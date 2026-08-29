// Tile protocols wiring MapLibre to local OPFS PMTiles archives, with a
// live-network fallback while online.
//
//   topo://{z}/{x}/{y}   raster: OPFS topo archive -> LIST service -> blank
//   pmtiles://...        vector: TASVEG archive (OPFS file or remote URL)
import maplibregl from "maplibre-gl";
import { FetchSource, FileSource, PMTiles, Protocol } from "pmtiles";
import { ARCHIVES, DATA_BASE, LIST_TOPO } from "./config";
import { opfsFile } from "./storage";

// 1x1 transparent PNG for tiles we can't provide (offline + not downloaded).
const BLANK_PNG = Uint8Array.from(
  atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="),
  (c) => c.charCodeAt(0),
);

let topoArchive: PMTiles | null = null;
let tasvegArchive: PMTiles | null = null;
const pmProtocol = new Protocol();

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
    // Remote fallback (range requests against R2/dev server) while online.
    tasvegArchive = navigator.onLine
      ? new PMTiles(new FetchSource(`${DATA_BASE}/${ARCHIVES.tasveg}`))
      : null;
    status.tasvegAvailable = !!tasvegArchive;
  }
  // Register under the stable key "tasveg" regardless of backing source
  // (OPFS file vs remote URL), so the style can always say pmtiles://tasveg.
  if (tasvegArchive) pmProtocol.tiles.set("tasveg", tasvegArchive);
  else pmProtocol.tiles.delete("tasveg");
  return status;
}

export function registerProtocols(): void {
  maplibregl.addProtocol("pmtiles", pmProtocol.tile);

  maplibregl.addProtocol("topo", async (params, abort) => {
    const m = params.url.match(/^topo:\/\/(\d+)\/(\d+)\/(\d+)$/);
    if (!m) throw new Error("bad topo url: " + params.url);
    const [z, x, y] = [Number(m[1]), Number(m[2]), Number(m[3])];

    if (topoArchive) {
      const t = await topoArchive.getZxy(z, x, y);
      if (t?.data) return { data: t.data };
      // In-bbox gaps are pruned ocean -> blank is correct offline behaviour;
      // fall through to network when online for anything outside the archive.
    }
    if (navigator.onLine) {
      try {
        const res = await fetch(LIST_TOPO(z, x, y), { signal: abort?.signal });
        if (res.ok) return { data: await res.arrayBuffer() };
      } catch {
        /* offline race or abort — fall through to blank */
      }
    }
    return { data: BLANK_PNG.buffer.slice(0) };
  });
}
