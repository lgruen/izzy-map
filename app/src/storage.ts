// OPFS archive store. Map archives and F2F PDFs live here — never in the
// service-worker cache (see CLAUDE.md). All sizes are surfaced to the UI.
//
// Download design (round-2 review): CHUNKED PART FILES. Each 128 MB chunk is
// its own bounded Range request streamed into its own OPFS file, then a
// single assembly pass concatenates them into the final archive. Compared to
// one growing .part with periodic commits this gives O(n) total I/O (a
// committing writable copies the whole file into its swap on every open —
// ~31 GB of flash writes for the 2 GB topo), per-chunk retry/resume, and
// `If-Range` validation so a re-uploaded archive can never be spliced with
// stale bytes.

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
  try {
    const { dir, base } = await resolvePath(path, false);
    await dir.removeEntry(base).catch(() => {});
    await dir.removeEntry(base + ".parts", { recursive: true }).catch(() => {});
  } catch {
    /* already gone */
  }
  try {
    localStorage.removeItem("izzy-dl-etag:" + path);
  } catch {
    /* private mode */
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
): {
  progress: Progress;
  attach: (cb: (p: Progress) => void) => void;
  cancel: () => void;
  promise: Promise<void>;
} | null {
  const f = inflight.get(name);
  if (!f) return null;
  return {
    progress: f.progress,
    attach: (cb) => f.listeners.add(cb),
    cancel: () => f.controller.abort(),
    promise: f.promise,
  };
}

const DEFAULT_CHUNK = 128 * 1024 * 1024;
// Assembly transiently needs parts + final (≈2× archive) before parts are
// deleted; preflight accordingly, plus headroom.
const QUOTA_MARGIN = 300 * 1024 * 1024;

const MAGIC: Record<string, string> = { pmtiles: "PMTiles", pdf: "%PDF" };

const etagKey = (name: string) => "izzy-dl-etag:" + name;
const getEtag = (name: string) => {
  try {
    return localStorage.getItem(etagKey(name));
  } catch {
    return null;
  }
};
const setEtag = (name: string, v: string | null) => {
  try {
    if (v) localStorage.setItem(etagKey(name), v);
    else localStorage.removeItem(etagKey(name));
  } catch {
    /* private mode */
  }
};

const chunkName = (i: number) => String(i).padStart(4, "0") + ".bin";

async function partsDirOf(
  name: string,
  create: boolean,
): Promise<FileSystemDirectoryHandle | null> {
  try {
    const { dir, base } = await resolvePath(name, create);
    return await dir.getDirectoryHandle(base + ".parts", { create });
  } catch (e) {
    if (create) {
      // probing (create=false) returns null; a real download must surface
      // a meaningful error instead of crashing on a null handle later
      throw new Error("Offline storage isn't available in this browser");
    }
    void e;
    return null;
  }
}

/** Sizes of completed chunk files, indexed. */
async function completedChunks(pd: FileSystemDirectoryHandle): Promise<Map<number, number>> {
  const out = new Map<number, number>();
  const entries = (pd as unknown as { values(): AsyncIterable<FileSystemHandle> }).values();
  for await (const h of entries) {
    const m = /^(\d{4})\.bin$/.exec(h.name);
    if (m && h.kind === "file") {
      out.set(Number(m[1]), (await (h as FileSystemFileHandle).getFile()).size);
    }
  }
  return out;
}

/** Bytes already resumable for an archive (completed chunks). */
export async function partialBytes(name: string): Promise<number> {
  const pd = await partsDirOf(name, false);
  if (!pd) return 0;
  let sum = 0;
  for (const s of (await completedChunks(pd)).values()) sum += s;
  return sum;
}

/** Stream a URL into OPFS. Concurrent calls for the same name join the
 * existing download. */
export function download(
  url: string,
  name: string,
  onProgress?: (p: Progress) => void,
  opts?: { chunkSize?: number },
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
  entry.promise = runDownload(url, name, entry, opts?.chunkSize ?? DEFAULT_CHUNK).finally(() =>
    inflight.delete(name),
  );
  inflight.set(name, entry);
  return entry.promise;
}

async function runDownload(
  url: string,
  name: string,
  entry: Inflight,
  chunkSize: number,
): Promise<void> {
  try {
    await runDownloadInner(url, name, entry, chunkSize);
  } catch (e) {
    // Cancels can surface as raw AbortErrors from any await — normalize.
    // (But never mask a deliberate pre-abort error like the quota check.)
    if (entry.controller.signal.aborted && (e as Error).name === "AbortError")
      throw new Error("paused — tap the button to continue");
    throw e;
  }
}

async function runDownloadInner(
  url: string,
  name: string,
  entry: Inflight,
  chunkSize: number,
): Promise<void> {
  const signal = entry.controller.signal;
  const pd = (await partsDirOf(name, true))!; // throws with a clear message if OPFS is missing

  let chunks = await completedChunks(pd);
  // contiguous prefix of completed chunks is the resume point
  let nextIdx = 0;
  let offset = 0;
  while (chunks.has(nextIdx)) {
    offset += chunks.get(nextIdx)!;
    nextIdx++;
  }

  const wipe = async () => {
    const { dir, base } = await resolvePath(name, true);
    await dir.removeEntry(base + ".parts", { recursive: true }).catch(() => {});
    await dir.getDirectoryHandle(base + ".parts", { create: true });
    chunks = new Map();
    nextIdx = 0;
    offset = 0;
    setEtag(name, null);
  };

  const emit = (received: number, total: number | null) => {
    entry.progress.received = received;
    entry.progress.total = total;
    for (const cb of entry.listeners) cb(entry.progress);
  };

  let total: number | null = null;
  let restarted = false;

  for (;;) {
    if (total !== null && offset >= total) break;

    const etag = getEtag(name);
    const headers: Record<string, string> = {
      Range: `bytes=${offset}-${offset + chunkSize - 1}`,
    };
    if (etag && offset > 0) headers["If-Range"] = etag;

    let res: Response;
    try {
      res = await fetch(url, { signal, headers });
    } catch (e) {
      if (signal.aborted) throw e; // normalized to "paused" upstream
      throw new Error("Connection lost — tap Resume to continue where it left off");
    }

    if (res.status === 416 || (res.status === 200 && offset > 0)) {
      // Remote changed shape (416) or ignored/invalidated the range (200):
      // existing chunks may belong to an older version — start clean once.
      if (restarted) throw new Error("Server keeps sending unexpected data — try again later");
      restarted = true;
      await wipe();
      if (res.status === 200) res.body?.cancel().catch(() => {});
      continue;
    }
    if (!res.ok && res.status !== 206) throw new Error(friendlyHttp(res.status));
    if (!res.body) throw new Error("empty response");

    if (res.status === 206) {
      const range = res.headers.get("Content-Range"); // "bytes a-b/total"
      total = range ? Number(range.split("/")[1]) || null : total;
    } else {
      // 200 at offset 0: full body — single pass, chunked into part files.
      total = Number(res.headers.get("Content-Length")) || null;
    }
    if (offset === 0) setEtag(name, res.headers.get("ETag"));

    if (total) {
      const { usage, quota } = await storageInfo();
      // assembly needs parts + final simultaneously
      const needed = (total - offset) + total + QUOTA_MARGIN;
      if (quota && quota - usage < needed) {
        throw new Error(
          `Not enough free space — this needs about ${(2 * total / 1e9).toFixed(1)} GB free ` +
            "while installing. Delete something and try again.",
        );
      }
    }

    // Stream the body into sequential chunk files (a 206 body is exactly one
    // chunk; a 200 body spans many). Fresh files — no swap-copy commits.
    const reader = res.body.getReader();
    let curW: FileSystemWritableFileStream | null = null;
    let curWritten = 0;
    const openCur = async () => {
      curW = await (
        await pd.getFileHandle(chunkName(nextIdx) + ".tmp", { create: true })
      ).createWritable();
      curWritten = 0;
    };
    const commitCur = async () => {
      await curW!.close();
      await commitChunk(pd, chunkName(nextIdx) + ".tmp", chunkName(nextIdx));
      chunks.set(nextIdx, curWritten);
      offset += curWritten;
      nextIdx++;
      curW = null;
      emit(offset, total);
    };
    try {
      await openCur();
      for (;;) {
        const r = await reader.read();
        if (r.done) break;
        let buf: Uint8Array = r.value as Uint8Array;
        while (buf.byteLength > 0) {
          const take = Math.min(chunkSize - curWritten, buf.byteLength);
          await curW!.write(buf.subarray(0, take) as unknown as BufferSource);
          curWritten += take;
          buf = buf.subarray(take);
          emit(offset + curWritten, total);
          if (curWritten === chunkSize) {
            await commitCur();
            await openCur();
          }
        }
      }
      if (curWritten > 0) {
        await commitCur();
      } else {
        await curW!.abort().catch(() => {});
        await pd.removeEntry(chunkName(nextIdx) + ".tmp").catch(() => {});
      }
    } catch (e) {
      await (curW as FileSystemWritableFileStream | null)?.abort().catch(() => {});
      if (signal.aborted) throw e;
      throw new Error("Connection lost — tap Resume to continue where it left off");
    }
    if (total === null) total = offset; // 200 with no Content-Length
  }

  if (total !== null && offset !== total)
    throw new Error("Download incomplete — tap Resume to continue");

  await assemble(name, pd, chunks, total);
  emit(offset, total);
}

async function commitChunk(
  pd: FileSystemDirectoryHandle,
  tmpName: string,
  finalName: string,
): Promise<void> {
  const tmp = await pd.getFileHandle(tmpName);
  try {
    // @ts-expect-error move() not yet in lib.dom
    await tmp.move(finalName);
  } catch {
    const dst = await pd.getFileHandle(finalName, { create: true });
    const w = await dst.createWritable();
    await (await tmp.getFile()).stream().pipeTo(w);
    await pd.removeEntry(tmpName).catch(() => {});
  }
}

/** Concatenate chunk files into the final archive, validate, clean up. */
async function assemble(
  name: string,
  pd: FileSystemDirectoryHandle,
  chunks: Map<number, number>,
  total: number | null,
): Promise<void> {
  const { dir, base } = await resolvePath(name, true);
  const final = await dir.getFileHandle(base, { create: true });
  const w = await final.createWritable();
  try {
    for (let i = 0; i < chunks.size; i++) {
      const f = await (await pd.getFileHandle(chunkName(i))).getFile();
      const reader = f.stream().getReader();
      for (;;) {
        const r = await reader.read();
        if (r.done) break;
        await w.write(r.value);
      }
    }
    await w.close();
  } catch (e) {
    await w.abort().catch(() => {});
    // never leave a half-written file behind masquerading as installed
    await dir.removeEntry(base).catch(() => {});
    throw e instanceof Error ? e : new Error(String(e));
  }

  const installed = await (await final.getFile()).size;
  const ext = name.split(".").pop() ?? "";
  const magic = MAGIC[ext];
  let ok = total === null || installed === total;
  if (ok && magic) {
    const head = await (await final.getFile()).slice(0, magic.length).text();
    ok = head === magic;
  }
  if (!ok) {
    await dir.removeEntry(base).catch(() => {});
    await dir.removeEntry(base + ".parts", { recursive: true }).catch(() => {});
    setEtag(name, null);
    throw new Error("Downloaded file looks corrupted — try again");
  }
  await dir.removeEntry(base + ".parts", { recursive: true }).catch(() => {});
  setEtag(name, null);
}

function friendlyHttp(status: number): string {
  if (status === 404) return "Not available on the server yet";
  return `Couldn't download (HTTP ${status}) — try again on Wi-Fi`;
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
