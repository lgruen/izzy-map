# IzzyMap native — design plan (2026-11-03)

Replaces the PWA (`app/`) with a native SwiftUI app for iPhone and iPad, and
adds photo plant identification. Rule for every component (Leo): **start from
what it is for, then pick the supported native way** — never port a web
workaround. The intent catalogue this plan was derived from lists every web
component, its product rules and its web-only workarounds (summarised in
§9).

Decisions already taken (Leo, 2026-11-03):

- Offline data ships as **Apple-hosted Background Assets packs**. Core layers
  arrive automatically with the install; every other pack is **one tap**;
  the licensed device-fetched extras (F2F PDFs, plant photos, tree data
  sheets) are one tap each too.
- CI is **GitHub Actions**, modelled on the Trio "browser build" (fastlane +
  match + App Store Connect API key; the six secrets and the private
  `lgruen/Match-Secrets` repo can be reused).
- The web app is **deleted** from the repo now. Its hosting — the Pages
  site, the R2 bucket and the CORS relay Worker — kept running until the
  native app was on the devices and was **retired on 2026-11-04** (Leo
  approved; CLAUDE.md "Retired hosting"). Our data now lives in `data/`
  locally and in the Apple-hosted packs.
- iOS 26 deployment target, built with the iOS 27 SDK (Xcode 27.2).
- Devices: partner's iPhone 16e, Leo's iPhone, household iPad Pro 12.9" 4th gen
  (2020, Wi-Fi only — no GPS; runs iPadOS 27). Simulators on iOS 27.2:
  "iPhone 16e (27.2)", "iPad Pro 12.9 4th gen (27.2)".

## 1. Platform and project shape

- `ios/` — XcodeGen `project.yml` (generated `.xcodeproj` stays untracked, as
  in `native/plantid-test`). Targets:
  - **IzzyMap** (app, `org.gruenschloss.izzymap`, iPhone + iPad).
  - **IzzyMapAssets** — the Background Assets downloader extension that Apple
    hosting requires (shares an App Group with the app).
  - **IzzyMapTests** / **IzzyMapUITests**.
- `ios/IzzyKit/` — a local Swift package with all logic that needs no UI:
  search index + scoring, MGA55 conversion, data-table decoding
  (communities, geology, pre-1750, trees, plants, records, NBY1 grid),
  plant-list ranking, plant-ID scoring (head + kNN + prior + answer ladder),
  download-job rules (gone / captive-portal detection). Fast `swift test` on
  the Mac without a simulator; the bulk of the old Playwright behaviour tests
  become unit tests here.
- Swift 6 language mode, MainActor-by-default, Approachable Concurrency;
  heavy work (index build, inference, file I/O) in `@concurrent` /
  `nonisolated` functions or actors. `@Observable` models, no
  `ObservableObject`. No SwiftData: the data is read-only tables; user state
  is a few small Codable files.
- MapLibre Native **7.0.0, pinned exactly** (the distribution package's
  default branch points at a globe pre-release), wrapped in one
  `UIViewRepresentable`; the style JSON is generated in Swift from the
  bundled tables.

## 2. Data delivery

| Pack | Contents | Size | Policy |
|---|---|---|---|
| `vector` | TASVEG, geology, pre-1750 | 0.39 GB | essential (installs with the app) |
| `topo` | topo z0–15 | 2.04 GB | prefetch (starts during install) |
| `relief` | relief shading, pre-rendered AVIF (see §3) | 1.29 GB | prefetch |
| `plantid` | Core ML encoder (w8, compiled) + head + int8 kNN bank + prior + credits | 0.73 GB | prefetch |
| `aerial` | statewide photo mosaic | 1.93 GB | on demand (one tap) |
| `tasmap` | paper-map scans | 3.24 GB | on demand |
| `season-2020` … `season-2026` | one per flying season | 0.21–0.99 GB | on demand; plus "all seasons" |

- **Bundled in the app itself** (small, change with code): search indexes,
  community/geology/pre-1750 tables, trees, plants, records, nearby grid,
  F2F page index, glyphs (~15 MB).
- Packs hold our PMTiles **byte-for-byte**, so the CC BY-NC-ND imagery stays
  verbatim, attributed and non-commercial, as they were on R2.
  Updating a pack (e.g. the still-incomplete 2025–26 season) = re-upload;
  devices update in the background, so there is no Update button. Packs are
  built with `xcrun ba-package` and uploaded **locally** with `altool`
  (`pipeline/upload_packs.sh`), never from CI.
- **Licensed extras** (all rights reserved, LICENSING.md §2) are never packs,
  committed or hosted: F2F chapters (~37 MB, nre.tas.gov.au), plant photos
  (~152 MB, Understorey Network), tree data sheets (~446 MB, arcgis.com).
  The device fetches them directly. No CORS natively, so **the relay Worker
  went away** (deleted 2026-11-04). Each is a one-tap row using a background `URLSession`, which
  keeps going when the app is closed. The rules carry over: gone = 4xx;
  captive portal = magic-byte check plus "n gone in a row"; a space
  preflight; resume skips files already present. A tap on a single sheet,
  photo or chapter still fetches just that one.
- Everything lives in Application Support, excluded from iCloud backup.
  The Storage screen shows per-item sizes and free space, and Remove for any
  on-demand pack or extra.
- `plantid` (milestone 6): the w8 encoder compiled to `.mlmodelc` plus the
  scorer's tables and credits in a `plantid/` folder, staged and packed by
  `build_packs.py plantid` (pipeline/plantid/README.md "Shipping artefacts").

### Pack facts (researched 2026-11-03, Xcode 27.2 / iOS 27.2 SDK)

Sources: [A] SDK headers `BackgroundAssets.framework/Headers/BAAssetPackManager.h`
+ its swiftinterface, `StoreKit/SKDownloaderExtension.h`, Xcode's
"Background Download" target template; [B]
<https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs>;
[C] <https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs>;
[D] <https://developer.apple.com/documentation/backgroundassets/testing-asset-packs-locally>;
[E] <https://developer.apple.com/help/app-store-connect/reference/apple-hosted-asset-pack-size-limits>;
[F] <https://developer.apple.com/help/app-store-connect/test-a-beta-version/test-apple-hosted-asset-packs>;
[G] <https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs>;
[H] WWDC26 378 <https://developer.apple.com/videos/play/wwdc2026/378/> (WWDC25 325
is the introduction); [I] forum threads 845418 / 850707 (Xcode 27 scheme
option; simulator problems on 27.1).

- **File access for MapLibre:** `AssetPackManager.shared.url(for: FilePath)`
  (iOS 26, nonisolated) returns a file URL — the only API that gives a path,
  so `pmtiles://file://` uses it. All packs merge into ONE namespace (file
  names must be unique across packs); the URL must not be persisted beyond
  the process; it is "well formed even if no item exists", so the app checks
  readability; "less efficient" than `descriptor(for:)` (an fd the caller
  closes) / `contents(at:)` (mmapped `Data`) — call it off the main thread
  [A]. `PackStore` resolves at launch and after each download, never per
  tile, and off the main thread: the first touch of `AssetPackManager.shared`
  connects to the helper service (0.2–0.27 s on the 27.2 simulator).
- **On-disk form — not yet verified on a device:** an `.aar` is an Apple
  Archive (pbz, block compression); `url`/`descriptor`/mmap imply extracted
  plain files, but whether they sit uncompressed at a stable path is
  undocumented. On the 27.2 simulator `url(for:)` points into a system
  daemon's container: `…/Containers/Data/InternalDaemon/<uuid>/Library/Caches/
  org.gruenschloss.izzymap/Staging/Unlocalized/<file>`. Check on the first
  real install (log `Packs` category, debug level prints each resolved path).
- **Packaging is lossless:** `xcrun ba-package` (2.0) only archives;
  `pipeline/build_packs.py --verify all` extracts every pack with `aa` and
  SHA-256-matches all 14 PMTiles against `data/` (2026-11-03). PNG/aerial
  packs shrink 3–7 % from the archive's own compression; the bytes the app
  reads are the originals.
- **Limits:** 200 GB total per app (per pack the max over its live
  versions, summed) and 200 packs per app [E]. No per-pack or per-file
  limit is published (Tasmap = one 3.24 GB file; confirm on first upload).
  Essential packs count towards the App Store "Up to" size [E].
- **Manifest** (`ba-package template`): `assetPackID`, `downloadPolicy` =
  `essential` | `prefetch` (`installationEventTypes`: `firstInstallation`,
  `subsequentUpdate`) | `onDemand` (`{}`), `fileSelectors` (`file`,
  `directory`, `filePattern`, `fileSource`+`fileDestination`, …),
  `platforms`, optional `sourceRoot` (relative to the manifest), `language`
  (27+); `userInfo` is not allowed for Apple hosting [C]. Essential blocks
  opening the app until downloaded; prefetch starts with the install and may
  finish later; on-demand only via the API [C].
- **Project setup** [B, A]: an ExtensionKit "Background Download"
  extension, type "Apple-Hosted, Managed" = `@main struct …:
  StoreDownloaderExtension {}` (StoreKit; Apple: omit `shouldDownload` unless
  filtering), Info.plist `EXAppExtensionAttributes.EXExtensionPointIdentifier
  = com.apple.background-asset-downloader-extension`; the App Group on app
  and extension; app Info.plist `BAAppGroupID`, `BAHasManagedAssetPacks` =
  YES, `BAUsesAppleHosting` = YES, and no other BA keys.
- **Status and control** [A, B]: `statusUpdates` (all packs) /
  `statusUpdates(forAssetPackWithID:)` → began / paused / downloading
  (`Progress`; `progress.cancel()` cancels) / finished / failed;
  `ensureLocalAvailability(of:requireLatestVersion:)` (26.4; the 26.0 form
  is deprecated) downloads and returns when local; `remove(assetPackWithID:)`
  — the system never removes packs while the app is installed;
  `assetPackIsAvailableLocally(withID:)` (26.4, sync); `manifest` (27; on 26
  `allAssetPacks`) gives `downloadSize`/`version`; updates install in the
  background by themselves. Even an essential pack can be missing after a
  network dropout until the app calls `ensureLocalAvailability` — `PackStore`
  does that for every essential/prefetch pack at launch.
- **Upload** [G]: `xcrun altool --upload-asset-pack <id>.aar --apple-id
  <numeric app id>` (+ `--api-key`/`--api-issuer`, `--wait`), or
  Transporter / the ASC API — separately from builds. Each upload is a new
  version (numbered automatically); devices then update in the background.
  Archiving a pack in ASC is irreversible and its ID can never be reused.
- **TestFlight** [F]: internal testers automatically get the latest
  processed version (no review step described); external testers need each
  version through TestFlight review (one in review at a time). Testers need
  an Apple Account with access to the beta; sandbox accounts are not
  supported.
- **Local testing** [D, H, I]: Xcode 27's Run scheme → Options → "Background
  Asset Packs" folder makes Xcode serve the `.aar`s while it runs the app
  (Xcode's DT asset service serves `/assetpacks/<id>` and sets the device's
  override). Only an Xcode *Run* starts it: an `xcodebuild test` with the
  same scheme element got no override (tried 2026-11-03), and `xcodebuild`
  can't run apps. The older path, `xcrun ba-serve --host … *.aar` plus Settings ▸
  Developer ▸ Development Overrides, needs a TLS identity in the Mac keychain
  and a trusted root CA on the device; forum reports say the override page
  is blank and BA is unreliable on 27.1 simulators — a real iPhone is the
  safer test bed. Without any server, a simulator build asks the App Store,
  gets 404 (no packs uploaded) and the app shows "No offline maps" (handled).

## 3. Map

- **Stacked sources instead of a per-tile resolver.**
  - Each statewide raster pack is a `pmtiles://file://` source with
    `maxzoom 15`, so MapLibre stretches z15 tiles natively when zoomed in.
  - A plain LIST source (`…/tile/{z}/{y}/{x}`, z16–18; Tasmap z16) sits
    above it. Online it draws full resolution; offline its tiles fail and
    the stretched pack shows through.
  - Detailed areas sit above both (see below).
  - Product rules kept:
    - a miss inside a local pack is authoritative (pruned sea: blank, no
      network);
    - the gap colour is fully transparent;
    - per-base background colours (aerial `#1e525f`, Tasmap `#aae0fc`);
    - topo stays under the season stack, and under aerial or Tasmap while
      that pack isn't installed;
    - fades are off for seasons.
- **Seasons:** seven pack sources stacked oldest to newest. "Up to season X"
  is layer visibility. The caption "Showing 2023–24 photos here" probes the
  local packs only, at the zoom MapLibre actually draws. Live seasons above
  z15 only where the season's z15 tile exists, so seven stacked sources
  don't flood LIST with 404s.
- **Relief:** LIST hillshade is CC BY (adaptation allowed). The pipeline
  converts it once into translucent-black tiles with alpha =
  0.4 × (1 − g/247), the exact multiply look. It becomes a plain raster
  layer above the overlay fills and below lines and labels. A real elevation
  hillshade or 3D terrain from LIST's DEM stays a later option.
  Measured 2026-11-03 (1,522 sampled tiles of 198,727):
  - Lossless alpha is 2–2.7× the JPEG source (PNG 4.7 GB, WebP 3.1–3.5 GB),
    because the JPEG noise ends up in the alpha channel.
  - Rejected: converting on the device, because it needs a custom tile
    protocol.

  **Built 2026-11-03: AVIF q85, `data/relief_tas.pmtiles`, 1.29 GB**
  (`pipeline/build_relief.py`, 12 min on 10 cores; not uploaded yet).
  - Gate passed: MapLibre Native 7.0.0 (iOS 27.2 simulator) decodes
    AVIF-with-alpha tiles from a `pmtiles://file://` raster source,
    PMTiles tile_type 5, no warnings. Over topo + TASVEG at 0.5 the
    screenshots differ from a lossless PNG archive by mean 0.4 / max 4
    levels (WebP lossy alpha q50: mean 0.7 / max 6), so WebP is not needed.
  - 198,727 tiles, 1:1 with the source; 181,582 distinct contents. Fully
    transparent tiles (~17k) share ONE stored tile. They must not be left
    out: MapLibre Native draws the stretched parent tile in a missing tile's
    place (tested), which would put blurred shading where there is none.
  - 200 random tiles vs the exact formula: mean alpha error 0.44 levels,
    max 10, colour channels always 0.
  - Layer: plain `raster`, `raster-fade-duration` 0, maxzoom 15 (overzoomed
    above); above the overlay fills, below outlines and labels.

- **Overlays:** TASVEG, pre-1750, geology, or none, at Full (0.5), Light
  (0.25) or Outlines.
  - Pre-1750 has no outlines; Outlines falls back to Light there.
  - Official colours come from the bundled tables (QML for TASVEG).
  - Paint order as today; trees and the red selection highlight last.
- **Detailed areas: our own per-area PMTiles files**, each added as one more
  `pmtiles://file` source above the statewide pack and below nothing else.
  - The device fetches LIST tiles (verbatim bytes), writes them into a
    PMTiles v3 file per area and layer (a small writer in IzzyKit), and
    MapLibre reads it like any pack.
  - The download is a user-started task that keeps running in the
    background through iOS 26's `BGContinuedProcessingTask` (system progress
    UI) and resumes after interruption.
  - Kept from the web app: per-layer caps and estimates, seasons only where
    flown, an area beats the packs, and Delete falls back to the stretched
    z15.
  - Rejected: MapLibre's offline packs. They work (map proof Q4), but LIST
    sends `max-age=0` / `Expires: 1970`, so every stored tile counts as stale
    and is re-requested on each view unless we rewrite response headers. That
    is a workaround, and their zoom range is map zoom, not tile zoom.
- **Location:** MapLibre's user location with follow and follow-with-heading.
  - The idle timer is disabled only while following and in the foreground.
  - Only a permission denial ends following; a temporary "no fix" never
    does.
  - One honest message per session ("No location fix — the map still works.
    Wi-Fi-only iPads have no GPS.") and a Settings deep link when denied.
- **Camera:** opens at the GPS position. Without a fix it restores the last
  camera (new: the web app always opened statewide). Bounded to Tasmania.
- **Grid readout:** an MGA55 easting/northing pill for the map centre; tap
  switches to lat/lon. A short Swift UTM formula, no proj library.
- **Connectivity:** no reachability gating; live sources simply retry when
  the camera moves.

## 4. Interface (iOS 27, Liquid Glass; layout by size class, never device)

- **Shell, Apple Maps pattern.** A full-bleed map, with floating glass
  controls at the top trailing edge: Layers, Location (off / follow /
  heading) and MapLibre's compass. A scale bar and the grid pill sit at the
  bottom leading edge.
  - **Compact width (iPhone):** one persistent bottom sheet with detents
    (search bar only / medium / large). The map stays interactive behind it
    up to medium. The sheet is the single place for search, results, the
    tapped-feature card and plant drill-down, in a `NavigationStack`.
  - **Regular width (iPad, wide windows):** the same content in a floating
    glass card on the leading side. The map, controls and card all stay
    live together, for comparing communities side by side.
- **Tap a feature.** The sheet or card shows it, and its outline turns red.
  Hit priority: trees first, then the visible overlay.
  - TASVEG card:
    - swatch and code, plus group, structure, notable tree and weeds;
    - **Read the description** opens the F2F chapter at that community's
      page;
    - the **Plants** section, collapsed to one summary row so the card
      stays compact. It expands into three lists: Named in the description,
      Often recorded in this community, and Recorded near here.
  - Geology card: plain-English description and age.
  - Pre-1750 card: extent and the modelling note.
  - Tree card: common and botanical name, address, count, note, accuracy,
    and the data sheet.
  - Plant rows push a plant sheet: photos with credits, names, facts and a
    flowering strip. A group entry such as "pinkberry · 6 species" pushes a
    member list first.
  - Changing the overlay dismisses an overlay card but not a tree card;
    toggling trees dismisses only a tree card.
- **Search.** The search field in the sheet; results show a type icon,
  locality and distance. Scoring is today's, ported as is and pinned by unit
  tests:
  - word prefixes, abbreviations, house numbers, units and ranges, number
    words, street words;
  - property names ranked below official ones;
  - ties broken by distance.

  A result flies the camera and drops a pin. The sheet header shows the
  selected place with ×, and the last query is restored when reopened.
- **Layers.** A glass sheet on iPhone, a popover on iPad.
  - Base: Topo, Aerial, Paper map, or Photos by season with a season slider
    and the coverage caption.
  - Overlay with a strength picker.
  - Also show: Relief, Hobart trees.
  - Every row says whether it is on the device ("on this iPhone",
    "downloading 62 %", "Download · 3.2 GB").
  - The legend opens from here. It is a list per overlay with a native
    section index, replacing the chip bar; the curated short group names are
    kept.
- **Identify a plant.** A leaf-camera button in the sheet header.
  1. Take a photo (full-screen system camera) or pick one (PhotosPicker).
  2. A framing step: drag or zoom a square onto the plant you mean. In the
     evaluation, many mistakes were photos with several plants in them.
  3. Results: the answer ladder.
     - Name the species when p ≥ 0.5.
     - Else name the genus when its summed p ≥ 0.5.
     - Else say "Not sure", and still show the top 5.

     Each row has the UN thumbnail and common name, and opens the plant
     sheet. Location comes from the photo's GPS metadata, else the current
     fix, else none (no prior). The results say "recorded within 5 km" when
     the prior contributed.
- **Storage** (from Layers and About): packs, extras and detailed areas,
  with sizes, free space, one-tap get or remove, and "Download an area…".
  Framing an area is a dashed frame with a glass bar ("Frame the area, then
  Next"). Next opens a setup sheet: layers, detail (z16/17/18), a live size
  estimate and a cap.
- **PDF reader.** PDFKit in a full-screen cover, opened at the page, with
  native zoom and page count. The F2F chapter or tree sheet is read from the
  device, else fetched once and kept.
- **About and attribution.** On-screen attribution lists only the visible
  sources, behind the app's own (i) control (MapLibre's button is hidden: a
  PMTiles source takes its credit from the archive's metadata, so the app
  owns the credit table, `Attribution.swift`). About has the full credits by
  licence regime, the "indicative boundaries" note and the battery note.
- **Keyboard and pointer (iPad).**
  - Escape walks back one level at a time: framing → PDF → sheet stack →
    card → search pin.
  - ⌘F search, ⌘L locate, ⌘1–4 bases.
  - Hover effects on controls.
- **Accessibility: scope (Leo, 2026-11-04).** Private app: no VoiceOver/extended accessibility work; legibility at default sizes + iPad keyboard usability matter (Leo, 2026-11-04).
  Text uses system styles (no fixed px); system glass handles Reduce
  Transparency / Increase Contrast; no VoiceOver, AX-size or Reduce-Motion
  rounds.
- **Visual identity, spent in one place:** the map's official colours carry
  it. The chrome is the system's (SF, glass, sheets). Botanical names follow
  the taxonomist's convention: italic, set in New York, with rank words
  (subsp., var., ×) upright. The app icon is a TASVEG-coloured leaf.

## 5. Plant ID pipeline additions

- Export from the 2026-11-02 evaluation into the `plantid` pack:
  - the encoder (fp16 Core ML; compressed variants ready as fallbacks);
  - the trained head (~5.5 MB);
  - the kNN bank (82,649 × 1024 fp16, ~169 MB; measure int8 and
    per-species prototypes against the 94.7 % before shrinking);
  - text prototypes (5.5 MB);
  - labels (2,675);
  - a **new shipping location prior**: a gridded per-species density over
    all labels from the pool records, not `nearby.bin`;
  - a credits file for the training photos (observer + licence; BY-NC binds
    us to non-commercial, which we are).
- Preprocessing matches open_clip (bicubic shortest side, centre crop,
  CLIP mean/std). The photo's colour profile is ignored: no P3 → sRGB
  conversion.
- The 16e TestFlight memory test decides fp16 vs a compressed encoder. The
  UI and scoring don't depend on which.

## 6. CI (GitHub Actions, Trio-style)

- `ci.yml` on every push and PR: `swift test` (IzzyKit), then `xcodebuild
  test` on an iOS simulator (macOS runner, Xcode 27 label).
- Trio-style workflows, triggered only by `workflow_dispatch` or schedule
  on main:
  - Validate Secrets;
  - Add Identifiers (app, extension, App Group, increased-memory-limit);
  - Create Certificates (match, shared with Trio's cert; re-runnable after a
    Trio nuke);
  - Build & Upload (XcodeGen → gym → TestFlight; build number = latest + 1).

  Build & Upload also runs on push to main touching `ios/**`, and monthly
  as a keep-alive against the 90-day expiry.
- Leo copies the six secrets from the Trio fork; the agent never handles
  secret values.

## 7. Repo changes

- Delete `app/`, `probe/`, `pipeline/f2f-proxy/` (code), the Pages and
  Playwright workflows, and the R2 upload/CORS scripts (done 2026-11-04
  with the hosting; `run_pulls.sh` now chains build → `build_packs.py`).
- Keep `pipeline/` (the build scripts and generated tables are the data
  source for both).
- Rewrite CLAUDE.md for the native app: non-negotiables (licensing incl.
  "Apple-hosted = our hosting"; fully offline; size classes), workflows
  (pack build and upload, CI, simulator checks), and the gotchas that
  survive.
- `native/plantid-test` stays as the memory test until the 16e verdict;
  `export_coreml.py` is committed with it.

## 8. Milestones (each ends with adversarial review rounds)

1. **Foundations.** Map proof findings; repo restructure; XcodeGen project
   with IzzyKit; app shell with the map, sheet/card and glass controls; CI
   test workflow.
2. **Map and layers.** (Opaque background under topo; Latin-1 labels.) Style builder, bases, overlays and strength, season
   stack, relief (pipeline re-render), trees layer, legend, location, grid
   pill, attribution.
3. **Cards and content.** Tap cards, plants (lists, plant sheet, photos),
   F2F and tree-sheet PDF reader with device fetch.
4. **Search.** IzzyKit port with the old tests as unit tests; sheet UI, pin.
5. **Offline data.** Pack build and upload scripts, BA extension, Storage
   screen, extras as background downloads, detailed areas.
6. **Plant ID.** Artefact export, prior, capture → frame → results UI.
7. **Design polish (dedicated phase).** The main user is a landscape
   architect with a keen eye for design, so the bar is "looks amazing", not
   "follows the HIG". Round-2 decisions (relief on by default, lists stay
   lists, habitat colour boxes, map stays light, elevations approved,
   places to wander later) and the designed states: DESIGN.md §3 "States"
   and §8 (2026-11-04).
   - **Design brief and language** (drafted at the end of milestone 1 and
     applied throughout, so polish is never bolted on): a type scale
     (SF for chrome, italic New York for botanical names), spacing and
     corner rules, how glass and the map's own colours carry the identity,
     motion principles, and the icon.
   - **Cartography:** line weights and label sizes per zoom, halos,
     outline colours against each base, the selection highlight, legend
     swatches drawn like a printed map key, and the scale bar and grid pill
     typography.
   - **The field-guide feel of cards and plant sheets:** photo treatment,
     the flowering strip, the hierarchy of names, and spacing that reads
     like a well-set book.
   - **Motion and feedback:** zoom transitions from list rows into plant
     sheets, sheet detent behaviour, haptics on meaningful moments
     (identification result, area download done), and respect for Reduce
     Motion.
   - **Every state designed:** loading, empty, offline, "still downloading
     the maps", errors, first launch.
   - **A screenshot matrix reviewed by fresh-eyes design critics:**
     iPhone 16e and iPad Pro 12.9" portrait and landscape, light and dark,
     default text size (accessibility sizes out of scope, 2026-11-04).
   - **A real app icon** (layered, iOS 27 style) instead of the
     placeholder.
   - **Her own review:** a TestFlight build goes to her for feedback, and
     her notes become a final polish round.
8. **iPad and keyboard pass (no extended accessibility work — private
   app, Leo 2026-11-04); CI to TestFlight.** Install on
   Leo's and the partner's phones and the iPad; then retire Pages, R2 and
   the Worker (done 2026-11-04).

Milestones 3, 4 and the pipeline halves of 5 and 6 can run in parallel once
milestone 2's shell exists. CI to TestFlight (milestone 8) can be pulled
forward whenever a build is worth putting on a phone; the secrets are in
place (2026-11-03).

## 9. Map proof results (2026-11-03, MapLibre Native 7.0.0, simulator)

- Local PMTiles render: vector TASVEG, PNG topo, JPEG aerial, and the MIXED
  PNG-alpha/JPEG season packs. Local reads make no network requests.
- Overzoom of maxzoom-15 packs to z18: no holes. Live LIST over the pack:
  full resolution online; offline the failed tiles are transparent and the
  stretched pack shows. There are no retry storms (≤ 4 tries per URL, tied
  to camera moves), but each failure logs two lines, so filter the log.
- 256 px tiles mean the live z16 layer already draws from map zoom 15.5.
- LIST topo water has alpha 207, so the base needs an opaque background
  (or water tints magenta, as in the proof).
- `visibleFeatures(at:)` returns VEGCODE and friends. `asset://` glyphs work
  offline. **A character outside Latin-1 drops the whole label** (en dash
  seen), so the Latin-1 guard on map text stays.
- Full stack (topo + aerial + 7 seasons + TASVEG): 60 fps in the
  simulator, but texture memory went from 20 to about 145 MB. Measure it on
  the 16e, and keep hidden seasons out of the style rather than merely
  invisible if needed.
- Offline-storage completions arrive on the main thread; never block it.

## 10. Web workarounds deliberately not carried over

- The `raster://` resolver.
- Throwing a 404 to trigger MapLibre GL's parent retain.
- Circuit breakers.
- The pmtiles promise cache.
- OPFS part files and the atomic-swap downloads.
- Range/ETag bookkeeping.
- SW precache globs and additive-version constraints.
- The CORS relay.
- pdf.js and its scroll-anchoring fixes.
- The DOM view stash and double-tap swallower (→ NavigationStack plus a
  same-entry guard).
- `focus()`-in-gesture keyboard hacks.
- visualViewport maths.
- The Safari late-`input` guard.
- localStorage gone-sets (→ a Codable file).
- Wake Lock API juggling (→ `isIdleTimerDisabled`).
- proj4 (→ a UTM formula).
- Per-tile canvas hillshade (→ pre-rendered pack).
- The manifest-bytes Update button (→ pack versioning).

## 11. Future ideas (not planned)

- **Places to wander** — "later", decided by the user (2026-11-04). A short,
  static, data-derived list in the empty search state (never a feed: no
  "new" dot, no daily change), each item with a locator glyph (the
  Tasmania silhouette with a dot) that flies there and, for a community,
  starts "Show on map". The round-2 mocks had three concepts:
  - **Smallest communities** — the rarest TASVEG codes by statewide area,
    each opening on its largest patch. *Data: already bundled* —
    `where_patches.json` (`ha`, patch count, the 20 largest patches with
    label points and boxes); rank by `ha`, skip codes that are not
    vegetation (water, sand, urban).
  - **Species-rich spots** — the ~1 km cells with the most species on
    record, each opening "Recorded near here". *Data: bundled* —
    `nearby.bin` (species per 0.01° cell). Needs care: it measures survey
    effort as much as richness (Mount Wellington and the Hobart Rivulet
    would win), so rank by species per site and require a minimum number
    of sites, and title it "Most recorded" unless a fairer measure holds.
  - **Today vs pre-1750** — where the modelled pre-European vegetation now
    lies under cleared or built land (TASVEG "Modified land" over a native
    NVIS class), as "cleared since 1750" hotspots. *Data: new pipeline
    work* — a crosswalk of the 37 Tasmanian NVIS MVS classes to TASVEG
    groups, an overlay of the pre-1750 raster with TASVEG's modified-land
    codes (FAG, FUR, FPL, …) summed per ~5 km cell, and a small bundled
    list of the top cells with hectares; both sources are CC BY (credit in
    About). The card should say "modelled" on the pre-1750 side.

