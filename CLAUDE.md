# IzzyMap — maintainer guide (written by Claude, for future Claude)

Offline Tasmania vegetation map PWA for one iPhone (Leo's partner) and the
household iPad. All changes happen through Claude Code sessions with Leo. The approved plan that
started this project: `~/.claude/plans/this-is-a-completely-vectorized-bee.md`
(research findings summarized there and in docs/).

## Non-negotiables

1. **docs/LICENSING.md first.** From Forest to Fjaeldmark content and the
   City of Hobart tree data sheets must never be committed or served from
   our hosting (public repo!). The LIST
   aerial/Tasmap rasters are CC BY-NC-ND: tiles stay BYTE-FOR-BYTE as
   served (no re-encoding, no merging across services), non-commercial,
   attributed — the licence text governs, not the ArcGIS export flag.
   CC BY / CC BY-NC-ND attribution stays in the app.
2. **Fully offline is the product.** Any change must keep working in airplane
   mode after setup: no CDN references, glyphs/sprites self-hosted, tiles
   never routed through the service worker cache (they live in OPFS PMTiles;
   the two search indexes under `app/public/search/` are the ONE JSON the
   SW precaches — app shell, not map data).
3. **Target device is a small iPhone**, plus an iPad in landscape with a
   keyboard/trackpad. Home-screen web app (iOS 17+ behaviours assumed:
   60%-of-disk quota, ITP exemption, persist() heuristic). Surface storage
   sizes in UI; keep archives lean. Layout is keyed on viewport width
   (`min-width: 700px` → side cards), never on the device/UA (iPadOS reports
   a Mac UA; Split View gives phone-width windows). Wi-Fi-only iPads have no
   GPS: the geolocate error is announced, never silently spun.
4. **Device access:** Leo has an **Android** phone (secondary test target —
   the PWA should work there too); the only real iPhone is the partner's.
   iOS testing therefore runs on the Xcode iOS Simulator, with occasional
   short verification sessions on the partner's phone — anything sent to
   that phone must be self-explanatory and low-effort (auto-running probe,
   copy-results buttons).

## Key endpoints & data facts (verified 2026-08-29)

- Topo tiles: `https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic/MapServer/tile/{z}/{y}/{x}`
  — EPSG:3857, 256px PNG, z0–18, CORS on. **Path is z/row/col — y before x!**
- Aerial photos (verified 2026-09-10): `Basemaps/Orthophoto` = statewide
  "best available" mosaic (MIXED/JPEG q75, z0–19; ocean = one constant
  1,652-byte JPEG `#1e525f`); `Basemaps/AerialPhoto2020…2026` = flying
  seasons 2019–20 … 2025–26, each a PATCHWORK (6–15 % of land tiles at z12),
  no-imagery = HTTP 404 or a fully transparent PNG (two encodings seen: 876
  and 889 bytes), project edges are PNG with alpha (up to ~130 KB — season
  packs are 200–1000 MB each, mostly edge tiles). All CC BY-NC-ND 3.0 AU (2026's badge is missing — see
  LICENSING.md). Coverage/footprint indexes: `Public/Indexes` layers 100
  ("Digital Imagery Mosaic Index": CAP_SEASON, dates, resolution per
  project) and 107 ("Tas Imagery and LiDAR Program": planned captures).
- Tasmap scans: `Basemaps/TasmapRaster` (MIXED, z0–16; 500K/250K low zoom,
  100K z13–14, 25K sheets at z15 byte-identical to `Tasmap25K`). CC BY-NC-ND.
  Because each zoom comes from a DIFFERENT scanned series, a blank z14 tile
  says nothing about its z15 children — top-down pruning is unsafe here
  (the build's validation caught it, 2026-09-10); `prune: "blank"` fetches
  every candidate and only drops blank tiles per tile. Result: 3.24 GB,
  144k tiles; at z15 the dropped tiles are all transparent beyond-sheet
  PNGs, at z13–14 uniform printed-sea JPEGs (#aae0fc = the Tasmap base
  background), at z≤12 #ccffff sea and white margins.
- Blank-tile facts the pipeline relies on: byte-identical sentinels are
  learned per level (≥ 8 identical tiles; non-image 200 bodies are rejected
  before they can become one); a tile that 404s or equals a sentinel has no
  descendants. `prune: blank@10` means z10 candidates are filtered by their
  z9 parents (~230 m/px), so a project smaller than a few z9 pixels could in
  principle vanish — hence two validations per build: 40 pruned z15 tiles
  (30 at project edges) re-fetched live, and `--check-footprints`, which
  re-fetches the z15 tile under every LIST mosaic-index project centroid.
- TASVEG 5.0: `https://listdata.thelist.tas.gov.au/opendata/data/LIST_TASVEG_50_STATEWIDE.zip`
  (1.79 GB; shapefile EPSG:28355, 482,138 polygons, 156 communities keyed by
  `VEGCODE`; official solid-fill colours in bundled `TASVEG_5_0.qml`).
  Unpacked dir also available: `.../opendata/data/LIST_TASVEG_50_STATEWIDE/`.
- F2F chapter PDFs: `https://nre.tas.gov.au/Documents/f2f_*.pdf` (~36 MB
  total; chapters map 1:1 to the 11 VEG_GROUPs).
- Attribute fields: VEGCODE, VEGCODE_D (name), VEG_GROUP, FOREST_STR,
  NOTABLE_TR/TD, WEED_TYPE/_D, SOURCE_*.
- Search datasets (verified 2026-09-12; all CC BY 3.0 AU © State of
  Tasmania, `pipeline/build_gazetteer.py`):
  - Nomenclature: WFS `https://services.thelist.tas.gov.au/arcgis/services/Public/OpenDataWFS/MapServer/WFSServer`,
    type `LIST_Nomenclature`, 35,835 points (NOM_REG_NO, FEAT_NAME,
    DUALNAME, FEAT_TYPE, FEAT_GROUP, STATUS, DISP_STAT, NAMETYPE, MUNY).
    Kept STATUS "Normal" + DISP_STAT "DISPLAYED", minus FEAT_TYPE
    Electorate / Municipal Area / Land District and 36 standalone
    Aboriginal names already present inside a dual name → 32,753 rows.
  - Transport Segments: REST `Public/TopographyAndRelief/MapServer/8`,
    273,376 polylines, 2000/page (~140 pages); only PRI_NOMREG/SEC_NOMREG
    (= register number) pulled → one bbox per road, 100 % of register roads
    covered. Routes like "C645" have no segment field → almost no bbox.
  - Named Feature Extents: `.../opendata/data/LIST_NAMED_FEATURE_EXTENT_STATEWIDE.zip`,
    7,344 polygons (MGA55) → bboxes for hills/bays/mountains/localities.
  - Locality and Postcode Areas: WFS, 777 polygons → suburb per row by
    point-in-polygon (93.5 % of rows get one).
  - Address Points: `.../opendata/data/LIST_ADDRESS_POINTS_STATEWIDE.zip`
    (92.9 MB, 301,619 points, MGA55) → 13,679 (street, locality) groups ×
    261,176 distinct house numbers (units collapsed to the building
    number); 10,727 property names kept after dropping lot/unit noise and
    names occurring in ≥ 5 localities; 96 address-derived roads added where
    the register has no same-named road nearby.
  - WFS gotchas: empty fields arrive as the STRING "null"; `count` is
    silently capped at 1000; with `srsName=EPSG:4326` coordinates are
    [lat, lon] (EPSG axis order) — omit srsName → [lon, lat] (the build
    detects the order from the data); `resultType=hits` returns an EMPTY
    body for GEOJSON output, so page until a short page. ArcGIS REST reports
    errors inside HTTP-200 bodies.
- Hobart significant trees (verified 2026-09-12; CC BY 4.0 © City of
  Hobart, `pipeline/build_trees.py`): ArcGIS Online hosted feature service
  `https://services1.arcgis.com/NHqdsnvwfSTg42I8/arcgis/rest/services/ENVIRON_Significant_Tree_Locations/FeatureServer`
  (portal item 9b31f3f6acb14bb2a5869b5e17707155 — `licenseInfo` links
  creativecommons.org/licenses/by/4.0/, `accessInformation` "City of
  Hobart", item modified 2025-08-11; maxRecordCount 1000). Layer 1 =
  points (460), layer 4 = areas (34 polygons: groups/hedges/avenues).
  Fields: Planning_Ref_No (letter+number = 2012/2020 register, plain
  numbers = March-2024 draft amendment PSA-22-4; 277 distinct refs),
  Botanical_ID (layer 1: smallint with a ~354-name coded-value domain in
  the layer definition; layer 4: the code AS A STRING plus Botanical_Name),
  Number_Trees, Object_Metadata (free text), Session_Key (13-code
  position-accuracy domain), Data_Sheet_URL (282 distinct PDF items,
  446 MB total, median 0.6 MB, 1–2 A4 pages each; NO licence — item
  licenseInfo null). Sheet fetch from the browser: ONLY
  `https://www.arcgis.com/sharing/rest/content/items/<id>/data` sends CORS
  headers on its 302 to signed S3 (the `hobartcc.maps.arcgis.com` form in
  Data_Sheet_URL does not); the preflight allow-list lacks `Range`, so the
  request must stay a simple GET. Council register PDF (common names +
  addresses; the service has neither): 76.5 MB, 465 pages, "Updated March
  2020", hobartcity.com.au answers scripts with 403 → browser-save it to
  `pipeline/cache/trees/register.pdf`; `pdftotext -layout`; 2012-era data
  sheets embed a subset font without ToUnicode → glyph codes = ASCII − 29.

## Architecture

(see README for user-facing summary; plan file for rationale)

- `app/` — Vite + TS + MapLibre GL JS. No framework. The overlay set is
  hand-curated in code (see "Add an overlay map" below); archives + sizes
  come from `data-manifest.json`, generated by `pipeline/upload_r2.sh` and
  served from R2. Two datasets bypass R2 entirely: `app/public/search/
  gazetteer.json` + `addresses.json` (committed, precached by the SW as
  app shell via the explicit `search/*.json` glob in vite.config.ts —
  stable unhashed URLs) and `app/src/generated/trees.json` (committed,
  statically imported by style.ts as bundled GeoJSON). `app/src/search.ts`
  = search panel, scoring, pin + pill; `app/src/sheets.ts` = tree
  data-sheet fetch/store, shared by details.ts and ui.ts (neither may
  import the other).
- `pipeline/` — data prep scripts (bash/python via uv; tippecanoe/gdal/
  pmtiles from brew). Outputs to `data/` (gitignored), uploaded to R2 —
  except `build_gazetteer.py` and `build_trees.py`, whose outputs are
  committed (see above); their caches live under `pipeline/cache/`.
  Raster packs are declared in `pipeline/packs.json` (key, service, file,
  prune rule, attribution, optional season/note/licence_override) and built
  by `build_raster.py`; `upload_r2.sh` derives manifest keys from it; the
  app mirrors the key list by hand in `app/src/config.ts` (`RASTER_PACKS`).
- `probe/` — standalone device capability probe page.
- Hosting: GitHub Pages (app), Cloudflare R2 (archives). CI via Actions.

## Workflows

- **Adversarial review is the default ship gate.** Before committing any
  substantive change, run adversarial review rounds (fresh-eyes hunt for
  real failure modes in the diff, not style nits) and address findings
  autonomously until returns diminish. Don't wait to be asked. The first
  two days' rounds caught ~40 real bugs (fake-ocean tile, SW precache
  miss, CORS never applied, Victorian mangroves in a Tasmania crop, …).

- **Refresh TASVEG (e.g. 6.0 release):** update URL/version in
  `pipeline/build_tasveg.sh`, run pipeline, verify counts/colors, upload to
  R2, bump layer manifest version.
- **Add an overlay map (e.g. geology):** run a pipeline variant on the new
  dataset → PMTiles + colour table; then extend `app/src/config.ts`
  (ARCHIVES), `style.ts` (source + layers), `ui.ts` (download row), and
  `upload_r2.sh` (manifest keys). Hand-curated by design — a handful of
  files, one pattern to follow (TASVEG is the template).
- **Add an overlay map — tiny dataset variant (trees is the template):**
  when the whole dataset is a few hundred KB, skip PMTiles/R2/manifest/
  download row: `pipeline/build_<x>.py` → `app/src/generated/<x>.json`
  (GeoJSON carrying only ids + a facts table, licence guard in the script)
  → static import in `style.ts`, geojson source(s) + layers appended at the
  END of the layer list (before `selected-outline`/`selected-point`; the
  trees test pins that order — extend it) → an independent `LayerState` boolean (default off,
  restored in main.ts, `clearDetails()` when it flips) → checkbox row under
  "Also show" in the Layers sheet (ui.ts; bump the `.lay-row` count in the
  test) → tap handling in details.ts (a `TREE_LAYERS`-style list queried
  with a padded box, topmost first) → `ATTRIBUTION_<X>` in config.ts on
  every source + About. Map text must be Latin-1 (`0-255.pbf` glyphs).
- **Extend topo coverage (e.g. z16):** bump `maxzoom` in `packs.json`,
  re-run `build_raster.py --pack topo` (disk cache makes it incremental),
  re-upload. Re-validate the ocean-prune threshold first (see the topo
  `size<1000@13` rule in build_raster.py).
- **Add a raster pack (base map or season):** add an entry to
  `pipeline/packs.json` → `build_raster.py --measure 1500 --pack <key>` (time
  it first; ~70 tiles/s at 8 concurrent in 2026-09) → `--pack <key>` (the
  licence guard reads the live copyrightText) → `upload_r2.sh data/<file>`
  → mirror the key in `RASTER_PACKS` (config.ts) and, for a base, add it to
  `BASES`/`BASE_ROWS`/`rasterVisibility`; a season only needs `SEASON_KEYS`
  (chronological!). `pipeline/run_pulls.sh` chains build+upload for all.
- **Refreshing a season (2025–26 is INCOMPLETE — still being flown and
  published as of 2026-09-10):** `python3 pipeline/build_raster.py --pack
  aerial2026 --fresh` (wipes that pack's tile cache incl. the cached
  "absent" markers, ~10–40k requests, minutes with keep-alive) →
  `build_raster.py --check-footprints --pack aerial2026` → `pipeline/upload_r2.sh
  data/aerial_2026.pmtiles`. The manifest's `bytes` changes, so installed
  phones see an **Update** button in Offline maps; the pack's `note` in
  packs.json is shown under the row. When LIST adds the CC badge to the
  2026 service, delete its `licence_override` (the guard would otherwise
  abort on the changed text). Check the season list yearly: a new
  `AerialPhotoYYYY` service = one new packs.json entry + `SEASON_KEYS`.
- **Detailed areas (in-app, per layer, user-framed):** Offline maps →
  "Download this area…" → dashed frame follows the map → Next → layers
  (aerial / seasons / paper map / topo) + detail (z16–18) + estimate →
  Download. `app/src/areas.ts`: tiles fetched by the device from the LIST
  service (6 concurrent, image-magic checked, 404 = absent), stored as
  `areas/<id>/<layer>/part-NNNN.bin` + `.json` index (64 MB parts, written
  together on close; an interrupted part is redone), registry
  `areas/areas.json`. Seasons only fetch under z15 tiles the season's
  archive has (`archiveTile`). The `raster://` protocol consults area stores
  first. Estimates use `meanTileBytes` per pack; `MAX_AREA_TILES` (60k per
  layer) caps a download — the framing bar and the setup sheet refuse
  larger frames. Registry writes are serialised (`withRegistry`); an
  interrupted part is closed and indexed, not discarded; Delete waits for
  the layer's download to stop first (an open writable makes removeEntry
  fail and would orphan gigabytes).
- **Refresh place names / addresses (yearly; address points are
  republished quarterly):** `uv run --with shapely --with pyshp --with
  pyproj python3 pipeline/build_gazetteer.py [--fresh]` (cache
  `pipeline/cache/gazetteer/`, ~80 s cold / 9 s warm on 2026-09-12; the
  segments pull is cached one file per page → resumable; the two LISTdata
  zips can be dropped into the cache by hand). Count tripwires (31–34k kept
  names, 13–15k streets, 250–275k house numbers) are pinned to the 2026-09
  pull and WILL drift with LIST republishes — eyeball the stage output
  (dropped counts, samples, FEAT_TYPE histogram → new admin types into
  `DROP_TYPES`) and widen; they catch truncated pulls, not growth. Outputs
  go into the public repo (facts only — LICENSING.md §1). The on-disk
  format at `version: 1` must stay ADDITIVE: the URL is unhashed, so a
  resident old app after a background SW update reads the NEW file; bump
  `version` only for a breaking change (the panel then shows "Update the
  app to search"; `loadIndexes()` treats a version mismatch as permanent
  for that build). `npm run build` → `check-dist.mjs` asserts both files
  exist, parse, are version 1, hold > 30k rows / > 13k streets and appear
  in `dist/sw.js`.
- **Refresh significant trees:** `python3 pipeline/build_trees.py
  [--skip-enrich] [--fresh]` (stdlib only; cache `pipeline/cache/trees/`,
  ~50 s cold / 2 s warm; `--fresh` drops cached JSON/text but keeps the
  PDFs). Needs `pipeline/cache/trees/register.pdf` saved from a browser
  (403 to scripts) and `pdftotext` (poppler). The licence guard aborts
  unless the portal item names CC BY 4.0 AND "City of Hobart". Enrichment
  reads the register first (214 of 277 refs; asserts ≥ 200) and downloads
  data sheets ONLY for the remaining refs (63 on 2026-09-12; asserts
  ≤ 100 — never all 282). Read the run report: register/service conflicts
  (D7 Pinus vs Populus, H2 Ulmus vs Fraxinus) drop the common name and
  fall back to the botanical one; A1's points carry A5's trees upstream.
  Result 2026-09-12: 275/277 common names, 277/277 addresses,
  `app/src/generated/trees.json` 233 KB. The Downloads row's total
  (`SHEETS_TOTAL_BYTES`, ~446 MB) follows the `sheets` table. If the
  council republishes sheets under new item ids, phones keep the old
  `trees/<id>.pdf` files (the row's Delete only removes current ids).
- **Deploy app:** push to main → Pages workflow.
- **Do not re-upload topo unless its tiles changed:** `build_raster.py`
  writes extra metadata (`copyright_text`, `built`, …) into the archive, so
  a rebuild of identical tiles has a different byte size and every installed
  phone would be offered a 2 GB "Update" (the app compares manifest bytes to
  the installed file). `run_pulls.sh` deliberately excludes topo.
- **iPad checks:** `node app/scripts/shot-ipad.mjs` (dev server on :5199)
  for landscape/portrait screenshots; Xcode iPad simulators (Pro 11, mini)
  for home-screen install + hardware-keyboard Escape; Playwright project
  `webkit-ipad` runs the wide-layout tests in CI.

## Gotchas discovered so far

- **MapLibre 6 is ESM-only and resolves its Web Worker from
  `import.meta.url` at runtime** — inside a Vite bundle that URL points at a
  file that doesn't exist, so vector tiles silently never render in the
  BUILT app while every dev-server test passes. main.ts wires
  `setWorkerUrl(import "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url")`
  (the `?worker&url` form bundles the sibling `maplibre-gl-shared.mjs`;
  plain `?url` does not). `npm run build` ends with `scripts/check-dist.mjs`
  asserting both workers are emitted and precached; `scripts/smoke-dist.mjs`
  drives the production bundle under `vite preview` for a manual check.
  Default import (`import maplibregl from "maplibre-gl"`) is gone: use named
  imports. Geolocate errors arrive as `GeolocateErrorEvent` (has `.code`).
- Layer state lives in ONE localStorage key `layerState` (`{base, cutoff,
  overlay, strength}`); the old `overlayMode`/`overlayOpacity` keys are
  migrated once. The Layers sheet, legend and boot pill all read it via
  `setLayerAccess` in ui.ts.
- The season stack is plain layer visibility: season sources are stacked
  chronologically, "up to season X" shows layers ≤ X, newest paints on top,
  transparent edge tiles and absent tiles let older seasons through, and
  the topo layer stays visible underneath so gaps read as "no photo by
  then". The topo underlay ALSO stays on under an aerial/Tasmap base whose
  archive is not local (offline = the map, never a flat ocean colour);
  `applyLayerState(map, state, status.rasterLocal)` must be re-run after
  downloads/deletes (`layers.reapply()`). `seasonAt()` in protocol.ts tells
  the sheet which LOCAL season is on top at the map centre (remote archives
  are never probed: a pmtiles getZxy re-downloads the tile), probing at
  round(zoom + 1) — the level MapLibre renders 256 px tiles at.
  `raster-fade-duration: 0` on seasons — stacked cross-fades flicker.
- Geolocate `error`: only code 1 (denied) ends tracking; a transient
  "position unavailable" keeps MapLibre's watch alive and recovers without
  any event, so the wake lock must not be released on it. One pill per
  tracking session.
- Downloads "Update" keeps the installed archive serving until the
  replacement is assembled (atomic swap) unless free space < 2× the
  archive; outdated/partial rows keep a secondary Delete. "Download all
  seasons" is one batch: first failure or Cancel ends it.
- Wide viewports (≥ 700 px) have NO scrim: the map, toolbar and controls
  stay live beside the card (pan while comparing seasons); close is × or
  Escape. Phones keep the tap-outside scrim.
- `raster://<key>/{z}/{x}/{y}` resolution: downloaded detailed area →
  local OPFS pack (z ≤ 15) → (seasons) R2 pack → LIST live → blank (z ≤ 15)
  or **throw** (z > 15). Sources run to the service's native max zoom
  (aerial/seasons/topo 18, Tasmap 16 — `packOf(key).maxzoom`), so online
  the map streams full-resolution LIST tiles past the packs; offline a
  miss above z15 must ERROR **with `status = 404`**: only a 404 makes
  MapLibre fire the `data` event that re-runs its retain pass, which then
  requests the parent (up to 10 levels, `maxUnderzooming`), i.e. the
  stretched z15 pack tile. A blank there paints a hole over it; a non-404
  error leaves the hole until the camera moves. MapLibre never requests a
  parent for a tile still *loading*, so live fetches above z15 are bounded
  (3 s timeout + a 20 s breaker after a failure) or a phantom connection
  holds holes open. z18 cap = size choice (64× z15 per tile), not a
  fallback constraint. Seasons go live only above z15 and only where
  their z15 archive tile exists (`seasonHasParent`, cached), so seven
  stacked sources don't fire 404 storms. For statewide packs a miss inside
  a LOCAL archive's bounds/zooms is authoritative (pruned ocean → blank).
- MapLibre hard-codes `image/png` as the blob type for every raster tile
  and the browser sniffs the real format, so JPEG archives (and MIXED
  PNG/JPEG season archives) decode fine — proven by the pixel-readback tests
  (`?pixels=1` sets preserveDrawingBuffer; never on in normal use).
- The Layers sheet's scrim covers the toolbar: tests must close the panel
  before clicking another toolbar button (a scrim tap closes the panel).
- Pixel tests must switch the overlay OFF first — a 50 % TASVEG fill tints
  the readback.
- Playwright routes match the MOST RECENTLY registered handler first:
  `routeRasterFixtures` (Orthophoto/Tasmap live tiles from the synthetic
  fixtures) must be registered after `blockTopoNetwork`.
- Every `dev-data/*.pmtiles` URL and the manifest are routed in tests
  (404 by default): a developer's `data/` holds the real multi-GB packs and
  a real manifest, which would otherwise leak into "no archive" test paths.
- Pipeline fetches use one keep-alive HTTPS connection per worker
  (`http.client`): urllib's per-tile TLS handshake capped the pull at ~55
  tiles/s (0.8 MB/s); keep-alive gives ~190 tiles/s with the same 8 workers.

- LIST ArcGIS tile path is `{z}/{y}/{x}` (row before column).
- Author CSS `display:` on an element defeats the `hidden` attribute — the
  app.css `[hidden]{display:none!important}` rule guards this.
- `wrangler r2 bucket cors set` wants `{"rules":[{"allowed":{...}}]}`, NOT
  the S3-style `[{AllowedOrigins:...}]` — the wrong shape fails silently if
  you pipe the output away. Always verify with a curl -H "Origin:".
- iOS Safari can paint inline SVGs at viewBox scale before author CSS
  applies — give toolbar/inline SVGs explicit width/height attributes.
- Playwright's WebKit build has NO OPFS write support (and desktop WebKit
  quirks around it) — all OPFS-write tests run in the Chromium project;
  real-iOS verification happens on the partner's phone.
- OPFS `createWritable({keepExistingData:true})` copies the whole file into
  its swap on every open — never use it for incremental appends to large
  files (hence the chunked part-file download design in storage.ts).
- WebKit scroll anchoring walks scrollTop as content renders above the
  viewport; the PDF viewer computes scroll targets arithmetically and
  re-asserts (see viewer.ts).
- pmtiles `Protocol` self-registers a FetchSource for unknown keys against a
  RELATIVE url — always keep the "tasveg" key registered.
- MapLibre never retries an errored source — after archive changes call
  `setUrl()` to re-kick (protocol.ts refreshArchives does this).
- The ArcGIS `drawingInfo` colours are wrong for 67 hatch-patterned
  communities (they give the hatch-line colour, often black) — always use
  the QML.
- TASVEG 5.0 is NOT in the LIST WFS (only 3.0/4.0); no GeoPackage/GeoJSON
  distribution — shapefile/FGDB/MapInfo only.
- GDA94 shapefile → EPSG:4326/3857 reprojection happens once in the
  pipeline; GPS (WGS84) vs GDA94 differ by ~1.8 m — irrelevant at this
  scale.
- LIST OpenDataWFS: empty text fields are the string "null" (not null, not
  ""); `count` above 1000 is silently truncated to 1000; `srsName=EPSG:4326`
  flips the axis order to [lat, lon] (omit it → [lon, lat]); `resultType=
  hits` with GEOJSON output returns an empty body. Page until a short page
  and sanity-check coordinates against Tasmania's bounds.
- The SW precache holds `search/*.json` as an EXPLICIT glob — the only JSON
  it may hold. Never widen it to `**/*.json`: map data (manifest, unit
  tables are bundled anyway) must never go through the SW.
- `openSearch()` must run synchronously inside the tap's own task: iOS
  raises the keyboard only for a `focus()` in the gesture's task — never
  `await` before it. The panel is `openPanel(html, "search")`: a
  full-height, top-anchored takeover on phones so the keyboard never shifts
  the page; the usual 400 px side card ≥ 700 px.
- Safari clears a `type=search` input on Escape AND fires a late `input`
  event after the Escape handler has already closed the panel — search.ts
  ignores input events once the panel is closed (`closed` flag), or the
  late empty value would wipe the remembered query that reopening restores.
- Escape chain (hardware keyboards): areabar → PDF viewer → panel → details
  sheet → search pin. `clearSearchPin()`/`isSearchPinShown()` live in
  search.ts; the pin is a DOM `Marker` (no sprite, no glyph range needed
  offline) with `#search-pill` (name = re-fly, × = clear).
- Search indexes are prefetched on the first map `idle` (main.ts) ONLY when
  a service worker controls the page (`navigator.serviceWorker?.controller`
  — an uncontrolled first load is precaching them already); otherwise they
  load on the first search. The panel retries if that failed. `loadIndexes()`
  resets its promise on network failure but NOT on a version mismatch — that
  would re-fetch ~6 MB per keystroke for a build that can never succeed.
- arcgis.com item downloads: only `www.arcgis.com/sharing/rest/content/
  items/<id>/data` sends CORS headers on the 302 to signed S3 — the
  `hobartcc.maps.arcgis.com` URL in the service data does NOT. The preflight
  allow-list lacks `Range`, so a sheet is a plain `fetch(url)` with no
  custom headers (never `storage.download()`, which sends Range). A captive
  portal answers 200 with HTML — check the `%PDF` magic before storing.
  pdf.js is only ever handed the OPFS `File`, never the remote URL.
- The six `trees-*` layers MUST stay last in the style, followed only by
  `selected-outline` and `selected-point` (a test asserts
  `layers.slice(-8)`): they sit on top of every overlay and its labels, and
  both highlights sit above THEM (below the tree layers a selected tree
  area's red ring was tinted/overpainted by `trees-area-fill`).
  `selected-point` rings a tapped tree; `selected-outline` covers polygons.
- Tree data sheets: ArcGIS answers a REMOVED item with HTTP 400 + HTML (not
  404). The bulk download files any 4xx / non-PDF sheet under localStorage
  `treeSheetsGone` ({id: isoDate}), skips it and finishes as "✓ downloaded ·
  n sheets no longer published"; five such in a row are read as a captive
  portal instead (marks undone, batch stops). A tap always tries a gone id
  once (republished items) and a success forgets the mark; Delete clears
  the set. `fetchSheet` dedupes per id (tap + batch on the same sheet) and
  throws `SheetError` with a `kind` the callers word differently.
- `GeoJSONSource.getClusterExpansionZoom()` returns a Promise in MapLibre 6
  (the callback form is gone); details.ts caps the resulting zoom at 17 so
  a CBD cluster never jumps to street level.
- Glyphs ship as `0-255.pbf` only. Botanical `name` in trees.json is
  verbatim from the register (curly quotes, "×" hybrids, upstream typos);
  map text uses `label`, asserted Latin-1 by the build and a test. A
  character outside 0–255 makes MapLibre request a glyph range that does
  not exist → the label silently fails offline. Use `label`, not `name`,
  for any `text-field`.
- The tree card's "Open the data sheet" button is looked up asynchronously
  (OPFS answers later): guard on `btn.isConnected` — `renderSheet()`
  replaces innerHTML, so a second tap on another tree detaches the first
  button while its probe is still in flight.
- Multi-file downloads (F2F chapters, tree sheets) share one job registry
  in ui.ts (`runJob`/`activeJob`, module-level like storage.ts's inflight
  map): a reopened panel finds the running job, shows Cancel, and resumes
  per file (files already on disk are skipped, not re-fetched).

## Future ideas (discussed, not planned)

- **Vector topo**: the raster topo (~3.4 GB z15) could in principle be
  rebuilt as vector tiles (~500 MB) from the individual LIST open datasets
  (contours, transport, hydro, …), but that means recreating TASMAP's entire
  cartography in MapLibre style JSON — weeks of design work. Cheaper hybrid
  if z15 raster ever feels soft: statewide 10 m contours as a small vector
  overlay (~100–300 MB) over a z14 raster base (~1 GB), keeping contours
  sharp at all zooms. Or extend raster to z16 (+~5 GB, resumable fetch).
- **Geology overlay — SHIPPED 2026-08-30** (kept for the dataset facts): Use MRT's own ArcGIS server (NOT LISTdata — geology isn't
  there; NOT LIST's Public/GeologicalAndSoils — grey renderer, no colours):
  `https://data.stategrowth.tas.gov.au/ags/rest/services/MRT/Geology_Tasmania/MapServer/16`
  = **1:500,000 GEOLOGY UNITS, statewide, 7,693 polygons, 107 legend units,
  CC BY 3.0 AU**. Official colour is the per-polygon `RGBHex` attribute
  (#RRGGBBAA — no QML parsing needed); render flat fills, ignore the
  `pattern` hatch codes. `description` = plain-English lithology sentence
  (popup headline), `strat_name` = ">"-hierarchy (legend bucketing),
  max_age/min_age = period. Acquire via REST query paging (f=geojson,
  outSR=4326, 2000/page ≈ 4 pages, ~26 MB raw → a few MB of PMTiles) — the
  mrt.tas.gov.au download page is Cloudflare-blocked to scripts. 250K (165
  units) and 25K (1,591 units, ~70% coverage) rejected as too complex for a
  non-geologist. `ga_strat_no` links to GA's ASUD pages for ~1/3 of units;
  richer per-unit prose would be ~107 hand-written blurbs (still open).
  Shipped as the Vegetation/Geology/Off switcher; tiles carry only
  SYMB+color, everything else comes from geology_units.json. NO tippecanoe
  coalescing flags for geology (cross-unit merges = wrong answers; the build
  fails loudly if a merge strategy fires).

- **Pre-1750 vegetation overlay — SHIPPED 2026-08-30** (dataset facts):
  NVIS V7.0 "Estimated Pre-1750" Major Vegetation Subgroups, the only
  statewide pre-European reconstruction (Tasmania has NO state-published
  one — LIST/NRE have nothing; Tas content descends from RFA-era mapping,
  frozen since NVIS 6.0). Source: 112 MB national FileGDB (MVS + MVG 100 m
  rasters + RATs), ArcGIS Online item d82f6eab808542ee9d9a0ea09ea36567,
  CC BY 4.0 (DCCEEW). Official colours come from the NVIS_pre_mvs MapServer
  legend swatches on gis.environment.gov.au (the .lyr symbology in the zip
  is an unparseable binary). Tasmania: 37 MVS classes, 21 MVG groups.
  Parent groups come from a NATIONAL-raster majority vote plus same-name
  override — the Tasmanian MVG cells themselves file tussock grasslands
  under "Heathlands" (upstream inconsistency; a name/group assert guards it).
  Pipeline (`build_pre1750.py`) gotchas, hard-won: (1) an Albers envelope
  of a lat/lon box bulges north — the first crop pulled in VICTORIAN coast
  (Corner Inlet mangroves!); clip with a densified cutline at the real
  border, 39°12'S. (2) With a cutline, warp reads source-mask-invalid sea
  as value 0, not dstnodata. (3) MVS/MVG rasters disagree on ~1% of
  boundary cells (independent rasterisations) — parent group = majority
  vote. (4) Never let tippecanoe fix oversized low-zoom tiles itself (it
  kept 0.4% of features for the statewide view); generalise the RASTER
  per zoom band with mode resampling (100/200/400/800/1600 m -> z10-11/
  z9/z8/z7/z0-6), tippecanoe per band, tile-join. Tiles carry MVS+color
  only; names/groups/areas live in pre1750_units.json (geology pattern).

## Deployed endpoints (2026-08-29)

- App: https://lgruen.github.io/izzy-map/ (Pages, deployed by CI on green tests)
- Device probe: https://lgruen.github.io/izzy-map/probe/
- Data archives: https://pub-0ef9b8ef1e7541f8814d3e4374485b76.r2.dev
  (R2 bucket `izzy-map`, CORS for lgruen.github.io + localhost; upload via
  `pipeline/upload_r2.sh` — LOCAL wrangler OAuth only, >300 MiB files go
  through a deploy-use-delete multipart uploader Worker)
- F2F CORS proxy: https://izzy-f2f.fountouki.workers.dev (Worker `izzy-f2f`,
  allowlisted f2f_*.pdf pass-through; needed because nre.tas.gov.au sends no
  CORS headers)

## Decisions revised during build (vs original plan)

- Region packs → ONE statewide topo pack z0–15 (probe showed 41 GB quota on
  the target phone; TASVEG stays sharp at all zooms as vector). z16 remains
  a documented extension (+~5 GB).
- No Cloudflare secrets in GitHub CI — tests + Pages deploy only; data
  uploads always local (user decision).
- F2F PDFs render in an in-app pdf.js viewer with per-community page deep
  links (Safari ignores #page= on blob: URLs).

## Status log

- 2026-09-12: Offline search + Hobart Significant Trees overlay. Search:
  five LIST datasets (Nomenclature, Transport Segments, Named Feature
  Extents, Locality areas, Address Points; CC BY 3.0 AU) → two committed
  indexes `app/public/search/gazetteer.json` (2.48 MB raw / 0.87 MB gzip,
  43,576 rows) + `addresses.json` (3.42 MB / 1.22 MB gzip, 13,679 streets ×
  261,176 house numbers), SW-precached app shell (`check-dist.mjs` guards
  them), no library — word-prefix scoring, abbreviations, house numbers /
  units / ranges / number words, distance tie-break; 5th toolbar button,
  full-height panel on phones, pin + pill, Escape chain. Trees: City of
  Hobart register (CC BY 4.0 — new LICENSING.md §1c), 460 points + 34 areas,
  277 refs, bundled 233 KB GeoJSON behind an independent "Also show"
  toggle (`LayerState.trees`), per-tree card (botanical/common name,
  address, count, register note, accuracy) + council data sheet fetched
  from www.arcgis.com into OPFS on tap, optional 446 MB bulk row; the new
  multi-file job registry gives the F2F row Cancel/Resume too. Pipeline
  enrichment from the council register PDF (glyph-shift decode for
  2012-era sheets) — 275/277 common names, 277/277 addresses. Adversarial
  review rounds — highlights: Safari clears `type=search` on Escape and
  fires a late `input`; only www.arcgis.com sends CORS on the 302 and its
  preflight lacks Range; captive-portal HTML stored as a "PDF" (%PDF magic
  check); version-mismatch re-fetching 6 MB per keystroke; iOS keyboard
  needs a synchronous focus(); WFS [lat, lon] axis flip; register vs
  service botanical-name conflicts (D7, H2) and A1's mis-tagged points;
  detached tree-card button after a second tap. 37 Playwright tests in
  app.spec.ts (Chromium; wide-layout subset on webkit-ipad).
- 2026-09-10 (evening): detailed-area downloads in the app (frame an area,
  pick layers + z16–18, device fetches from LIST into OPFS part files);
  sources now run to native max zoom with parent fallback above z15.
- 2026-09-10: Aerial photos (statewide compilation + seven seasons behind an
  "up to season" slider), Tasmap paper-scan base map, Layers sheet (base /
  overlay / strength incl. Outlines-only) replacing the cycling button,
  iPad support (side-card layout ≥ 700 px, Escape, hover, GPS-failure
  pill, `webkit-ipad` Playwright project). Licence re-analysis: NC-ND
  verbatim collections are fine, the export flag is not a licence term
  (docs/LICENSING.md rewritten). Pipeline generalised: `packs.json` +
  `build_raster.py` (licence guard, byte-identical blank sentinels,
  top-down pruning, `--measure`, `--fresh`), `run_pulls.sh`. Measured ~70
  tiles/s (55 with urllib, 190–375 with keep-alive); season packs 210 MB
  (2020–21) to 995 MB (2023–24) — edge tiles are big PNGs; aerial
  compilation 1.93 GB (223k tiles), Tasmap 3.24 GB; R2 now holds 13
  archives, 11.1 GB. maplibre-gl 5.24 → 6.4.1 (ESM-only; worker wiring +
  build guard, see gotchas). 2025–26 season is INCOMPLETE —
  refresh path documented above. Manifest gained `built`/`note`; the
  downloads panel offers Update when the server archive differs.
- 2026-08-29: repo created; plan approved; Phase 0 (setup) in progress.
- 2026-08-29 (night): pipeline + app MVP + design pass + tests + CI + R2/
  Worker infra done; tasveg.pmtiles (360 MB) on R2; statewide topo fetch +
  adversarial review round in flight. Xcode + iOS 26.5 simulator installed
  (Leo has no iPhone — simulator is the iOS test bed, partner's phone the
  target).
- 2026-08-30 (midday): Pre-1750 vegetation overlay shipped (NVIS V7.0 MVS,
  19 MB pmtiles, 4th switcher mode). FOUR adversarial review rounds (~40
  findings) — highlights: Victorian coast leaked into the crop (Albers
  envelope bulge), tussock grasslands mis-grouped as Heathlands by
  Tasmania's own MVG cells (fixed via national-raster vote), coarse-band
  coastline dilation (+8% fake land -> land-fraction mask), pmtiles caching
  a REJECTED header promise (online re-kick needs a fresh instance), R2
  manifest clobber/stale-merge, LICENSING.md 4th regime, 0 km² rounding.
  Declined: descriptor-table refactor (hand-curated overlay wiring is a
  deliberate repo decision), per-source error tracking (offline-first
  product; streaming is a bonus path). 23 tests green.
- 2026-08-30 (early): both archives live on R2 (topo_tas 2.04 GB z0-15 incl.
  Bass Strait islands, tasveg 360 MB); TWO adversarial review rounds (~40
  findings) fixed — highlights: SW precache missed the pdf.js worker,
  half-opaque-blue "blank" tile, downloads state machine, chunked resumable
  download redesign, F2F proxy made non-caching, GHC/NBA page anchors, R2
  CORS never actually applied. 15 Playwright tests green. Remaining known
  minors: no drag-to-dismiss on sheets (handle is decorative), F2F size
  hardcoded 37 MB, veg-state apply skipped if style mid-load (self-heals),
  px-fixed chrome text (no Dynamic Type).
