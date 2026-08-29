# IzzyMap

Offline Tasmania vegetation map for hiking — a home-screen PWA for iPhone.

Shows the LIST **Topographic** basemap with the **TASVEG 5.0** vegetation
community layer on top (official colours, outlines, and code labels). Tap a
polygon to see which plant community you're in, with a link into the full
*From Forest to Fjaeldmark* description — all fully offline once set up.

Built for personal use on a single phone. Not affiliated with the Tasmanian
Government.

## How it works

- **App**: Vite + TypeScript + [MapLibre GL JS](https://maplibre.org/), served
  from GitHub Pages, installed via Safari's Add to Home Screen.
- **Vegetation layer**: TASVEG 5.0 polygons converted to vector tiles
  ([PMTiles](https://protomaps.com/docs/pmtiles)), downloaded once (statewide)
  into the browser's OPFS storage.
- **Topo basemap**: fetched live from LIST tile services when online; offline
  coverage via a single statewide raster pack (zoom ≤ 15) downloaded in-app.
- **Geology overlay**: MRT's statewide 1:500,000 units as a second vector
  layer, switched with vegetation (one overlay at a time).
- **Community descriptions**: the phone fetches the *From Forest to
  Fjaeldmark* chapter PDFs from nre.tas.gov.au (via a transparent,
  non-caching CORS relay — the PDFs are not redistributable and are never
  committed here or stored on our hosting; see `docs/LICENSING.md`).

See `CLAUDE.md` for the full architecture and maintenance guide.

## Data sources & attribution

- Topographic Basemap from [theLIST](https://www.thelist.tas.gov.au)
  © State of Tasmania —
  [CC BY 3.0 AU](https://creativecommons.org/licenses/by/3.0/au/)
- TASVEG 5.0 from [theLIST](https://listdata.thelist.tas.gov.au/opendata/)
  © State of Tasmania —
  [CC BY 3.0 AU](https://creativecommons.org/licenses/by/3.0/au/)
- Geology 1:500,000 from Mineral Resources Tasmania © State of Tasmania —
  [CC BY 3.0 AU](https://creativecommons.org/licenses/by/3.0/au/)
- Kitchener, A. and Harris, S. (2013). *From Forest to Fjaeldmark:
  Descriptions of Tasmania's Vegetation*. Edition 2. DPIPWE, Tasmania.
  © Government of Tasmania — all rights reserved (not included in this repo).

## Licence

Code in this repository: MIT (see `LICENSE`). Data licences as above.
