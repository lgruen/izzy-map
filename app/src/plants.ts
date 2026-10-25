// Plants: the Understorey Network Tasmania (UN) plant profiles, the
// Atlas of Living Australia occurrence lists per TASVEG community and the
// ~1 km "recorded near here" grid — plus the photo store. Shared by
// details.ts (community card + plant sheet) and ui.ts (the "Plant photos"
// download row); neither may import the other.
//
// Data: plants.json + records.json are committed FACTS (names, short
// descriptors, species lists), loaded by dynamic import on the first card
// that needs them — Vite emits them as JS chunks the service worker
// precaches. nearby.bin is a hashed binary asset (also precached), fetched
// and parsed once. PHOTOS are © their photographers: never committed, never
// on Pages/R2. Online, a plain <img> shows them straight from UN; for
// offline use the device fetches the large versions through the
// transparent, non-caching relay into OPFS (`plants/<file>`).
import nearbyUrl from "./generated/nearby.bin?url";
import { PLANT_PHOTO_DIR, PLANT_RELAY, UN_BASE } from "./config";
import { QUOTA_MARGIN, deleteDir, listDir, opfsFile, storageInfo, writeFile } from "./storage";

export interface Photo {
  /** under /wp-content/uploads/, no size suffix, no extension */
  path: string;
  ext: string;
  /** suffix of the 150 px square thumbnail, or null */
  thumb: string | null;
  /** suffix of the ~768 px version ("-768x576"), or of a WordPress-renamed
   * original ("-rotated", "-scaled"), or "" = the original — never parsed */
  large: string;
  /** size of the large version if known */
  bytes: number | null;
  credit: string | null;
}
export interface Plant {
  id: number;
  slug: string;
  /** verbatim UN title — may hold non-Latin-1 characters: DOM only, never MapLibre text */
  name: string;
  species: string | null;
  common: string | null;
  family: string | null;
  forms: string[];
  height: string | null;
  form: string | null;
  flowers: string | null;
  fruit: string | null;
  habitat: string | null;
  notes: string | null;
  status: string | null;
  flowering: number[];
  habitats: string[];
  photos: Photo[];
}
interface PlantsFile {
  version: number;
  plants: Plant[];
  /** B entries: species keys, or keys of `groups` */
  communities: Record<string, string[]>;
  /** a broad-sense name F2F uses for what UN splits into several species */
  groups?: Record<string, { common: string | null; species: string[] }>;
}
interface RecordsFile {
  version: number;
  species: string[];
  /** [speciesIdx, sites, score]; score null = a community with few records
   * (< 30 sites), whose list is a plain tally ranked by sites */
  communities: Record<string, [number, number, number | null][]>;
  /** VEGCODE -> total recorded ~100 m sites in that community */
  sites?: Record<string, number>;
  /** VEGCODE -> [speciesIdx, sites] for every group member species recorded
   * there (uncapped, unlike the C1 lists) */
  members?: Record<string, [number, number][]>;
  grid: { step: number; lat0: number; lon0: number; nlon: number };
}
/** C1 for one community. */
export interface Often {
  entries: Entry[];
  /** few records: every species recorded there, by sites (not an indicator ranking) */
  tally: boolean;
  /** total recorded sites in the community, if known */
  sites: number | null;
}

/** One list entry: the species key, its UN profile and (C1/C2) a site count. */
export interface Entry {
  key: string;
  /** the profile to show (for a group: the member that lends its thumbnail) */
  plant: Plant;
  sites?: number;
  /** set when this B entry is a group (broad-sense name) */
  group?: Group;
}
export interface Group {
  key: string;
  common: string | null;
  /** species in the group, profiled or not */
  size: number;
  /** members with a UN profile */
  members: Entry[];
}
export interface Nearby {
  entries: Entry[];
  /** species key -> summed sites, every species incl. those without a profile */
  sites: Map<string, number>;
  /** Σ sites over the window */
  total: number;
  /** Σ sites over the entries shown (species with a UN profile) */
  shownTotal: number;
}
export interface PlantData {
  plants: Plant[];
  /** B: species named in the community's F2F account (order of mention) */
  named(code: string): Entry[];
  /** C1: species ALA records put inside this community, best first */
  often(code: string): Often;
  /** C2: the tapped point's 0.01° cell + 8 neighbours, summed; rejects when
   * the grid could not be loaded (the next call tries again) */
  nearby(lon: number, lat: number): Promise<Nearby>;
  /** species key -> recorded sites inside this community (every species
   * C1 lists, profiled or not) */
  communitySites(code: string): Map<string, number>;
}

// ---------- nearby.bin (NBY1, little-endian) ----------

const NBY_MAGIC = 0x4e425931;
interface Grid {
  view: DataView;
  n: number;
  cellsAt: number; // byte offset of the cell array
  offAt: number; // byte offset of the (n + 1) offsets
  pairsAt: number; // byte offset of the (uint16 species, uint16 sites) pairs
}
/** Parse and validate the grid; throws on a wrong magic or a truncated file. */
export function parseNearby(buf: ArrayBuffer): Grid {
  const view = new DataView(buf);
  if (buf.byteLength < 8 || view.getUint32(0, true) !== NBY_MAGIC) throw new Error("nearby.bin: bad magic");
  const n = view.getUint32(4, true);
  const cellsAt = 8;
  const offAt = cellsAt + 4 * n;
  const pairsAt = offAt + 4 * (n + 1);
  if (buf.byteLength < pairsAt) throw new Error("nearby.bin: truncated");
  const npairs = view.getUint32(offAt + 4 * n, true);
  if (buf.byteLength < pairsAt + 4 * npairs) throw new Error("nearby.bin: truncated");
  return { view, n, cellsAt, offAt, pairsAt };
}
/** Binary search for a cell id; its index or -1. */
function findCell(g: Grid, cell: number): number {
  let lo = 0;
  let hi = g.n - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >>> 1;
    const v = g.view.getUint32(g.cellsAt + 4 * mid, true);
    if (v === cell) return mid;
    if (v < cell) lo = mid + 1;
    else hi = mid - 1;
  }
  return -1;
}
/** speciesIdx -> summed sites over the 3 × 3 cells around (lon, lat). Cell
 * centres sit on multiples of `step`, so the window always reaches at least
 * one step (≈ 0.8 km E–W, 1.1 km N–S) past the point, at most 1.5 steps. */
export function sitesAround(
  g: Grid,
  grid: RecordsFile["grid"],
  lon: number,
  lat: number,
): Map<number, number> {
  const out = new Map<number, number>();
  const row = Math.round((lat - grid.lat0) / grid.step);
  const col = Math.round((lon - grid.lon0) / grid.step);
  for (let dr = -1; dr <= 1; dr++) {
    for (let dc = -1; dc <= 1; dc++) {
      const r = row + dr;
      const c = col + dc;
      if (r < 0 || c < 0 || c >= grid.nlon) continue;
      const i = findCell(g, r * grid.nlon + c);
      if (i < 0) continue;
      const a = g.view.getUint32(g.offAt + 4 * i, true);
      const b = g.view.getUint32(g.offAt + 4 * (i + 1), true);
      for (let k = a; k < b; k++) {
        const sp = g.view.getUint16(g.pairsAt + 4 * k, true);
        const sites = g.view.getUint16(g.pairsAt + 4 * k + 2, true);
        out.set(sp, (out.get(sp) ?? 0) + sites);
      }
    }
  }
  return out;
}

// ---------- loading ----------

let loading: Promise<PlantData> | null = null;

/** Load (once) and index the plant data. A failure is not cached: a lazy
 * chunk can go missing when a background service-worker update replaced the
 * build this resident app came from — the next card retries, and a relaunch
 * picks up the new build. main.ts prefetches it on the first map idle
 * under a service worker, so a resident app holds the data in memory before
 * any update can purge its precache. The grid loads alongside but on its
 * own: if only it fails the lists still work, and nearby() retries. */
export function loadPlantData(): Promise<PlantData> {
  loading ??= build().catch((e: unknown) => {
    loading = null;
    throw e;
  });
  return loading;
}

// The nearby grid, loaded once; a failure is not cached (next nearby() retries).
let gridLoading: Promise<Grid> | null = null;
const GRID_TIMEOUT_MS = 20_000; // a stalled fetch must not hang the list for ever
function loadGrid(): Promise<Grid> {
  if (!gridLoading) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), GRID_TIMEOUT_MS);
    gridLoading = fetch(nearbyUrl, { signal: ctl.signal })
      .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then(parseNearby)
      .catch((e: unknown) => {
        gridLoading = null;
        throw e;
      })
      .finally(() => clearTimeout(timer));
  }
  return gridLoading;
}

async function build(): Promise<PlantData> {
  loadGrid().catch(() => {}); // in parallel; nearby() awaits (and retries) it
  const [pm, rm] = await Promise.all([import("./generated/plants.json"), import("./generated/records.json")]);
  const P = pm.default as unknown as PlantsFile;
  const R = rm.default as unknown as RecordsFile;
  if (P.version !== 1 || R.version !== 1) throw new Error("plant data: unexpected version");

  const byKey = new Map<string, Plant[]>();
  for (const p of P.plants) {
    if (!p.species) continue;
    const list = byKey.get(p.species);
    if (list) list.push(p);
    else byKey.set(p.species, [p]);
  }
  /** species key -> the profile to show: one with photos (the species'
   * own record first), else the species' own record, else the first */
  const pick = new Map<string, Plant>();
  const plantFor = (key: string): Plant | undefined => {
    const hit = pick.get(key);
    if (hit) return hit;
    const list = byKey.get(key);
    if (!list) return undefined;
    const withPhotos = list.filter((p) => p.photos.length);
    const p =
      withPhotos.find((x) => x.name === key) ?? withPhotos[0] ?? list.find((x) => x.name === key) ?? list[0];
    pick.set(key, p);
    return p;
  };
  const entry = (key: string, sites?: number): Entry | null => {
    const plant = plantFor(key);
    return plant ? { key, plant, sites } : null; // a key without a UN profile is skipped
  };
  const present = (e: Entry | null): e is Entry => e !== null;

  return {
    plants: P.plants,
    named: (code) =>
      (P.communities[code] ?? [])
        .map((k) => {
          const g = P.groups?.[k];
          if (!g) return entry(k);
          const members = g.species.map((s) => entry(s)).filter(present);
          if (!members.length) return null;
          // the thumbnail comes from the first member with a photo
          const face = members.find((m) => m.plant.photos.length) ?? members[0];
          return { key: k, plant: face.plant, group: { key: k, common: g.common, size: g.species.length, members } };
        })
        .filter(present),
    communitySites: (code) => {
      // the C1 list is capped (≤ 40), so group members can be missing from
      // it: `members` carries their full per-community counts
      const out = new Map<string, number>();
      for (const [i, sites] of R.communities[code] ?? []) if (R.species[i]) out.set(R.species[i], sites);
      for (const [i, sites] of R.members?.[code] ?? []) if (R.species[i]) out.set(R.species[i], sites);
      return out;
    },
    often: (code) => {
      const rows = R.communities[code] ?? [];
      return {
        entries: rows.map(([i, sites]) => (R.species[i] ? entry(R.species[i], sites) : null)).filter(present),
        tally: rows.length > 0 && rows.every((r) => r[2] == null),
        sites: R.sites?.[code] ?? null,
      };
    },
    nearby: async (lon, lat) => {
      const grid = await loadGrid();
      const raw = sitesAround(grid, R.grid, lon, lat);
      const sites = new Map<string, number>();
      let total = 0;
      for (const [i, n] of raw) {
        const key = R.species[i];
        if (!key) continue;
        sites.set(key, n);
        total += n;
      }
      const entries = [...sites]
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
        .map(([k, n]) => entry(k, n))
        .filter(present);
      return { entries, sites, total, shownTotal: entries.reduce((a, e) => a + (e.sites ?? 0), 0) };
    },
  };
}

// ---------- photos ----------

const uploads = (ph: Photo, suffix: string) => `${UN_BASE}/wp-content/uploads/${ph.path}${suffix}.${ph.ext}`;
/** The 150 px square thumbnail (the large version when UN has none). */
export const thumbUrl = (ph: Photo): string => uploads(ph, ph.thumb ?? ph.large);
/** The ~768 px version shown in the plant sheet and kept offline. */
export const largeUrl = (ph: Photo): string => uploads(ph, ph.large);
/** The same large file through the CORS relay (OPFS download only). */
export const relayUrl = (ph: Photo): string => `${PLANT_RELAY}/${ph.path}${ph.large}.${ph.ext}`;
/** Flat OPFS file name (one directory walk answers "what is on the device").
 * The size suffix is left out: a re-sized large version is still the photo. */
export const photoName = (ph: Photo): string => `${ph.path.replace(/\//g, "-")}.${ph.ext}`;
export const photoPath = (ph: Photo): string => `${PLANT_PHOTO_DIR}/${photoName(ph)}`;

/** Mirrors the relay's allow-list (pipeline/f2f-proxy/worker.js): a photo
 * whose file name it would refuse can't be downloaded — leaving it out
 * keeps one odd name from stopping the batch at the same spot for ever
 * (it still shows online, straight from UN). */
const RELAYABLE = /^(?:19|20)\d\d\/(?:0[1-9]|1[0-2])\/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,199}$/;
const relayable = (ph: Photo) =>
  RELAYABLE.test(ph.path + ph.large) && !ph.path.includes("..") && /^(?:jpe?g|jpe|png|webp|gif)$/i.test(ph.ext);

/** Every distinct photo file the relay can fetch, across all profiles, in
 * path order — the "Plant photos" download set. */
export function allPhotos(data: PlantData): Photo[] {
  const seen = new Map<string, Photo>();
  for (const p of data.plants)
    for (const ph of p.photos) if (relayable(ph) && !seen.has(photoName(ph))) seen.set(photoName(ph), ph);
  return [...seen.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}
/** Σ declared sizes; photos of unknown size count at the mean of the known. */
export function photosBytes(photos: Photo[]): number {
  const known = photos.filter((p) => p.bytes != null);
  const sum = known.reduce((a, p) => a + p.bytes!, 0);
  const mean = known.length ? sum / known.length : 150_000;
  return Math.round(sum + (photos.length - known.length) * mean);
}

// Names of the photo files on the device (non-empty), from one directory
// walk, kept current by the downloads and Delete in this module.
let localNames: Promise<Set<string>> | null = null;
export function localPhotos(): Promise<Set<string>> {
  localNames ??= listDir(PLANT_PHOTO_DIR).then(
    (m) => new Set([...m].filter(([name, size]) => size > 0 && !name.endsWith(".tmp")).map(([name]) => name)),
  );
  return localNames;
}
// object URLs of stored photos, made once per file for this session
const objectUrls = new Map<string, string>();
async function localPhotoUrl(ph: Photo): Promise<string | null> {
  const name = photoName(ph);
  if (!(await localPhotos()).has(name)) return null;
  const cached = objectUrls.get(name);
  if (cached) return cached;
  const file = await opfsFile(photoPath(ph));
  if (!file || !file.size) return null;
  const url = URL.createObjectURL(file);
  objectUrls.set(name, url);
  return url;
}

const LEAF =
  '<svg class="ph-leaf" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="M20 4c-8.5 0-14 5.5-16 16 10.5-2 16-7.5 16-16Z"/><path d="M4 20C8 13 13 8 20 4"/></svg>';

/** The thumbnail-sized placeholder for a plant UN has no photo of. */
export function noPhotoBox(): HTMLElement {
  const box = document.createElement("span");
  box.className = "ph ph-thumb ph-none";
  box.innerHTML = LEAF;
  return box;
}

/** A photo box: a neutral placeholder that an <img> fades into once one
 * loads — the stored file first, else (online) UN directly. Offline and
 * not stored, or a failed load, leaves the placeholder: never a broken-image
 * icon. `kind` picks the 150 px thumbnail or the large version (a stored
 * large file also serves as the thumbnail — offline it is all there is). */
export function photoBox(ph: Photo, kind: "thumb" | "large", alt: string): HTMLElement {
  const box = document.createElement("span");
  box.className = `ph ph-${kind}`;
  box.innerHTML = LEAF;
  // The large file's pixel size isn't known (its suffix may be -WxH,
  // -rotated, -scaled or none): a fixed 4:3 box, the photo contained in it.
  const size = kind === "thumb" ? { w: 150, h: 150 } : { w: 768, h: 576 };
  void (async () => {
    const local = await localPhotoUrl(ph).catch(() => null);
    const src = local ?? (navigator.onLine ? (kind === "thumb" ? thumbUrl(ph) : largeUrl(ph)) : null);
    if (!src) return;
    const img = document.createElement("img");
    img.alt = alt;
    img.width = size.w;
    img.height = size.h;
    img.loading = "lazy";
    img.decoding = "async";
    img.onload = () => box.classList.add("loaded");
    img.onerror = () => img.remove(); // placeholder stays
    img.src = src;
    box.append(img);
  })();
  return box;
}

// ---------- the "Plant photos" download ----------

/** Why a photo fetch failed. `notimage` = a 200 that is not JPEG/PNG/WebP
 * (a captive-portal login page): the batch stops instead of storing it. */
export type PhotoErrorKind = "offline" | "aborted" | "notimage" | "failed";
export class PhotoError extends Error {
  constructor(message: string, readonly kind: PhotoErrorKind) {
    super(message);
    this.name = "PhotoError";
  }
}

/** JPEG (FF D8 FF), PNG (89 'PNG'), WebP ('RIFF' … 'WEBP'), GIF ('GIF8'). */
export function isImage(buf: ArrayBuffer): boolean {
  const b = new Uint8Array(buf, 0, Math.min(12, buf.byteLength));
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return true;
  if (b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return true;
  const s = String.fromCharCode(...b);
  return (s.startsWith("RIFF") && s.slice(8, 12) === "WEBP") || s.startsWith("GIF8");
}

// UN may delete or rename a photo before plants.json is rebuilt: a readable
// 404/410 through the relay (the relay's own refusals carry no CORS headers,
// so they reject as network errors and stop the batch instead) is filed here
// ({name: isoDate}) and counts as done, or the row could never finish.
const GONE_KEY = "plantPhotosGone";
export function gonePhotos(): Record<string, string> {
  try {
    const v = JSON.parse(localStorage.getItem(GONE_KEY) ?? "{}") as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, string>) : {};
  } catch {
    return {};
  }
}
function setGone(set: Record<string, string>): void {
  try {
    if (Object.keys(set).length) localStorage.setItem(GONE_KEY, JSON.stringify(set));
    else localStorage.removeItem(GONE_KEY);
  } catch {
    /* private mode */
  }
}

/** Fetch one large photo through the relay into OPFS. Resolves "gone" for
 * a 404/410 (nothing stored); throws a PhotoError otherwise. A plain GET
 * with no custom headers = a CORS simple request. */
export async function fetchPhoto(ph: Photo, signal?: AbortSignal): Promise<"ok" | "gone"> {
  if (!PLANT_RELAY) throw new PhotoError("The photo relay isn't configured", "failed");
  let buf: ArrayBuffer;
  try {
    const res = await fetch(relayUrl(ph), { signal });
    if (res.status === 404 || res.status === 410) return "gone";
    if (!res.ok) throw new PhotoError(`Couldn't download (HTTP ${res.status}) — try again on Wi-Fi`, "failed");
    buf = await res.arrayBuffer();
  } catch (e) {
    if (signal?.aborted) throw new PhotoError("paused — tap the button to continue", "aborted");
    if (e instanceof TypeError) throw new PhotoError("Couldn't reach the photo relay — needs reception", "offline");
    throw e;
  }
  if (!isImage(buf)) {
    throw new PhotoError("A download wasn't a photo — a Wi-Fi login page may be in the way", "notimage");
  }
  await writeFile(photoPath(ph), buf);
  (await localPhotos()).add(photoName(ph));
  return "ok";
}

/** Bytes of the listed photos already on the device. */
export async function photosOnDevice(photos: Photo[]): Promise<{ bytes: number; count: number; complete: boolean }> {
  const have = await localPhotos();
  const gone = gonePhotos();
  let bytes = 0;
  let count = 0;
  let complete = true;
  const mean = photos.length ? photosBytes(photos) / photos.length : 0;
  for (const ph of photos) {
    const name = photoName(ph);
    if (have.has(name)) {
      count++;
      bytes += ph.bytes ?? mean;
    } else if (!(name in gone)) complete = false;
  }
  return { bytes: Math.round(bytes), count, complete };
}
/** How many listed photos UN no longer serves (remembered by the batch). */
export function goneCount(photos: Photo[]): number {
  const gone = gonePhotos();
  return photos.filter((ph) => photoName(ph) in gone).length;
}

const WORKERS = 4;
const GONE_STREAK_LIMIT = 10;
// Files whose fetch failed with a server error (relay 502: upstream broken,
// redirected or not an image) — skipped for the rest of this session so one
// bad file can't stop every Resume at the same spot; a relaunch retries.
const failedThisSession = new Set<string>();

/** Download every listed photo not yet on the device (skipping files
 * already there, ones UN no longer serves and ones that failed with a server
 * error this session), WORKERS at a time. A network-level failure (relay
 * unreachable), Cancel or a non-image body stops the batch; what arrived
 * stays (Resume continues). Server-error files are skipped and reported at
 * the end. */
export async function downloadPhotos(
  photos: Photo[],
  signal: AbortSignal,
  progress: (done: number, total: number, bytes: number, totalBytes: number) => void,
): Promise<void> {
  const have = await localPhotos();
  const gone = gonePhotos();
  const todo = photos.filter(
    (ph) => !have.has(photoName(ph)) && !(photoName(ph) in gone) && !failedThisSession.has(photoName(ph)),
  );
  const totalBytes = photosBytes(photos);
  const mean = photos.length ? totalBytes / photos.length : 0;
  let bytes = (await photosOnDevice(photos)).bytes;
  let done = photos.length - todo.length;
  const { usage, quota } = await storageInfo();
  const remaining = totalBytes - bytes;
  if (quota && quota - usage < remaining + QUOTA_MARGIN) {
    throw new Error(
      `Not enough free space — this needs about ${Math.round(remaining / 1e6)} MB free. Delete something and try again.`,
    );
  }
  progress(done, photos.length, bytes, totalBytes);
  let next = 0;
  let streak: string[] = [];
  let failure: unknown = null;
  const worker = async () => {
    while (!failure && next < todo.length) {
      if (signal.aborted) throw new PhotoError("paused — tap the button to continue", "aborted");
      const ph = todo[next++];
      let res: "ok" | "gone";
      try {
        res = await fetchPhoto(ph, signal);
      } catch (e) {
        if (!(e instanceof PhotoError) || e.kind !== "failed" || signal.aborted) throw e;
        failedThisSession.add(photoName(ph)); // skip it, carry on
        continue;
      }
      if (res === "gone") {
        gone[photoName(ph)] = new Date().toISOString();
        streak.push(photoName(ph));
        // a long run of 404s is a broken relay or path scheme, not deletions
        if (streak.length >= GONE_STREAK_LIMIT) {
          for (const n of streak) delete gone[n];
          setGone(gone);
          throw new Error("Many photos in a row were missing — try again later.");
        }
        setGone(gone);
      } else {
        streak = [];
        bytes += ph.bytes ?? mean;
      }
      done++;
      progress(done, photos.length, Math.round(bytes), totalBytes);
    }
  };
  const runs = Array.from({ length: WORKERS }, () =>
    worker().catch((e: unknown) => {
      failure ??= e;
    }),
  );
  await Promise.all(runs);
  if (failure) throw failure;
  const failed = photos.filter((ph) => failedThisSession.has(photoName(ph))).length;
  if (failed)
    throw new PhotoError(`${failed} photo${failed === 1 ? "" : "s"} failed, will retry next time the app opens`, "failed");
}

/** Remove every stored photo and forget the "no longer served" marks. */
export async function deletePhotos(): Promise<void> {
  for (const url of objectUrls.values()) URL.revokeObjectURL(url);
  objectUrls.clear();
  await deleteDir(PLANT_PHOTO_DIR);
  localNames = null;
  setGone({});
}
