# Licensing boundaries (read before touching data flows)

This repo is **public**. Three licence regimes apply — the architecture is
shaped around keeping them separate.

## 1. CC BY 3.0 AU — free to use, redistribute, derive (with attribution)

- **TASVEG 5.0** vector data and everything derived from it: the PMTiles
  archives, the colour table extracted from `TASVEG_5_0.qml`, community
  codes/names/groups. Source: listdata.thelist.tas.gov.au/opendata/.
- **LIST Topographic basemap tiles** (`Basemaps/Topographic` MapServer) and
  Hillshade. The service explicitly advertises bulk export
  (`exportTilesAllowed: true`); the LIST Web Services T&C (Dec 2014, 8
  clauses) contain no prohibition on caching or offline storage — clause 7
  delegates licensing to each service's `copyrightText`, which is CC BY.

Required attribution format (from the Land Tasmania attribution guidelines):
`<dataset/service name> from theLIST © State of Tasmania` + CC BY 3.0 AU
badge/link. The app shows this on the About screen and map attribution.

## 2. © All rights reserved — must NEVER enter this repo or our hosting

- **From Forest to Fjaeldmark** (Ed. 2) chapter PDFs and any text extracted
  from them. Copyright page verified: "no part may be reproduced … without
  the prior written permission of the publisher and creators."
- Handling: the phone fetches the PDFs from nre.tas.gov.au for ordinary
  private use. Because that server sends no CORS headers, the request passes
  through a **transparent, non-caching relay** (Cloudflare Worker
  `pipeline/f2f-proxy/`): it forwards GET/HEAD for exactly the 11 known
  chapter files, only for this app's origins (403 otherwise), with
  `cache: "no-store"` upstream and `Cache-Control: no-store` downstream so
  nothing is ever stored at the edge. The relay must stay that way — never
  add caching, widen the allowlist, or open the Origin check.
- This repo may only contain `f2f_index.json` — a mapping of VEGCODE →
  chapter file + page number, which is facts, not content. Do not commit
  PDFs, extracted text, or host either on Pages/R2. `.gitignore` blocks
  `*.pdf` and `f2f_pdfs/` as a guard.

## 3. CC BY-NC-ND — do not use at all

- **TASMAP raster products**: `Basemaps/TasmapRaster`, `Tasmap25K/100K/250K/
  500K` services and the paid tasmapshop.au GeoTIFF/geoPDF products.
  Non-commercial, no-derivatives, `exportTilesAllowed: false`. The
  vector-derived `Topographic` basemap (regime 1) is the one we use.
