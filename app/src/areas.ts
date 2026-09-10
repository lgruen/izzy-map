// Detailed areas: high-zoom tiles for a user-framed rectangle, per layer,
// fetched by the device straight from the LIST tile service (same verbatim
// tile terms as the packs — docs/LICENSING.md) and stored in OPFS.
//
// Layout (never whole-file rewrites; OPFS createWritable with
// keepExistingData copies the file on every open):
//   areas/areas.json                    registry of AreaMeta
//   areas/<id>/<layer>/part-0000.bin    tile bytes appended in fetch order
//   areas/<id>/<layer>/part-0000.json   [[z, x, y, offset, length], ...]
//                                       length 0 = confirmed absent (404)
// A part and its index are written together when the part closes (64 MB or
// end of run); an interrupted part is discarded and its tiles re-fetched on
// resume, everything before it survives.
import { PACK_MAXZOOM, SEASON_KEYS, packOf, type RasterKey } from "./config";
import { archiveTile } from "./protocol";
import { storageInfo } from "./storage";

export type BBox = [number, number, number, number]; // w, s, e, n

export interface AreaMeta {
  id: string;
  name: string;
  bbox: BBox;
  zmax: number;
  layers: RasterKey[];
  created: string;
  /** per layer: bytes stored, tiles stored (absent ones excluded), done */
  bytes: Partial<Record<RasterKey, number>>;
  tiles: Partial<Record<RasterKey, number>>;
  complete: Partial<Record<RasterKey, boolean>>;
}

const PART_LIMIT = 64 * 1024 * 1024;
const CONCURRENCY = 6;
const RETRIES = 3;

// ---------- tile maths ----------

export function tileAt(lon: number, lat: number, z: number): { x: number; y: number } {
  const n = 2 ** z;
  const x = Math.floor(((lon + 180) / 360) * n);
  const y = Math.floor(((1 - Math.asinh(Math.tan((lat * Math.PI) / 180)) / Math.PI) / 2) * n);
  return { x: Math.max(0, Math.min(n - 1, x)), y: Math.max(0, Math.min(n - 1, y)) };
}

/** Tiles of one zoom covering a bbox. */
export function tilesAt(bbox: BBox, z: number): [number, number][] {
  const [w, s, e, n] = bbox;
  const a = tileAt(w, n, z);
  const b = tileAt(e, s, z);
  const out: [number, number][] = [];
  for (let x = a.x; x <= b.x; x++) for (let y = a.y; y <= b.y; y++) out.push([x, y]);
  return out;
}

/** Tile count without materialising anything (a statewide frame at z18 is
 * millions of tiles — the setup sheet re-estimates on every tap). */
export function tileCount(bbox: BBox, zmin: number, zmax: number): number {
  const [w, s, e, n] = bbox;
  let count = 0;
  for (let z = zmin; z <= zmax; z++) {
    const a = tileAt(w, n, z);
    const b = tileAt(e, s, z);
    count += (b.x - a.x + 1) * (b.y - a.y + 1);
  }
  return count;
}

/** Hard cap per layer (~1 GB of aerial tiles): keeps device memory, the
 * LIST request volume and the user's patience bounded. */
export const MAX_AREA_TILES = 60_000;

/** Rough download size per layer: count × the pack's mean tile size. Seasons
 * only have tiles where they were flown, so theirs is an upper bound. */
export function estimateArea(bbox: BBox, zmax: number, layers: RasterKey[]): Record<string, { tiles: number; bytes: number }> {
  const out: Record<string, { tiles: number; bytes: number }> = {};
  for (const key of layers) {
    const p = packOf(key);
    const tiles = tileCount(bbox, 0, Math.min(zmax, p.maxzoom));
    out[key] = { tiles, bytes: tiles * p.meanTileBytes };
  }
  return out;
}

// ---------- OPFS helpers ----------

async function dirOf(path: string, create: boolean): Promise<FileSystemDirectoryHandle | null> {
  try {
    let dir = await navigator.storage.getDirectory();
    for (const part of path.split("/").filter(Boolean)) dir = await dir.getDirectoryHandle(part, { create });
    return dir;
  } catch {
    return null;
  }
}

async function readJson<T>(dir: FileSystemDirectoryHandle, name: string): Promise<T | null> {
  try {
    return JSON.parse(await (await (await dir.getFileHandle(name)).getFile()).text()) as T;
  } catch {
    return null;
  }
}

async function writeJson(dir: FileSystemDirectoryHandle, name: string, value: unknown): Promise<void> {
  const w = await (await dir.getFileHandle(name, { create: true })).createWritable();
  await w.write(JSON.stringify(value));
  await w.close();
}

// ---------- registry ----------

export async function listAreas(): Promise<AreaMeta[]> {
  const dir = await dirOf("areas", false);
  if (!dir) return [];
  const reg = await readJson<{ areas: AreaMeta[] }>(dir, "areas.json");
  return reg?.areas ?? [];
}

async function saveAreas(areas: AreaMeta[]): Promise<void> {
  const dir = await dirOf("areas", true);
  if (!dir) throw new Error("Offline storage isn't available in this browser");
  await writeJson(dir, "areas.json", { areas });
}

// Every registry change is a fresh read-modify-write under one lock: two
// layer downloads (or a download and a delete) must not clobber each other
// with stale copies of the whole AreaMeta.
let registryLock: Promise<unknown> = Promise.resolve();
function withRegistry<T>(fn: (areas: AreaMeta[]) => Promise<T> | T): Promise<T> {
  const run = registryLock.then(async () => {
    const areas = await listAreas();
    const out = await fn(areas);
    await saveAreas(areas);
    return out;
  });
  registryLock = run.catch(() => {});
  return run;
}

export function upsertArea(meta: AreaMeta): Promise<void> {
  return withRegistry((areas) => {
    const i = areas.findIndex((a) => a.id === meta.id);
    if (i >= 0) areas[i] = meta;
    else areas.push(meta);
  });
}

/** Update one layer's counters from a fresh read (never from a stale copy). */
function patchLayer(
  id: string,
  key: RasterKey,
  add: { bytes: number; tiles: number },
  complete?: boolean,
): Promise<AreaMeta | null> {
  return withRegistry((areas) => {
    const a = areas.find((x) => x.id === id);
    if (!a) return null;
    a.bytes[key] = (a.bytes[key] ?? 0) + add.bytes;
    a.tiles[key] = (a.tiles[key] ?? 0) + add.tiles;
    if (complete !== undefined) a.complete[key] = complete;
    return a;
  });
}

export async function deleteArea(id: string): Promise<void> {
  // a running download holds an open writable in the directory: stop it
  // and wait, or removeEntry fails and gigabytes stay orphaned in OPFS
  for (const [k, f] of inflight) {
    if (k.startsWith(id + "/")) {
      f.controller.abort();
      await f.promise.catch(() => {});
    }
  }
  const root = await dirOf("areas", false);
  if (root) {
    try {
      await root.removeEntry(id, { recursive: true });
    } catch (e) {
      if ((e as DOMException).name !== "NotFoundError")
        throw new Error("Couldn't delete the area's files — close and reopen the app, then try again");
    }
  }
  await withRegistry((areas) => {
    const i = areas.findIndex((a) => a.id === id);
    if (i >= 0) areas.splice(i, 1);
  });
  await refreshAreaStores();
}

// ---------- reading ----------

type Entry = [part: number, offset: number, length: number];

/** One area × layer, opened for tile reads. */
class AreaStore {
  private index = new Map<string, Entry>();
  private parts: File[] = [];
  constructor(readonly areaId: string, readonly key: RasterKey, readonly zmax: number) {}

  async open(): Promise<boolean> {
    const dir = await dirOf(`areas/${this.areaId}/${this.key}`, false);
    if (!dir) return false;
    const names: string[] = [];
    for await (const h of (dir as unknown as { values(): AsyncIterable<FileSystemHandle> }).values())
      if (h.kind === "file") names.push(h.name);
    for (const name of names.filter((n) => /^part-\d{4}\.json$/.test(n)).sort()) {
      const part = Number(name.slice(5, 9));
      const rows = await readJson<[number, number, number, number, number][]>(dir, name);
      if (!rows) continue;
      try {
        this.parts[part] = await (await dir.getFileHandle(`part-${name.slice(5, 9)}.bin`)).getFile();
      } catch {
        continue; // index without data: skip that part
      }
      for (const [z, x, y, off, len] of rows) this.index.set(`${z}/${x}/${y}`, [part, off, len]);
    }
    return this.index.size > 0;
  }

  get size(): number {
    return this.index.size;
  }

  /** ArrayBuffer for a stored tile, null for absent-or-unknown. */
  async get(z: number, x: number, y: number): Promise<ArrayBuffer | null> {
    const e = this.index.get(`${z}/${x}/${y}`);
    if (!e || e[2] === 0) return null;
    const f = this.parts[e[0]];
    if (!f) return null;
    return f.slice(e[1], e[1] + e[2]).arrayBuffer();
  }

  has(z: number, x: number, y: number): boolean {
    return this.index.has(`${z}/${x}/${y}`);
  }

  /** Completed (z,x,y) keys — the resume point for the downloader. */
  keys(): Set<string> {
    return new Set(this.index.keys());
  }
}

let stores = new Map<RasterKey, AreaStore[]>();

/** (Re)open every area store; call at boot and after area changes. Built
 * aside and swapped in whole, so tiles in view never see an empty map
 * mid-refresh (a z16+ miss would 404 to the parent and stay stale). */
export async function refreshAreaStores(): Promise<void> {
  const next = new Map<RasterKey, AreaStore[]>();
  for (const meta of await listAreas()) {
    for (const key of meta.layers) {
      const s = new AreaStore(meta.id, key, meta.zmax);
      if (await s.open()) {
        if (!next.has(key)) next.set(key, []);
        next.get(key)!.push(s);
      }
    }
  }
  stores = next;
}

/** Tile from any downloaded area for this layer, or null. */
export async function areaTile(key: RasterKey, z: number, x: number, y: number): Promise<ArrayBuffer | null> {
  const list = stores.get(key);
  if (!list) return null;
  for (const s of list) {
    if (z > s.zmax) continue;
    const t = await s.get(z, x, y);
    if (t) return t;
  }
  return null;
}

export function areaCount(key: RasterKey): number {
  return stores.get(key)?.length ?? 0;
}

// ---------- downloading ----------

export interface AreaProgress {
  done: number;
  total: number;
  bytes: number;
}

interface Inflight {
  controller: AbortController;
  promise: Promise<void>;
  progress: AreaProgress;
  listeners: Set<(p: AreaProgress) => void>;
}
const inflight = new Map<string, Inflight>();

export function activeAreaDownload(areaId: string, key: RasterKey) {
  const f = inflight.get(`${areaId}/${key}`);
  if (!f) return null;
  return {
    progress: f.progress,
    attach: (cb: (p: AreaProgress) => void) => f.listeners.add(cb),
    cancel: () => f.controller.abort(),
    promise: f.promise,
  };
}

/** Download (or resume) one layer of an area. Rejects with a friendly
 * message; a cancel rejects with "paused". */
export function downloadAreaLayer(
  meta: AreaMeta,
  key: RasterKey,
  onProgress?: (p: AreaProgress) => void,
): Promise<void> {
  const id = `${meta.id}/${key}`;
  const existing = inflight.get(id);
  if (existing) {
    if (onProgress) existing.listeners.add(onProgress);
    return existing.promise;
  }
  const controller = new AbortController();
  const entry: Inflight = {
    controller,
    progress: { done: 0, total: 0, bytes: 0 },
    listeners: new Set(onProgress ? [onProgress] : []),
    promise: undefined as unknown as Promise<void>,
  };
  entry.promise = run(meta, key, entry)
    .catch((e: Error) => {
      if (controller.signal.aborted) throw new Error("paused — tap Resume to continue");
      throw e;
    })
    .finally(() => inflight.delete(id));
  inflight.set(id, entry);
  return entry.promise;
}

/** Fetch one tile from the live service: bytes, null for 404, throws on
 * repeated failure or abort. */
async function fetchTile(url: string, signal: AbortSignal): Promise<ArrayBuffer | null> {
  let err: unknown;
  for (let attempt = 0; attempt < RETRIES; attempt++) {
    try {
      const res = await fetch(url, { signal });
      if (res.status === 404) return null;
      if (res.ok) {
        const buf = await res.arrayBuffer();
        const b = new Uint8Array(buf, 0, 4);
        // only real images may enter the store (an HTML error page would
        // otherwise render as a broken tile forever)
        if ((b[0] === 0xff && b[1] === 0xd8) || (b[0] === 0x89 && b[1] === 0x50)) return buf;
        err = new Error("non-image response");
      } else err = new Error(`HTTP ${res.status}`);
    } catch (e) {
      if (signal.aborted) throw e;
      err = e;
    }
    await new Promise((r) => setTimeout(r, 800 * (attempt + 1)));
    if (signal.aborted) throw new Error("aborted");
  }
  throw new Error(`Connection lost — tap Resume to continue (${String((err as Error)?.message ?? err)})`);
}

async function run(meta: AreaMeta, key: RasterKey, entry: Inflight): Promise<void> {
  const signal = entry.controller.signal;
  const pack = packOf(key);
  if (!pack.live) throw new Error("This layer cannot be fetched by the device");
  const zmax = Math.min(meta.zmax, pack.maxzoom);
  const dir = await dirOf(`areas/${meta.id}/${key}`, true);
  if (!dir) throw new Error("Offline storage isn't available in this browser");

  // resume point: everything already indexed
  const existing = new AreaStore(meta.id, key, zmax);
  await existing.open();
  const have = existing.keys();
  let partNo = 0;
  for await (const h of (dir as unknown as { values(): AsyncIterable<FileSystemHandle> }).values()) {
    const m = /^part-(\d{4})\.json$/.exec(h.name);
    if (m) partNo = Math.max(partNo, Number(m[1]) + 1);
    if (/\.tmp$/.test(h.name)) await dir.removeEntry(h.name).catch(() => {});
  }
  // an interrupted part (bin without json) is discarded
  for await (const h of (dir as unknown as { values(): AsyncIterable<FileSystemHandle> }).values()) {
    const m = /^part-(\d{4})\.bin$/.exec(h.name);
    if (m && Number(m[1]) >= partNo) await dir.removeEntry(h.name).catch(() => {});
  }

  // candidate tiles. Seasons: only under z15 tiles the season actually has
  // (its archive, local or R2) — LISTs per-season services 404 everywhere
  // else, and a z18 area is 64× the z15 count.
  const isSeason = (SEASON_KEYS as readonly string[]).includes(key);
  const parentHas = new Map<string, boolean>();
  const todo: [number, number, number][] = [];
  for (let z = 0; z <= zmax; z++) {
    for (const [x, y] of tilesAt(meta.bbox, z)) {
      if (have.has(`${z}/${x}/${y}`)) continue;
      if (isSeason && z > PACK_MAXZOOM) {
        const d = z - PACK_MAXZOOM;
        const pk = `${x >> d}/${y >> d}`;
        if (!parentHas.has(pk)) {
          if (signal.aborted) throw new Error("aborted");
          try {
            // null = the season's archive says "not flown here"; an
            // UNREACHABLE archive must not read as "not flown" — that would
            // mark the area complete with nothing in it
            parentHas.set(pk, !!(await archiveTile(key, PACK_MAXZOOM, x >> d, y >> d)));
          } catch {
            throw new Error("Connection lost — the season's coverage couldn't be checked; tap Resume when online");
          }
        }
        if (!parentHas.get(pk)) continue;
      }
      todo.push([z, x, y]);
      if (todo.length > MAX_AREA_TILES)
        throw new Error(`Area too large for one download (over ${MAX_AREA_TILES.toLocaleString()} tiles) — zoom in or pick less detail`);
    }
  }
  entry.progress.total = have.size + todo.length;
  entry.progress.done = have.size;
  entry.progress.bytes = meta.bytes[key] ?? 0;
  const emit = () => {
    for (const cb of entry.listeners) cb(entry.progress);
  };
  emit();

  // quota preflight on the estimate
  const est = todo.length * pack.meanTileBytes;
  const { usage, quota } = await storageInfo();
  if (quota && quota - usage < est + 200e6)
    throw new Error(`Not enough free space — this needs about ${(est / 1e6).toFixed(0)} MB. Delete something and try again.`);

  // part writer. A part is valid at every prefix (rows are appended only
  // after their bytes are written), so on ANY interruption the open part is
  // closed and indexed rather than thrown away — unless the writer itself
  // failed, in which case its bytes are suspect and it is discarded.
  let writer: FileSystemWritableFileStream | null = null;
  let writerBroken = false;
  let partRows: [number, number, number, number, number][] = [];
  let partBytes = 0;
  let storedBytes = meta.bytes[key] ?? 0;
  const openPart = async () => {
    writer = await (await dir.getFileHandle(`part-${String(partNo).padStart(4, "0")}.bin`, { create: true })).createWritable();
    partRows = [];
    partBytes = 0;
  };
  const closePart = async () => {
    if (!writer) return;
    const w = writer;
    writer = null;
    await w.close();
    await writeJson(dir, `part-${String(partNo).padStart(4, "0")}.json`, partRows);
    partNo++;
    storedBytes += partBytes;
    await patchLayer(meta.id, key, { bytes: partBytes, tiles: partRows.filter((r) => r[4] > 0).length });
  };
  const discardPart = async () => {
    if (!writer) return;
    const w = writer;
    writer = null;
    await w.abort().catch(() => {});
    await dir.removeEntry(`part-${String(partNo).padStart(4, "0")}.bin`).catch(() => {});
  };
  const store = async (z: number, x: number, y: number, data: ArrayBuffer | null) => {
    if (!writer) await openPart();
    const len = data ? data.byteLength : 0;
    if (data) {
      try {
        await writer!.write(data);
      } catch (e) {
        writerBroken = true;
        throw e;
      }
    }
    partRows.push([z, x, y, partBytes, len]);
    partBytes += len;
    entry.progress.done++;
    entry.progress.bytes = storedBytes + partBytes;
    if (partBytes >= PART_LIMIT) await closePart();
  };

  // fetch with bounded concurrency; writes are serialised through one chain
  // with backpressure (fetchers wait when the queue is deep), and a write
  // failure stops the fetchers instead of letting them fill memory
  let next = 0;
  let failure: unknown = null;
  const queue: Promise<void>[] = [];
  const pending: { z: number; x: number; y: number; data: ArrayBuffer | null }[] = [];
  let writing: Promise<void> = Promise.resolve();
  const flush = () => {
    writing = writing
      .then(async () => {
        while (pending.length) {
          const t = pending.shift()!;
          await store(t.z, t.x, t.y, t.data);
        }
        emit();
      })
      .catch((e: unknown) => {
        failure ??= e;
        entry.controller.abort();
      });
    return writing;
  };
  const worker = async () => {
    while (next < todo.length && !failure && !signal.aborted) {
      const [z, x, y] = todo[next++];
      try {
        const data = await fetchTile(pack.live!(z, x, y), signal);
        pending.push({ z, x, y, data });
        void flush();
        if (pending.length >= 24) await writing;
      } catch (e) {
        failure ??= e;
      }
    }
  };
  try {
    for (let i = 0; i < CONCURRENCY; i++) queue.push(worker());
    await Promise.all(queue);
    await flush();
    if (failure) throw failure;
    if (signal.aborted) throw new Error("aborted");
    await closePart();
    await patchLayer(meta.id, key, { bytes: 0, tiles: 0 }, true);
    meta.complete[key] = true;
  } catch (e) {
    await writing.catch(() => {});
    if (writerBroken) await discardPart();
    else await closePart().catch(() => discardPart());
    throw e;
  } finally {
    await refreshAreaStores();
  }
}
