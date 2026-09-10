// Tile protocols wiring MapLibre to local OPFS PMTiles archives, with a
// live-network fallback while online.
//
//   raster://{key}/{z}/{x}/{y}   base rasters: OPFS archive -> (seasons) R2
//                                archive | (statewide) LIST service -> blank
//   pmtiles://...                vector overlays: TASVEG, geology, pre-1750
import { addProtocol, type Map as MlMap } from "maplibre-gl";
import { FetchSource, FileSource, PMTiles, Protocol, type Header } from "pmtiles";
import {
  ARCHIVES,
  DATA_BASE,
  RASTER_KEYS,
  SEASON_KEYS,
  packOf,
  VECTOR_ARCHIVES,
  type RasterKey,
  type VectorKey,
} from "./config";
import { opfsFile } from "./storage";

// 1x1 FULLY TRANSPARENT PNG for tiles we can't provide (offline + not
// downloaded). Review caught the previous constant decoding to a
// half-opaque BLUE pixel — offline gaps rendered as convincing fake ocean.
export const BLANK_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=";
const BLANK_PNG = Uint8Array.from(atob(BLANK_PNG_B64), (c) => c.charCodeAt(0));
const blank = () => ({ data: BLANK_PNG.buffer.slice(0) });

interface RasterEntry {
  archive: PMTiles;
  local: boolean;
  /** lazily read — only local archives ever need it (bounds check) */
  header?: Promise<Header | null>;
}
const rasters = new Map<RasterKey, RasterEntry>();
let boundMap: MlMap | null = null;
const lastBacking = new Map<string, string>();
const pmProtocol = new Protocol();

const entryFor = (archive: PMTiles, local: boolean): RasterEntry => ({ archive, local });
const headerOf = (e: RasterEntry): Promise<Header | null> =>
  (e.header ??= e.archive.getHeader().catch(() => null));

/** Give the protocol layer a map handle so archive changes (download,
 * delete) reach live sources — an errored vector source is never retried by
 * MapLibre on its own, and stale raster tiles stay cached until refreshed. */
export function bindMap(map: MlMap): void {
  boundMap = map;
}

export interface ArchiveStatus {
  rasterLocal: Record<RasterKey, boolean>;
  vectorLocal: Record<VectorKey, boolean>;
}
export const status: ArchiveStatus = {
  rasterLocal: Object.fromEntries(RASTER_KEYS.map((k) => [k, false])) as Record<RasterKey, boolean>,
  vectorLocal: { tasveg: false, geology: false, pre1750: false },
};

/** True when tiles for this pack can come from somewhere right now: a local
 * archive, or (seasons) the remote one. Statewide packs also stream live. */
export function rasterAvailable(key: RasterKey): boolean {
  return rasters.has(key) || !!packOf(key).live;
}

function refreshRaster(key: string): void {
  try {
    (boundMap as unknown as { refreshTiles?: (id: string) => void } | null)?.refreshTiles?.(key);
  } catch {
    /* source not in the style yet — harmless */
  }
}

/** (Re)open archives from OPFS. Call at startup and after downloads; pass
 * rekickRemote on offline->online transitions so remote-backed sources that
 * errored while offline get retried (MapLibre never retries on its own). */
export async function refreshArchives(rekickRemote = false): Promise<ArchiveStatus> {
  for (const key of RASTER_KEYS) {
    const pack = packOf(key);
    const file = await opfsFile(pack.file);
    status.rasterLocal[key] = !!file;
    const backing = file ? `local:${file.size}:${file.lastModified}` : "remote";
    const changed = lastBacking.get(key) !== backing;
    lastBacking.set(key, backing);
    if (file) {
      if (changed) rasters.set(key, entryFor(new PMTiles(new FileSource(file)), true));
    } else if (pack.live) {
      // statewide services stream straight from LIST while online
      rasters.delete(key);
    } else if (changed || rekickRemote) {
      // Sparse season: consult the R2 archive so absent tiles are a directory
      // lookup, not a network miss. A FRESH instance on re-kick: pmtiles'
      // SharedPromiseCache memoizes even a REJECTED header promise.
      rasters.set(key, entryFor(new PMTiles(new FetchSource(`${DATA_BASE}/${pack.file}`)), false));
    }
    if (changed || rekickRemote) refreshRaster(key);
  }

  for (const key of VECTOR_ARCHIVES) {
    const file = await opfsFile(ARCHIVES[key]);
    status.vectorLocal[key] = !!file;
    const backing = file ? `local:${file.size}:${file.lastModified}` : "remote";
    const changed = lastBacking.get(key) !== backing;
    lastBacking.set(key, backing);
    if (!changed) {
      // Unchanged backing: keep the PMTiles instance (its header/directory
      // cache) and normally skip the setUrl churn (TileJSON + in-view tile
      // refetch). Exception: an unchanged "remote" on an explicit online
      // re-kick — a remote source that errored while offline is never
      // retried by MapLibre, and "remote" -> "remote" is exactly the state
      // the window 'online' listener fires in (review finding — without
      // this the listener was dead code for remote-only archives).
      if (!(rekickRemote && !file)) continue;
      // A FRESH instance is required: pmtiles' SharedPromiseCache memoizes
      // even a REJECTED header promise, so re-kicking the retained instance
      // would replay the offline error forever (verified in pmtiles source).
      pmProtocol.tiles.set(
        key, new PMTiles(new FetchSource(`${DATA_BASE}/${ARCHIVES[key]}`)));
      (boundMap?.getSource(key) as { setUrl?: (u: string) => void } | undefined)
        ?.setUrl?.(`pmtiles://${key}`);
      continue;
    }
    // Remote fallback (range requests against R2/dev server) when no local
    // file — registered regardless of navigator.onLine (it lies on iOS),
    // and a failing fetch is handled anyway. Stable keys keep the style's
    // pmtiles://<key> urls valid and stop the pmtiles Protocol from
    // self-registering a relative-URL fetch.
    const archive = file
      ? new PMTiles(new FileSource(file))
      : new PMTiles(new FetchSource(`${DATA_BASE}/${ARCHIVES[key]}`));
    pmProtocol.tiles.set(key, archive);
    // Re-kick the live source (clears MapLibre's permanent errored state).
    (boundMap?.getSource(key) as { setUrl?: (u: string) => void } | undefined)
      ?.setUrl?.(`pmtiles://${key}`);
  }
  return status;
}

/** Web Mercator tile containing a lon/lat at zoom z. */
export function tileAt(lon: number, lat: number, z: number): { x: number; y: number } {
  const n = 2 ** z;
  const x = Math.floor(((lon + 180) / 360) * n);
  const y = Math.floor(((1 - Math.asinh(Math.tan((lat * Math.PI) / 180)) / Math.PI) / 2) * n);
  return { x: Math.max(0, Math.min(n - 1, x)), y: Math.max(0, Math.min(n - 1, y)) };
}

/** Tile -> lon/lat bounds (west, south, east, north). */
function tileBounds(z: number, x: number, y: number): [number, number, number, number] {
  const n = 2 ** z;
  const lon = (i: number) => (i / n) * 360 - 180;
  const lat = (j: number) => (Math.atan(Math.sinh(Math.PI * (1 - (2 * j) / n))) * 180) / Math.PI;
  return [lon(x), lat(y + 1), lon(x + 1), lat(y)];
}

/** A miss inside a LOCAL archive's zoom range and bounds is authoritative
 * (pruned ocean, or no imagery that season) — never a reason to hit the
 * network. Outside its bounds the live service may still have the tile. */
async function coveredBy(e: RasterEntry, z: number, x: number, y: number): Promise<boolean> {
  const h = await headerOf(e);
  if (!h) return false;
  if (z < h.minZoom || z > h.maxZoom) return false;
  const [w, s, ee, n] = tileBounds(z, x, y);
  return w >= h.minLon - 1e-9 && ee <= h.maxLon + 1e-9 && s >= h.minLat - 1e-9 && n <= h.maxLat + 1e-9;
}

export function registerProtocols(): void {
  addProtocol("pmtiles", pmProtocol.tile);

  addProtocol("raster", async (params, abort) => {
    const m = params.url.match(/^raster:\/\/([a-z0-9]+)\/(\d+)\/(\d+)\/(\d+)$/);
    if (!m) throw new Error("bad raster url: " + params.url);
    const key = m[1] as RasterKey;
    if (!RASTER_KEYS.includes(key)) throw new Error("unknown raster pack: " + key);
    const pack = packOf(key);
    const [z, x, y] = [Number(m[2]), Number(m[3]), Number(m[4])];

    const e = rasters.get(key);
    if (e) {
      try {
        const t = await e.archive.getZxy(z, x, y);
        if (t?.data) return { data: t.data };
        if (e.local && (await coveredBy(e, z, x, y))) return blank();
      } catch {
        /* corrupt/unreadable archive must not block the fallback */
      }
    }
    if (pack.live) {
      try {
        // Always attempt (no navigator.onLine gate — it lies on iOS after
        // backgrounding); offline the fetch fails fast and we fall through.
        const res = await fetch(pack.live(z, x, y), { signal: abort?.signal });
        if (res.ok) return { data: await res.arrayBuffer() };
      } catch {
        /* offline or abort — fall through to blank */
      }
    }
    return blank();
  });
}

/** What the season stack shows at a tile: the newest LOCAL season <= cutoff
 * that has it. Remote archives are not probed — a pmtiles getZxy on an R2
 * archive downloads the whole tile again per probe (review finding) — so
 * `unknown` is true when a non-downloaded season <= cutoff could be
 * streaming there instead. */
export async function seasonAt(
  z: number,
  x: number,
  y: number,
  cutoff: number,
): Promise<{ idx: number | null; unknown: boolean }> {
  let unknown = false;
  for (let i = Math.min(cutoff, SEASON_KEYS.length - 1); i >= 0; i--) {
    const e = rasters.get(SEASON_KEYS[i]);
    if (!e) continue;
    if (!e.local) {
      unknown = true;
      continue;
    }
    try {
      const t = await e.archive.getZxy(z, x, y);
      if (t?.data) return { idx: i, unknown: false };
    } catch {
      /* unreadable archive: treat as absent */
    }
  }
  return { idx: null, unknown };
}
