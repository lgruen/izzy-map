// Tile protocols wiring MapLibre to local OPFS PMTiles archives, with a
// live-network fallback while online.
//
//   topo://{z}/{x}/{y}   raster: OPFS topo archive -> LIST service -> blank
//   pmtiles://...        vector overlays: TASVEG + geology (OPFS or remote)
import maplibregl, { type Map as MlMap } from "maplibre-gl";
import { FetchSource, FileSource, PMTiles, Protocol } from "pmtiles";
import { ARCHIVES, DATA_BASE, LIST_TOPO, VECTOR_ARCHIVES, type VectorKey } from "./config";
import { opfsFile } from "./storage";

// 1x1 FULLY TRANSPARENT PNG for tiles we can't provide (offline + not
// downloaded). Review caught the previous constant decoding to a
// half-opaque BLUE pixel — offline gaps rendered as convincing fake ocean.
export const BLANK_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=";
const BLANK_PNG = Uint8Array.from(atob(BLANK_PNG_B64), (c) => c.charCodeAt(0));

let topoArchive: PMTiles | null = null;
let boundMap: MlMap | null = null;
const lastBacking = new Map<string, string>();
const pmProtocol = new Protocol();

/** Give the protocol layer a map handle so archive changes (download,
 * delete) reach live sources — an errored vector source is never retried by
 * MapLibre on its own, and stale topo tiles stay cached until refreshed. */
export function bindMap(map: MlMap): void {
  boundMap = map;
}

export interface ArchiveStatus {
  topoLocal: boolean;
  vectorLocal: Record<VectorKey, boolean>;
}
export const status: ArchiveStatus = {
  topoLocal: false,
  vectorLocal: { tasveg: false, geology: false },
};

/** (Re)open archives from OPFS. Call at startup and after downloads. */
export async function refreshArchives(): Promise<ArchiveStatus> {
  const topoFile = await opfsFile(ARCHIVES.topo);
  topoArchive = topoFile ? new PMTiles(new FileSource(topoFile)) : null;
  status.topoLocal = !!topoFile;

  for (const key of VECTOR_ARCHIVES) {
    const file = await opfsFile(ARCHIVES[key]);
    status.vectorLocal[key] = !!file;
    const backing = file ? `local:${file.size}:${file.lastModified}` : "remote";
    const changed = lastBacking.get(key) !== backing;
    lastBacking.set(key, backing);
    if (!changed) continue; // avoid pointless TileJSON/tile refetch churn
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
  if (boundMap) {
    try {
      (boundMap as unknown as { refreshTiles: (id: string) => void }).refreshTiles("topo");
    } catch {
      /* older maplibre or source not ready — harmless */
    }
  }
  return status;
}

export function registerProtocols(): void {
  maplibregl.addProtocol("pmtiles", pmProtocol.tile);

  maplibregl.addProtocol("topo", async (params, abort) => {
    const m = params.url.match(/^topo:\/\/(\d+)\/(\d+)\/(\d+)$/);
    if (!m) throw new Error("bad topo url: " + params.url);
    const [z, x, y] = [Number(m[1]), Number(m[2]), Number(m[3])];

    if (topoArchive) {
      try {
        const t = await topoArchive.getZxy(z, x, y);
        if (t?.data) return { data: t.data };
        // In-bbox gaps are pruned ocean -> blank is correct offline
        // behaviour; fall through to network for anything outside.
      } catch {
        /* corrupt/unreadable archive must not block the network fallback */
      }
    }
    try {
      // Always attempt (no navigator.onLine gate — it lies on iOS after
      // backgrounding); offline the fetch fails fast and we fall through.
      const res = await fetch(LIST_TOPO(z, x, y), { signal: abort?.signal });
      if (res.ok) return { data: await res.arrayBuffer() };
    } catch {
      /* offline or abort — fall through to blank */
    }
    return { data: BLANK_PNG.buffer.slice(0) };
  });
}
