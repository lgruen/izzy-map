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
  try {
    const { dir, base } = await resolvePath(path, false);
    await dir.removeEntry(base);
  } catch {
    /* already gone */
  }
}

export interface Progress {
  received: number;
  total: number | null;
}

/** Stream a URL into OPFS. Writes to <name>.part, renames on success. */
export async function download(
  url: string,
  name: string,
  onProgress?: (p: Progress) => void,
  signal?: AbortSignal,
): Promise<void> {
  const res = await fetch(url, { signal });
  if (!res.ok || !res.body) throw new Error(`HTTP ${res.status} for ${url}`);
  const total = Number(res.headers.get("Content-Length")) || null;

  const { dir, base } = await resolvePath(name, true);
  const tmp = await dir.getFileHandle(base + ".part", { create: true });
  const writable = await tmp.createWritable(); // Safari 26+/Chrome; target iPhone verified
  let received = 0;
  const reader = res.body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      await writable.write(value);
      received += value.byteLength;
      onProgress?.({ received, total });
    }
    await writable.close();
  } catch (e) {
    await writable.abort().catch(() => {});
    throw e;
  }
  // OPFS has no rename; copy handle content by moving via move() where
  // supported, else re-open. Safari supports FileSystemFileHandle.move()
  // since 26; fall back to copy-through-stream if it throws.
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
