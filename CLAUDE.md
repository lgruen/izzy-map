# IzzyMap — maintainer guide (written by Claude, for future Claude)

Offline Tasmania vegetation map for Leo's partner's iPhone, Leo's iPhone and
the household iPad — since 2026-11-03 a **native SwiftUI app** in `ios/`
(the PWA it replaces was deleted from the repo; see "Retired web app"). All
changes happen through Claude Code sessions with Leo. The native design plan
is `docs/NATIVE_PLAN.md` (decisions, data delivery, map, interface,
milestones, map-proof results); the design brief and language is
`docs/DESIGN.md`. The original PWA plan:
`~/.claude/plans/this-is-a-completely-vectorized-bee.md`.

## Non-negotiables

1. **docs/LICENSING.md first.** From Forest to Fjaeldmark content, the
   City of Hobart tree data sheets and Understorey Network plant photos
   must never be committed or served from our hosting (public repo!).
   **Apple-hosted Background Assets packs ARE our hosting** — never put F2F
   PDFs, UN photos or tree sheets into a pack or the app bundle; the device
   fetches them itself from the publisher. The LIST aerial/Tasmap rasters
   are CC BY-NC-ND: tiles stay BYTE-FOR-BYTE as served (no re-encoding, no
   merging across services — packs hold our PMTiles verbatim),
   non-commercial, attributed — the licence text governs, not the ArcGIS
   export flag. CC BY / CC BY-NC-ND attribution stays in the app.
2. **Fully offline is the product.** Everything must work in airplane mode
   once the packs are on the device: bundled tables + glyphs (no CDN, no
   remote style/sprite/glyph URL), local PMTiles packs, live LIST tiles only
   as a bonus layer above them. A failed live tile must never hide the
   local one underneath.
3. **Targets: iPhone 16e (partner) and iPad Pro 12.9" 4th gen (2020,
   Wi-Fi only — no GPS, iPadOS 27)**, plus Leo's iPhone. iOS 26 deployment
   target, iOS 27 SDK (Xcode 27.2). Layout by **size class**, never by
   device model (Split View / Slide Over give compact widths on the iPad).
   Wi-Fi-only iPads have no GPS: say so once, never spin silently. Surface
   storage sizes in the UI. Android is gone with the PWA (Leo, 2026-11).
4. **Design quality matters.** The main user is a landscape architect who
   reads cartography and printed map keys professionally — the bar is
   "looks amazing", not "follows the HIG" (`docs/DESIGN.md`, milestone 7).
   Map colours are data (official palettes, never restyled); chrome is
   quiet. Botanical names are set correctly (italics, "×", subsp./var.).
5. **Start from what a component is for, then use the supported native
   way** — never port a web workaround (`docs/NATIVE_PLAN.md` §10 lists the
   ones deliberately dropped).
6. **Remote services stay up until the native app is on all three
   devices:** the Pages site (last deploy = commit 04ea5d9), the R2 bucket
   and the `izzy-f2f` Worker. Tear-down only after asking Leo (see
   "Deployed endpoints").

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
- Relief shading (verified 2026-10-03): `Basemaps/HillshadeGrey` = grey
  hillshade, JPEG, z0–18, **CC BY 3.0 AU** (not ND — re-encoding/adapting
  allowed), from the 30 m state grid + LiDAR where flown (LiDAR areas are a
  DSM: Hobart shows buildings). Flat land ≈ 235–246, sea ≈ 251–255
  (constant 1,651–1,658-byte white JPEGs = blank sentinels), slopes away
  from the NW light darker. `Basemaps/Hillshade` is a colour-tinted
  (hypsometric) variant, unused.
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
- Understorey Network Tasmania plant database (verified 2026-10-25;
  `pipeline/build_plants.py`): WordPress at
  `https://database.understorey-network.org.au`. REST `/wp-json/wp/v2/plant`
  (1,884 posts, 100/page, `X-WP-Total`/`X-WP-TotalPages`, CORS on) exposes
  only id/slug/title + taxonomy term ids — `community` (11 habitat
  classes), `growth-form`, `plants-status`, `municipality` (29), months,
  `family-index`; REST `media` (~2,018) gives `media_details.file` + every
  size's file name and filesize. REST `acf` is EMPTY: common name, family,
  form, height, flowers, fruit, habitat/general notes and the flowering
  calendar (`class="month assigned"`) exist only in the HTML pages
  `/plant/<slug>` (~93 KB, ~13 KB gzip). The page's glide carousel is the
  authority for which photos, their order and credits ("Image Credit:
  <name> – with permission"; `<img>` via webp-express
  `…/webp-images/doc-root/wp-content/uploads/YYYY/MM/<file>.jpg.webp`).
  Pages and photo files send NO CORS. Footer: "© 2025 Understorey Network.
  All rights reserved". 997 UN-hosted photos on 724 plants, all credited
  (a few slides hotlink iNaturalist/AusGrass/VicFlora — skipped; carousel
  files with no REST media item are dropped — the ones seen 404 upstream,
  e.g. hibbertia-sericea-var-sericea). Descriptor fields mix in
  propagation sentences ("Propagate from seed…", "Stand pots in a saucer
  of water"), mostly in General Notes. Sizes:
  `<stem>-150x150` thumbnail, `<stem>-768xH` medium_large; images ≤ 768 px
  wide have none → the full copy, which WordPress may have renamed
  `<stem>-rotated` / `-scaled` (EXIF rotation / big-image) while the
  untouched original stays on disk. Server ~0.8 s/page.
- Atlas of Living Australia occurrences (verified 2026-10-25;
  `pipeline/build_records.py`): `https://biocache-ws.ala.org.au/ws/occurrences/search?q=*:*&fq=…&pageSize=0&facets=point-0.001,dataResourceUid,license&flimit=-1`
  — ONE facet request per species; no raw-record download, nothing
  email-gated. `point-0.001` is ROUNDED, not truncated (296/297 sampled =
  round(lat, 3), round(lon, 3)) → cell centres on multiples of 0.001°;
  `flimit=-1` returns every value (asserted: counts sum to `totalRecords`).
  ALA's `species` field is the species-rank parent (subsp./var. roll up,
  like the UN key); UN names missing from the statewide `species` facet go
  through `namematching-ws.ala.org.au/api/search?q=` (APC accepted name).
  `stateProvince:Tasmania` is coordinate-assigned and INCLUDES Macquarie
  Island (~10.5k records) → bbox fq lat −44…−39.2, lon 143.5…149 (also
  drops sign-flipped points; keeps King Island/Furneaux). Filters: ABSENT
  out (106,563 statewide — marine algal transects, a guard for UN species),
  generalised/sensitive out (threatened species snapped to 10 km = fake
  hotspots), coordinateUncertainty > 1 km out but MISSING kept (> ¼ of
  iNaturalist), fossils out; LIVING_SPECIMEN kept (seed-bank accessions
  georeferenced at their wild sites); no year cut-off (~41.8k records carry
  the "1599" unknown-year placeholder). Coarse georeferences (local, not
  an fq): ~8 % of (species, cell) pairs sit on the whole-arc-minute grid
  (≈ 0.36 % by chance — legacy/herbarium localities up to ~1 km off; one
  Hobart minute point dumped 212 species into HHE) → out of C1; 0.1°-grid
  points (~11 km) → out of C1 and C2. Kept: 1,729 UN species, 862k
  records, 127,635 ~100 m cells. Providers: NVA 564k, iNaturalist Australia
  137k, Tasmanian Herbarium (AVH) 100k, …; licences mostly CC BY 3.0 AU /
  4.0, plus CC BY-NC 106k, CC BY-NC-ND 1,452, unspecified 6.2k — hence
  aggregate counts only (LICENSING.md §1d).


## Architecture

- `ios/project.yml` — XcodeGen spec (`IzzyMap.xcodeproj` is generated and
  gitignored). Targets: **IzzyMap** (app, `org.gruenschloss.izzymap`,
  iPhone + iPad, team T4HS4UL2LT), **IzzyMapTests**, **IzzyMapUITests**;
  the Background Assets downloader extension **IzzyMapAssets** + App Group
  come with milestone 5. Swift 6, MainActor-by-default, Approachable
  Concurrency; `@Observable` models; heavy work `nonisolated`/`@concurrent`.
- MapLibre Native **7.0.0 pinned `exactVersion`** (the distribution repo's
  default branch is a globe pre-release) in one `UIViewRepresentable`
  (`Sources/Map/`); the style JSON is built in Swift (`StyleBuilder.swift`)
  from the bundled tables. Sources: `App/` (model, root view, commands),
  `Map/`, `Controls/` (layers sheet, map buttons, grid pill), `Panel/`
  (sheet/side card, feature card), `Data/` (archives, attribution,
  communities, `DataLocator`), `Location/`.
- `ios/IzzyKit/` — local Swift package for everything without UI: data-table
  decoding (communities, geology, pre-1750, trees, plants, records, NBY1
  grid, F2F index), plant-list ranking, MGA55 grid references; later
  search, plant-ID scoring, download rules. `swift test` on the Mac, no
  simulator. Its tests read the REAL bundled data in
  `ios/IzzyMap/Resources/Data` (tripwires: 156 communities, ≥ 1,800 plants,
  15 tallies, …) plus fixtures generated from the web app's own code
  (`Tests/Fixtures/make_*.{mjs,ts}`, provenance — re-run from a worktree of
  04ea5d9).
- **Bundled data** — `ios/IzzyMap/Resources/Data/` (a folder reference, so
  the bundle keeps `Data/…` and `Data/search/…`): `tasveg_communities.json`,
  `geology_units.json`, `pre1750_units.json`, `trees.json`, `plants.json`
  (1.45 MB), `records.json`, `nearby.bin` (NBY1 grid, 2.31 MB),
  `f2f_index.json`, `search/gazetteer.json` + `search/addresses.json`
  (~6 MB). `ios/IzzyMap/Resources/glyphs/` = `Noto Sans {Regular,Bold}/
  0-255.pbf` (`asset://glyphs/{fontstack}/{range}.pbf`). All committed,
  written by the pipeline (facts only — LICENSING.md §1).
- **Packs (milestone 5, NATIVE_PLAN §2)** — Apple-hosted Background Assets:
  `vector` (TASVEG, geology, pre-1750; essential), `topo` + `relief` +
  `plantid` (prefetch), `aerial`, `tasmap`, `season-2020…2026` (on demand).
  Built with `xcrun ba-package`, uploaded LOCALLY with `altool`
  (`pipeline/upload_packs.sh`, to come), never from CI. Until then the app
  reads the developer's `data/*.pmtiles` via `-dataDir` (DEBUG only);
  `Sources/Data/Archive.swift` mirrors the pipeline's file names by hand.
- Licensed extras (F2F chapters ~37 MB, plant photos ~152 MB, tree sheets
  ~446 MB) — one-tap background `URLSession` downloads straight from the
  publisher (no CORS natively → no relay), into Application Support
  (excluded from backup).
- `pipeline/` — data prep (bash/python via uv; tippecanoe/gdal/pmtiles
  from brew). PMTiles to `data/` (gitignored; still uploaded to R2 for the
  live PWA); the small tables straight into `ios/IzzyMap/Resources/Data/`.
  Raster packs are declared in `pipeline/packs.json`, built by
  `build_raster.py`. `build_style.py` is misnamed: it writes
  `tasveg_communities.json` (QML colours), which the native app uses.
- `native/plantid-test/` — standalone Core ML plant-ID memory test
  (TestFlight, its own README); `pipeline/plantid/` — the evaluation
  pipeline (BioCLIP 2.5, iNat sets, cloud runs).
- CI: `.github/workflows/ci.yml` — `swift test` (IzzyKit) and
  `xcodebuild test` on a simulator, runner label `xcode-27`. TestFlight
  workflows (Trio-style, fastlane + match) come later (NATIVE_PLAN §6).

## Workflows

- **Adversarial review is the default ship gate.** Before committing any
  substantive change, run adversarial review rounds (fresh-eyes hunt for
  real failure modes in the diff, not style nits) and address findings
  autonomously until returns diminish. Don't wait to be asked. The web
  app's first two days of rounds caught ~40 real bugs.
- **Build and run on a simulator** (iPhone 16e (27.2) =
  `4B72EE3A-9DEA-4136-A217-1B25A8082A43`; also "iPad Pro 12.9 4th gen
  (27.2)"):
  ```bash
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"   # Apple's rsync first
  cd ios && xcodegen generate
  xcodebuild -scheme IzzyMap -destination 'id=<udid>' -derivedDataPath build/dd build
  xcrun simctl install <udid> build/dd/Build/Products/Debug-iphonesimulator/IzzyMap.app
  xcrun simctl launch <udid> org.gruenschloss.izzymap -dataDir /Users/leo/izzy-map/data
  ```
  `-dataDir` (DEBUG only) points the app at the main checkout's packs; the
  scheme's Run action passes `$(SRCROOT)/../data`. Without it the app runs
  with bundled data only (that is how CI's UI tests run; the data-dependent
  UI test skips itself).
- **Tests:** `cd ios/IzzyKit && swift test` (~2 s);
  `xcodebuild test -scheme IzzyMap -destination 'id=<udid>' -derivedDataPath
  build/dd` (~35 s incremental).
- **Homebrew rsync gotcha:** Xcode runs `rsync` from PATH with flags only
  Apple's openrsync accepts; Homebrew's rsync 3.x first in PATH fails
  copy/export steps ("Copy failed", `rsync error: syntax or usage error`).
  Put `/usr/bin` first for every xcodebuild.
- **Xcode device components must be current** (2026-11-02: "CoreSimulator
  is out of date" made `simctl`/`devicectl` hang) — open Xcode once or
  `sudo xcodebuild -runFirstLaunch`.
- **Refresh TASVEG (e.g. 6.0 release):** update URL/version in
  `pipeline/build_tasveg.sh`, run pipeline (`build_style.py` rewrites
  `ios/IzzyMap/Resources/Data/tasveg_communities.json`), verify
  counts/colours (IzzyKit's `communities()` test pins 156), rebuild the
  vector pack.
- **Add an overlay map (e.g. geology):** pipeline variant → PMTiles +
  colour table in `ios/IzzyMap/Resources/Data/`; decoder in IzzyKit,
  source + layers in `StyleBuilder.swift`, a row in the Layers sheet, the
  pack entry, attribution. Hand-curated by design — one pattern to follow
  (TASVEG is the template). Tiny datasets (trees is the template) skip
  PMTiles and ship as a bundled GeoJSON-ish table; their layers go at the
  END of the style, before the selection highlight. Map text Latin-1 only.
- **Extend topo coverage (e.g. z16):** bump `maxzoom` in `packs.json`,
  re-run `build_raster.py --pack topo` (disk cache makes it incremental).
  Re-validate the ocean-prune threshold first (the topo `size<1000@13`
  rule in build_raster.py).
- **Add a raster pack (base map or season):** add an entry to
  `pipeline/packs.json` → `build_raster.py --measure 1500 --pack <key>` (time
  it first; ~70 tiles/s at 8 concurrent in 2026-09) → `--pack <key>` (the
  licence guard reads the live copyrightText) → upload (R2 via
  `upload_r2.sh data/<file>` while the PWA lives; a Background Assets pack
  from milestone 5) → mirror the file name in `Archive.swift`. Seasons are
  stacked chronologically. `pipeline/run_pulls.sh` chains build+upload.
- **Refreshing a season (2025–26 is INCOMPLETE — still being flown and
  published as of 2026-09-10):** `python3 pipeline/build_raster.py --pack
  aerial2026 --fresh` (wipes that pack's tile cache incl. the cached
  "absent" markers, ~10–40k requests, minutes with keep-alive) →
  `build_raster.py --check-footprints --pack aerial2026` → re-upload.
  Natively, a re-uploaded pack updates on devices in the background (no
  Update button). When LIST adds the CC badge to the 2026 service, delete
  its `licence_override` (the guard would otherwise abort on the changed
  text). Check the season list yearly: a new `AerialPhotoYYYY` service =
  one new packs.json entry + a season in the app.
- **Relief shading pack:** `python3 pipeline/build_raster.py --pack
  hillshade` (z0–15, prune blank@13; 2026-10-03: ~20 min at ~200 tiles/s).
  Natively the pipeline will pre-render translucent-black tiles (alpha =
  0.4 × (1 − g/247), the exact multiply look; CC BY allows it) — format
  measurements in NATIVE_PLAN §3.
- **Do not re-upload topo unless its tiles changed:** `build_raster.py`
  writes extra metadata (`copyright_text`, `built`, …) into the archive, so
  a rebuild of identical tiles has a different byte size — on R2 every
  installed PWA would be offered a 2 GB "Update"; as a pack, every device
  re-downloads it. `run_pulls.sh` deliberately excludes topo.
- **Refresh place names / addresses (yearly; address points are
  republished quarterly):** `uv run --with shapely --with pyshp --with
  pyproj python3 pipeline/build_gazetteer.py [--fresh]` → writes
  `ios/IzzyMap/Resources/Data/search/{gazetteer,addresses}.json` (cache
  `pipeline/cache/gazetteer/`, ~80 s cold / 9 s warm on 2026-09-12; the
  segments pull is cached one file per page → resumable; the two LISTdata
  zips can be dropped into the cache by hand). Count tripwires (31–34k kept
  names, 13–15k streets, 250–275k house numbers) are pinned to the 2026-09
  pull and WILL drift with LIST republishes — eyeball the stage output
  (dropped counts, samples, FEAT_TYPE histogram → new admin types into
  `DROP_TYPES`) and widen; they catch truncated pulls, not growth. Facts
  only (LICENSING.md §1). `version: 1`; the files now ship inside the app
  binary with the code that reads them, so the web app's "additive only"
  rule is gone — a breaking shape change bumps `version` and updates the
  IzzyKit decoder in the same commit (the search port, milestone 4, should
  carry the old build guard as a test: > 30k rows, > 13k streets).
- **Refresh significant trees:** `python3 pipeline/build_trees.py
  [--skip-enrich] [--fresh]` → `ios/IzzyMap/Resources/Data/trees.json`
  (stdlib only; cache `pipeline/cache/trees/`, ~50 s cold / 2 s warm;
  `--fresh` drops cached JSON/text but keeps the PDFs). Needs
  `pipeline/cache/trees/register.pdf` saved from a browser (403 to scripts)
  and `pdftotext` (poppler). The licence guard aborts unless the portal
  item names CC BY 4.0 AND "City of Hobart". Enrichment reads the register
  first (214 of 277 refs; asserts ≥ 200) and downloads data sheets ONLY for
  the remaining refs (63 on 2026-09-12; asserts ≤ 100 — never all 282).
  Read the run report: register/service conflicts (D7 Pinus vs Populus, H2
  Ulmus vs Fraxinus) drop the common name and fall back to the botanical
  one; A1's points carry A5's trees upstream. Result 2026-09-12: 275/277
  common names, 277/277 addresses, 233 KB. The tree-sheets download total
  (~446 MB) follows the `sheets` table. If the council republishes sheets
  under new item ids, devices keep the old files until Remove.
- **Refresh plants & records** (rerun plants when UN adds/edits profiles;
  records yearly — ALA grows — or after UN's species list changed). ORDER
  MATTERS: build_plants first — build_records reads plants.json `groups`
  to emit `members`. Both write into `ios/IzzyMap/Resources/Data/`.
  - `python3 pipeline/build_plants.py [--fresh] [--sample N]` (stdlib +
    `pdftotext`; cache `pipeline/cache/plants/`: REST pages, gzipped HTML
    one file per plant (resumable), `names/` ALA name matches, `f2f-text/`
    keyed on PDF size + mtime + extraction mode; F2F PDFs from
    `pipeline/cache/f2f/`, fetched if missing). Cold: HTML
    ~13.5 min at 3 workers + ~1,900 name lookups ~20 s; warm ~3 s.
    `--fresh` drops only the REST JSON — delete `html/` to re-pull pages,
    `names/` to re-resolve after an APC change. Tripwires (2026-10 pull):
    ≥ 1,800 plants, ≥ 650 with a photo, ≥ 1,000 common names, ≥ 140 F2F
    codes with species; every `SPLITS` member must be a UN key and the
    group key must NOT be (UN re-lumping → drop the entry). Read the
    report: unknown HTML labels (new UN fields → `P_FIELDS`/`H5_FIELDS` or
    the ignore lists — propagation prose stays ignored), skipped non-UN
    photos and dropped no-media photos, descriptor changes (propagation
    sentences dropped / 300-char caps), synonym mappings, ambiguous /
    fuzzy-dropped names, entries dropped as absent/contrast mentions
    (eyeball the context snippets), top unmatched (mostly
    weeds/introduced — not in UN by design). Result 2026-10-25: 3,210
    entries over 146/156 codes, median ~22 species (max 51), 571 distinct
    (incl. 1 group), 75 % of entries with a photo; 16 negated entries
    dropped.
  - `uv run --with geopandas --with pyogrio --with pyproj --with pyarrow
    python3 pipeline/build_records.py [--tasveg PATH] [--fresh] [--sample
    N]` (cache `pipeline/cache/records/`, one file per species tagged with
    the fq signature — editing a filter re-pulls everything; TASVEG zip
    default `data/LIST_TASVEG_50_STATEWIDE.zip`, read in place via
    `/vsizip/` into `tasveg_slim.parquet` keyed on the zip's name + size +
    mtime). In a worktree without `data/`, pass `--tasveg
    /Users/leo/izzy-map/data/LIST_TASVEG_50_STATEWIDE.zip`. Cold ~80 s,
    warm ~4 s, STRtree join ~1 s. Tripwires: 1,600–1,900 species,
    750k–1.1M records, 110–170k cells, ≥ 140 codes, `nearby.bin` ≤ 3.5 MB,
    and Nothofagus cunninghamii in RMT's top 5 (a lat/lon or CRS slip
    scrambles that first). Result 2026-10-25: 156 codes listed, 15 of them
    plain tallies; `members` for 123 codes; 33,819 grid cells, 510k pairs.
  - Both files are `version: 1`; IzzyKit refuses any other version (and a
    wrong NBY1 magic). Bump only for a breaking shape change, with the
    decoder in the same commit. Then `swift test` — PlantDataTests pin the
    tripwires again. Photos never pass through the pipeline; the plant
    photos download total (~152 MB for 997 large versions) is Σ `bytes`.
- **F2F page index:** `uv run --with pypdf python3 pipeline/build_f2f_index.py`
  → `ios/IzzyMap/Resources/Data/f2f_index.json` (reads
  `tasveg_communities.json` from the same folder; page numbers only — the
  PDFs are never committed).
- **Plant-ID evaluation:** `pipeline/plantid/README.md`; the UN species
  list comes from the bundled `ios/IzzyMap/Resources/Data/plants.json`
  (`--un-plants`).

## Native gotchas (map proof + milestone 1, 2026-11-03)

- **A character outside Latin-1 drops the whole label** in MapLibre Native
  too (en dash seen) — glyphs ship as `0-255.pbf` only, so every
  `text-field` uses the Latin-1 `label` fields (trees.json, the community
  table), never the verbatim `name` (curly quotes, upstream typos; "×" is
  U+00D7, inside the range). IzzyKit's `MapText.isLatin1` is the guard.
  Verbatim names are for SwiftUI text.
- **LIST topo water has alpha 207**: the base needs an opaque background
  layer under topo, or water tints with whatever is below (magenta in the
  proof). Per-base backgrounds: aerial `#1e525f`, Tasmap `#aae0fc`.
- **256 px tiles**: MapLibre draws a 256 px source one level up, so a live
  LIST z16 layer above a maxzoom-15 pack already draws from map zoom
  15.5. Overzooming the packs to z18 leaves no holes; offline, failed live
  tiles are transparent and the stretched pack shows. ≤ 4 tries per URL,
  tied to camera moves (no retry storms), but each failure logs two lines
  — filter the log (`MapLogging.swift`).
- **MapLibre's offline packs are rejected for detailed areas**: they work,
  but LIST sends `max-age=0` / `Expires: 1970`, so every stored tile counts
  as stale and is re-requested on each view unless we rewrite response
  headers (a workaround), and their zoom range is map zoom, not tile zoom.
  Detailed areas = our own per-area PMTiles files (NATIVE_PLAN §3).
- **MapLibre Native pinned to 7.0.0 exactly** (`exactVersion` in
  project.yml) — the distribution package's default branch points at a
  globe pre-release; never a branch or `from:`.
- `visibleFeatures(at:)` returns VEGCODE and friends; `asset://` glyphs work
  offline; local PMTiles (vector, PNG, JPEG, MIXED PNG-alpha/JPEG) make no
  network requests.
- Full stack (topo + aerial + 7 seasons + TASVEG) = 60 fps in the
  simulator but texture memory 20 → ~145 MB: measure on the 16e; keep
  hidden seasons out of the style rather than merely invisible if needed.
- Offline-storage completions arrive on the main thread; never block it.
- `.gitignore` anchors `/data/`: unanchored, it also matched
  `ios/IzzyMap/Resources/Data/` (macOS filesystem is case-insensitive,
  `core.ignorecase`).
- UI tests: XCTestCase overrides are nonisolated → IzzyMapUITests builds
  with `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, tests opt in with
  `@MainActor`. A camera can be injected with `-lastCamera <hex>`.

## Product rules carried over from the web app

(The behaviour is the spec; the web mechanics are not — NATIVE_PLAN §4/§10.)

- Stacking: topo stays under the season stack, and under aerial/Tasmap
  while that pack isn't installed (offline = the map, never a flat ocean
  colour). Seasons oldest → newest, "up to season X" = layer visibility,
  fades off for seasons; live seasons above z15 only where the season's
  z15 tile exists. A miss inside a local pack is authoritative (pruned sea).
- Paint order: overlay fills → relief → outlines/labels → trees layers →
  selection highlight (red ring) last, so a selected tree area isn't
  overpainted.
- Location: only a permission denial ends following; a temporary "no fix"
  never does. One honest message per session ("Wi-Fi-only iPads have no
  GPS"). Idle timer disabled only while following in the foreground.
- Cards stay compact so the map stays tappable — comparing communities is
  the core gesture; the Plants section starts collapsed ("n named · n in
  records · n nearby"). Rare communities (tallies, "few records") are
  shown, not hidden (Leo).
- Downloads of licensed extras: a 4xx (ArcGIS answers a REMOVED item with
  HTTP 400 + HTML) = gone, filed and skipped; a non-PDF/non-image 200 =
  captive portal (check `%PDF` / image magic before storing); n gone in a
  row = broken path or portal, stop; resume skips files present; a tap on
  one sheet/photo/chapter fetches just that one.
- Plant photos are stored by path with the size suffix left OUT (`large`
  is a suffix, never parsed: "-768x576", "" (original; 226 photos),
  "-rotated" (9) or "-scaled") — pixel size unknown, so a fixed 4:3 box
  with the photo fitted (thumbs 1:1, filled). Offline + not stored = a
  leaf placeholder, never a broken image.
- Cluster zoom for trees capped at 17 (a CBD cluster never jumps to street
  level).

## Pipeline and data gotchas

- Pipeline fetches use one keep-alive HTTPS connection per worker
  (`http.client`): urllib's per-tile TLS handshake capped the pull at ~55
  tiles/s (0.8 MB/s); keep-alive gives ~190 tiles/s with the same 8 workers.
- LIST ArcGIS tile path is `{z}/{y}/{x}` (row before column).
- `wrangler r2 bucket cors set` wants `{"rules":[{"allowed":{...}}]}`, NOT
  the S3-style `[{AllowedOrigins:...}]` — the wrong shape fails silently if
  you pipe the output away. Always verify with a curl -H "Origin:".
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
- F2F text must be pdftotext READING order, never `-layout`: the pages are
  two-column and `-layout` interleaves columns line by line, so a binomial
  wrapped across a line ("Acacia" / other column / "dealbata") vanished —
  ~160 species over 83 codes (2026-10-25 review). Page breaks survive
  either way, so f2f_index.json page numbers still delimit sections.
- F2F → UN join (build_plants.py): key = first two words of the UN title
  ("sp."/"x"/"×" → none). "E. amygdalina" expands from the last full genus
  with that initial when that resolves (exact, gender variant or ALA
  synonym — pass 2 queues "<last genus> <epithet>" for name matching:
  Ehrharta acuminata = Tetrarrhena acuminata), else from the ONE UN genus
  with that initial holding the epithet; gender-agreement swaps (us/a/um, is/e, er/ra) catch
  "Orites revoluta"/"revolutus"; ALA name matching maps a name only when it
  and exactly one UN key share an accepted species, and a fuzzy match only
  as a same-genus spelling fix (fuzzy-onto-synonym chains two guesses:
  "Eucalyptus glandulosus" ~> E. amygdalina). `SPLITS`: a broad F2F name
  UN only has segregates for (Leptecophylla juniperina "pinkberry" → 6)
  is listed as the group key, unless followed by "subsp. X" naming a UN
  segregate (then that species); the app ranks members by records in the
  community (`records.json` `members[code]` — full counts, since the ≤ 40
  C1 list may omit them), then nearby, then A–Z.
- Names mentioned only as ABSENT or as a contrast are not "in" the
  community: a cue (lacks/lacking, absence of/absent, instead of, rather
  than, rarely if ever, unlike) within ~60 chars before the name — cut at
  the last sentence end or clause break (", is/with/but/which…", "as is")
  — or "which/that rarely if ever / never / does not / is absent" right
  after it; the negation carries along "A, B and C" / "(e.g. …)" lists.
  A name also mentioned positively in the section stays (16 entries
  dropped, 2026-10-25; the report prints each with context).
- UN descriptors (form/flowers/fruit/habitat/notes) are cleaned: sentences
  about propagating, sowing/germinating, potting, watering, fertilising
  and pruning are dropped (propagation is out of scope); general gardening
  hints ("In cultivation needs a sheltered position") deliberately STAY.
  The regex is tuned so ecology survives (road cuttings, wind-pruned,
  self-sowing, "relies on birds to germinate its seed"); then each field is
  capped at 300 chars on a sentence boundary ("…").
- C1 ranking (build_records.py): IndVal (Dufrêne & Legendre 1997) with
  ~100 m cells as sites and the Wilson 95 % LOWER bound in place of the raw
  proportion (3 of 330 sites counts 0.3 %, not 0.9 %); sites ≥ 3, ≤ 40 per
  code. Codes with < 30 recorded sites (15, incl. threatened DMO/DBA/DPE/
  SMP) get a plain tally with score null — titled "Recorded in this
  community" and marked "few records", not hidden: rare communities are
  the interesting ones (Leo). Known quirk, left as is: GPL ranks riparian Acacia
  axillaris / Senecio squarrosus / Bedfordia above Poa labillardierei —
  genuine specificity in uneven survey data. Arc-minute-grid cells are
  excluded from sites_cs AND Sites_c (coarse herbarium georeferences
  dumped whole floras into whichever polygon the minute point hit).
  Counting distinct cells, not records, damps repeat surveys; C2 sums the
  tapped 0.01° cell + 8 neighbours (≈ 1–1.5 km).

## Retired web app (history: commit 04ea5d9)

The PWA (`app/`: Vite + TS + MapLibre GL JS 6, service worker, OPFS
PMTiles, pdf.js viewer, Playwright tests; `probe/` device + plant-ID Safari
test pages; `pipeline/f2f-proxy/` = the `izzy-f2f` CORS relay Worker;
`.github/workflows/pages-deploy.yml`) was deleted on 2026-11-03. Its
hard-won web-only gotchas (SW precache globs, MapLibre GL's worker URL,
`raster://` resolver + 404-to-retain, OPFS part files, Safari keyboard /
Escape / late `input` quirks, pdf.js scroll anchoring, arcgis.com CORS +
no-Range preflight, relay refusals without CORS, Playwright route order)
live in that commit's CLAUDE.md and code: `git show 04ea5d9:CLAUDE.md`,
`git show 04ea5d9:app/src/<file>`, or `git worktree add /tmp/izzy-web
04ea5d9`. Later milestones port behaviour from there (search scoring,
plants UI, areas), never the workarounds.

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


## Deployed endpoints (2026-08-29; still live — the PWA keeps running until the native app is on all devices)

- App: https://lgruen.github.io/izzy-map/ (Pages; last deployed from commit
  04ea5d9 — the deploy workflow is deleted, so nothing redeploys it). To
  retire (ask Leo first): unpublish Pages in the repo settings.
- Device probe: https://lgruen.github.io/izzy-map/probe/ (same deploy)
- Data archives: https://pub-0ef9b8ef1e7541f8814d3e4374485b76.r2.dev
  (R2 bucket `izzy-map`, CORS for lgruen.github.io + localhost; upload via
  `pipeline/upload_r2.sh` — LOCAL wrangler OAuth only, >300 MiB files go
  through a deploy-use-delete multipart uploader Worker, `pipeline/r2-uploader/`).
  Also `plantid-test/v1/` for the retired Safari plant-ID page. Stays
  while the PWA lives; the packs replace it (milestone 5).
- F2F CORS proxy: https://izzy-f2f.fountouki.workers.dev (Worker `izzy-f2f`,
  allowlisted f2f_*.pdf pass-through; needed because nre.tas.gov.au sends no
  CORS headers). Since 2026-10-25 also `/un/YYYY/MM/<file>.<img-ext>` →
  UN `wp-content/uploads/` (separate allow-list, image content-types only,
  no-store both ways, same Origin check). Both routes `redirect: "manual"`
  (3xx → 502). Redeployed and verified live 2026-10-25. Its source was
  deleted from the repo (`git show 04ea5d9:pipeline/f2f-proxy/worker.js`);
  the native app needs no relay. **Tear-down, only after asking Leo and
  once the native app is on all three devices:** `npx wrangler delete
  izzy-f2f` (local wrangler OAuth).

## Decisions revised during build (vs original plan)

- Region packs → ONE statewide topo pack z0–15 (probe showed 41 GB quota on
  the target phone; TASVEG stays sharp at all zooms as vector). z16 remains
  a documented extension (+~5 GB).
- No Cloudflare secrets in GitHub CI — tests + Pages deploy only; data
  uploads always local (user decision).
- F2F PDFs render in an in-app pdf.js viewer with per-community page deep
  links (Safari ignores #page= on blob: URLs) — web only; natively PDFKit.
- Native app replaces the PWA (Leo, 2026-11-03): Apple-hosted Background
  Assets packs instead of R2 downloads, no relay, CI on GitHub Actions
  (simulator tests now; TestFlight later, local pack uploads only).

## Status log

- 2026-11-03: Native start (milestone 1, `docs/NATIVE_PLAN.md`). Map
  proof with MapLibre Native 7.0.0 (local vector/PNG/JPEG/MIXED PMTiles,
  overzoom, live LIST above packs, Latin-1 labels, water alpha 207,
  offline packs rejected); XcodeGen project `ios/` with IzzyKit (data
  tables, plant lists, MGA55 — 19 tests over the real bundled data) and an
  app shell (map, sheet/side card, glass controls, layers sheet, grid
  pill, location notice). Repo restructure: the bundled data moved with
  history (`git mv`) from `app/src/generated/` and `app/public/search/`
  into `ios/IzzyMap/Resources/Data/`; glyphs into `Resources/glyphs/`;
  pipeline outputs repointed; `app/`, `probe/`, `pipeline/f2f-proxy/`,
  `make_raster_fixtures.py` and the Pages workflow deleted (Pages, R2 and
  the Worker stay live); new `ci.yml` (IzzyKit `swift test` + simulator
  `xcodebuild test` on the `xcode-27` runner). Plant ID: BioCLIP 2.5 at
  94.7 % top-1; the Safari test was memory-killed on the 16e → native Core
  ML test app (`native/plantid-test`, TestFlight).
- 2026-10-25: Plants section on TASVEG cards — three lists, each entry
  opening a plant sheet built from the Understorey Network Tasmania
  database (1,884 profiles: photos, common name, family, form, height,
  flowers/fruit, habitat, flowering months): B "Named in the description"
  (F2F binomials ∩ UN keys via abbreviations, gender endings, ALA
  synonyms and one split group, absent/contrast mentions dropped; 3,210
  entries over 146/156 codes, median ~22), C1 "Often recorded" (ALA
  records joined to TASVEG, Wilson-lower-bound IndVal, arc-minute
  georeferences out; tallies for 15 sparse codes), C2 "Recorded near
  here" (0.01° grid, 3 × 3 cells). Committed: plants.json + records.json
  (lazy chunks, prefetched on idle) + nearby.bin (precached asset).
  Licence decision (Leo): species lists and short factual descriptors are
  facts; photos © photographers, device-fetched only — online straight
  from UN, offline via the relay's new `/un/` allow-list into OPFS ("Plant
  photos" row, ~152 MB); propagation prose excluded (also scrubbed from
  the descriptors). Two adversarial review rounds. Hard-won: `-layout`
  pdftotext lost ~160 species to interleaved columns, REST `acf` empty
  (HTML scrape), `-rotated`/`-scaled` full copies, `stateProvince:Tasmania`
  includes Macquarie Island, ABSENT survey records, 10 km-generalised
  threatened species, arc-minute herbarium points, point-0.001 rounds,
  relay refusals carry no CORS (readable 404 vs network error) and must
  not follow redirects, lazy chunks purged by an SW update, double tap
  stacking two views, collapsed section so the map stays tappable. 11 new
  Playwright tests.
- 2026-10-03: Relief shading (LIST `HillshadeGrey`, CC BY 3.0 AU) as a
  statewide z0–15 raster pack + detailed-area layer, shown via an "Also
  show" toggle over any base/overlay; grey tiles become translucent-black
  "multiply" bitmaps at render time (`shadeTile`). Google-style terrain
  look; fixed NW light (movable sun judged a gimmick).
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
