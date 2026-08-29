// OPFS archive store. Map archives and F2F PDFs live here — never in the
// service-worker cache (see CLAUDE.md). All sizes are surfaced to the UI.

/** Resolve "a/b/c.ext" to (dir handle, basename), creating dirs if asked. */
async function resolvePath(
  path: string,
  create: boolean,
): Promise<{ dir: FileSystemDirectoryHandle; base: string }> {
  const parts = path.split("/");
  const base = parts.pop()!;
  let dir = await navigator.storage.getDirectory();
  for (const part of parts) dir = await dir.getDirectoryHandle(part, { create });
  return { dir, base };
}

export async function opfsFile(path: string): Promise<File | null> {
  try {
    const { dir, base } = await resolvePath(path, false);
    return await (await dir.getFileHandle(base)).getFile();
  } catch {
    return null;
  }
}

export async function deleteFile(path: string): Promise<void> {
  for (const p of [path, path + ".part"]) {
    try {
      const { dir, base } = await resolvePath(p, false);
      await dir.removeEntry(base);
    } catch {
      /* already gone */
    }
  }
}

export interface Progress {
  received: number;
  total: number | null;
}

interface Inflight {
  progress: Progress;
  listeners: Set<(p: Progress) => void>;
  controller: AbortController;
  promise: Promise<void>;
}
const inflight = new Map<string, Inflight>();

/** Live download for an archive, if any — lets a reopened panel re-attach. */
export function activeDownload(
  name: string,
): { progress: Progress; attach: (cb: (p: Progress) => void) => void; cancel: () => void; promise: Promise<void> } | null {
  const f = inflight.get(name);
  if (!f) return null;
  return {
    progress: f.progress,
    attach: (cb) => f.listeners.add(cb),
    cancel: () => f.controller.abort(),
    promise: f.promise,
  };
}

// Commit to disk every 64 MB so an interrupted multi-GB download resumes
// from the last committed boundary instead of byte 0.
const COMMIT_EVERY = 64 * 1024 * 1024;
// Leave headroom beyond the archive itself before starting a download.
const QUOTA_MARGIN = 300 * 1024 * 1024;

const MAGIC: Record<string, string> = { pmtiles: "PMTiles", pdf: "%PDF" };

/** Stream a URL into OPFS with resume, quota preflight, periodic durable
 * commits, and content validation. Concurrent calls for the same name join
 * the existing download. */
export function download(
  url: string,
  name: string,
  onProgress?: (p: Progress) => void,
): Promise<void> {
  const existing = inflight.get(name);
  if (existing) {
    if (onProgress) existing.listeners.add(onProgress);
    return existing.promise;
  }
  const controller = new AbortController();
  const entry: Inflight = {
    progress: { received: 0, total: null },
    listeners: new Set(onProgress ? [onProgress] : []),
    controller,
    promise: undefined as unknown as Promise<void>,
  };
  entry.promise = runDownload(url, name, entry).finally(() => inflight.delete(name));
  inflight.set(name, entry);
  return entry.promise;
}

async function runDownload(url: string, name: string, entry: Inflight): Promise<void> {
  try {
    await runDownloadInner(url, name, entry);
  } catch (e) {
    // Cancels can surface as raw AbortErrors from any await — normalize.
    if (entry.controller.signal.aborted)
      throw new Error("paused — tap Resume to continue");
    throw e;
  }
}

async function runDownloadInner(url: string, name: string, entry: Inflight): Promise<void> {
  const signal = entry.controller.signal;
  const { dir, base } = await resolvePath(name, true);
  const tmp = await dir.getFileHandle(base + ".part", { create: true });
  let offset = (await tmp.getFile()).size;

  const res = await fetch(url, {
    signal,
    headers: offset > 0 ? { Range: `bytes=${offset}-` } : {},
  });
  if (res.status === 200 && offset > 0) {
    offset = 0; // server ignored the Range header — start over
  } else if (res.status === 416) {
    offset = 0; // stale .part larger than the (changed) remote — start over
    await dir.removeEntry(base + ".part").catch(() => {});
  }
  if (!res.ok && res.status !== 206) throw new Error(friendlyHttp(res.status));
  if (!res.body) throw new Error("empty response");

  const range = res.headers.get("Content-Range"); // "bytes a-b/total"
  const total = range
    ? Number(range.split("/")[1]) || null
    : Number(res.headers.get("Content-Length")) + offset || null;
  entry.progress.total = total;

  if (total) {
    const { usage, quota } = await storageInfo();
    const needed = total - offset + QUOTA_MARGIN;
    if (quota && quota - usage < needed) {
      entry.controller.abort();
      throw new Error(
        `Not enough free space: this needs ~${Math.ceil((total - offset) / 1e9)} GB. ` +
          "Free up storage and try again.",
      );
    }
  }

  const emit = () => {
    entry.progress.received = offset;
    for (const cb of entry.listeners) cb(entry.progress);
  };
  emit();

  const reader = res.body.getReader();
  let writable = await tmp.createWritable({ keepExistingData: true });
  let sinceCommit = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      await writable.write({ type: "write", position: offset, data: value });
      offset += value.byteLength;
      sinceCommit += value.byteLength;
      emit();
      if (sinceCommit >= COMMIT_EVERY) {
        await writable.close(); // durable commit — the resume point
        writable = await tmp.createWritable({ keepExistingData: true });
        sinceCommit = 0;
      }
    }
    await writable.close();
  } catch (e) {
    await writable.abort().catch(() => {});
    if (signal.aborted) throw new Error("paused — tap Resume to continue");
    throw new Error("Connection lost — tap Resume to continue where it left off");
  }

  if (total && offset !== total)
    throw new Error("Download incomplete — tap Download to resume");

  // Validate content before installing: a captive portal or SPA fallback
  // serving HTML must not become "the archive".
  const ext = name.split(".").pop() ?? "";
  const magic = MAGIC[ext];
  if (magic) {
    const head = new Uint8Array(
      await (await tmp.getFile()).slice(0, magic.length).arrayBuffer(),
    );
    const got = String.fromCharCode(...head);
    if (got !== magic) {
      await dir.removeEntry(base + ".part").catch(() => {});
      throw new Error("Downloaded file looks corrupted — try again");
    }
  }

  try {
    // @ts-expect-error move() not yet in lib.dom
    await tmp.move(base);
  } catch {
    const final = await dir.getFileHandle(base, { create: true });
    const w = await final.createWritable();
    const f = await tmp.getFile();
    await f.stream().pipeTo(w);
    await dir.removeEntry(base + ".part").catch(() => {});
  }
}

function friendlyHttp(status: number): string {
  if (status === 404) return "Not available on the server yet";
  return `Couldn't download (HTTP ${status}) — try again on Wi-Fi`;
}

/** Bytes already resumable in a .part file, if any. */
export async function partialBytes(name: string): Promise<number> {
  const f = await opfsFile(name + ".part");
  return f?.size ?? 0;
}

export async function storageInfo(): Promise<{ usage: number; quota: number }> {
  try {
    const { usage = 0, quota = 0 } = await navigator.storage.estimate();
    return { usage, quota };
  } catch {
    return { usage: 0, quota: 0 };
  }
}

/** Call on every launch — home-screen apps get this granted heuristically. */
export async function ensurePersistence(): Promise<boolean> {
  try {
    return (await navigator.storage.persisted()) || (await navigator.storage.persist());
  } catch {
    return false;
  }
}
