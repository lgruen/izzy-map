// Tile protocols wiring MapLibre to local OPFS PMTiles archives, with a
// live-network fallback while online.
//
//   topo://{z}/{x}/{y}   raster: OPFS topo archive -> LIST service -> blank
//   pmtiles://...        vector: TASVEG archive (OPFS file or remote URL)
import maplibregl, { type Map as MlMap } from "maplibre-gl";
import { FetchSource, FileSource, PMTiles, Protocol } from "pmtiles";
import { ARCHIVES, DATA_BASE, LIST_TOPO } from "./config";
import { opfsFile } from "./storage";

// 1x1 FULLY TRANSPARENT PNG for tiles we can't provide (offline + not
// downloaded). Review caught the previous constant decoding to a
// half-opaque BLUE pixel — offline gaps rendered as convincing fake ocean.
export const BLANK_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=";
const BLANK_PNG = Uint8Array.from(atob(BLANK_PNG_B64), (c) => c.charCodeAt(0));

let topoArchive: PMTiles | null = null;
let tasvegArchive: PMTiles | null = null;
let boundMap: MlMap | null = null;
const pmProtocol = new Protocol();

/** Give the protocol layer a map handle so archive changes (download,
 * delete) reach live sources — an errored vector source is never retried by
 * MapLibre on its own, and stale topo tiles stay cached until refreshed. */
export function bindMap(map: MlMap): void {
  boundMap = map;
}

export interface ArchiveStatus {
  topoLocal: boolean;
  tasvegLocal: boolean;
  tasvegAvailable: boolean; // local or remote reachable
}
export const status: ArchiveStatus = {
  topoLocal: false,
  tasvegLocal: false,
  tasvegAvailable: false,
};

/** (Re)open archives from OPFS. Call at startup and after downloads. */
export async function refreshArchives(): Promise<ArchiveStatus> {
  const topoFile = await opfsFile(ARCHIVES.topo);
  topoArchive = topoFile ? new PMTiles(new FileSource(topoFile)) : null;
  status.topoLocal = !!topoFile;

  const tasvegFile = await opfsFile(ARCHIVES.tasveg);
  if (tasvegFile) {
    tasvegArchive = new PMTiles(new FileSource(tasvegFile));
    status.tasvegLocal = true;
    status.tasvegAvailable = true;
  } else {
    status.tasvegLocal = false;
    // Remote fallback (range requests against R2/dev server). Registered
    // regardless of navigator.onLine — iOS standalone apps report stale
    // offline states, and a failing fetch is handled anyway.
    tasvegArchive = new PMTiles(new FetchSource(`${DATA_BASE}/${ARCHIVES.tasveg}`));
    status.tasvegAvailable = true;
  }
  // Register under the stable key "tasveg" regardless of backing source
  // (OPFS file vs remote URL), so the style can always say pmtiles://tasveg
  // and the pmtiles Protocol never self-registers a relative-URL fetch.
  pmProtocol.tiles.set("tasveg", tasvegArchive!);

  if (boundMap) {
    // Re-kick the vector source (clears MapLibre's permanent errored state)
    // and drop cached raster tiles so a fresh topo archive shows up.
    const src = boundMap.getSource("tasveg") as { setUrl?: (u: string) => void } | undefined;
    src?.setUrl?.("pmtiles://tasveg");
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
