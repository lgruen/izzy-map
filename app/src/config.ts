// Central config. DATA_BASE is where the .pmtiles archives + data-manifest
// live: Cloudflare R2 in production, the vite dev middleware locally.
export const DATA_BASE: string =
  import.meta.env.VITE_DATA_BASE ?? (import.meta.env.DEV ? "/dev-data" : "");

// LIST topo tile service — NOTE the path is {z}/{y}/{x}: row BEFORE column.
export const LIST_TOPO = (z: number, x: number, y: number) =>
  `https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic/MapServer/tile/${z}/${y}/${x}`;

export const TOPO_MAXZOOM = 15; // raster archive ceiling; overzooms beyond

export const ARCHIVES = {
  tasveg: "tasveg.pmtiles",
  geology: "geology.pmtiles",
  topo: "topo_tas.pmtiles",
} as const;

/** Vector overlay archives served through the pmtiles protocol. */
export const VECTOR_ARCHIVES = ["tasveg", "geology"] as const;
export type VectorKey = (typeof VECTOR_ARCHIVES)[number];

export const ATTRIBUTION =
  '<a href="https://www.thelist.tas.gov.au">Topographic Basemap &amp; TASVEG 5.0 from theLIST</a>, Geology from Mineral Resources Tasmania — © State of Tasmania (CC BY 3.0 AU)';

// Tasmania-ish default view for before the first GPS fix
export const HOME = { center: [146.6, -42.2] as [number, number], zoom: 7 };
