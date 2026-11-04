# IzzyMap native: visual-first UX review (2026-11-03)

This review applies two lenses Leo set to `NATIVE_PLAN.md` §4/§8, `DESIGN.md`
and the M1/M2 screenshots:

1. **Visual first.** The main user is a landscape architect, so text serves as
   explanation and as the fallback.
2. **Browsing for pleasure.** She also likes to look at maps for a long time
   just for fun.

It is read-only on code and DESIGN.md, and every proposal is checked against
CLAUDE.md non-negotiable 1 (licensing).

## 1. The principle (paste into DESIGN.md §1)

> **6. Show, then say.** Whenever she must decide or recognise something —
> which layer, which plant, which season, how big, where else — the answer
> is drawn first (a swatch, a photo, a pictogram, a mini-map, a bar) from the
> data itself, and the words become its caption, its explanation and its
> VoiceOver label. Text leads only where text *is* the content (legal
> credits, prose descriptions, coordinates).
>
> **7. A map worth wandering.** IzzyMap is also somewhere to browse for
> pleasure: beautiful at every zoom, chrome that recedes, and the data
> itself offering the next place to look — never a feed, badge or nag.

## 2. Shared visual assets (build once, used everywhere)

Several proposals rest on four assets. Making them once keeps the visual
language consistent, so the app doesn't end up as a different chart on every
screen.

| Asset | What | Data / work | Licence |
|---|---|---|---|
| **A. Growth-form pictograms** | 10 custom SF Symbols drawn as planting-plan plan/section glyphs: Tree, Shrub, Herb, Grass, Sedge, Rush, Fern, Orchid, Groundcover, Climber (the complete `forms` vocabulary in plants.json). Plus 7 **structure** glyphs (tall forest, forest, woodland, scrub, heath, grass/sedge, wetland) for FOREST_STR and the pre-1750 MVGs. | Drawing work. Map the FOREST_STR value set (it isn't in a bundled table yet; check the distinct values in the pipeline). | Own work |
| **B. Tasmania silhouette** | A simplified coastline path, incl. King and Flinders Islands, about 20 KB. It gives every mini-map its context. | Pipeline: dissolve the TASVEG extent, or LIST coastline, Douglas–Peucker. Bundled. | CC BY 3.0 AU, credited in About |
| **C. Community presence grid** | Per VEGCODE: a bitset of ~5 km cells where the code occurs, plus total ha and its 20 largest patches (centroid + bbox). | Pipeline `build_tasveg.py` addition, about 150–250 KB bundled. Facts. | CC BY 3.0 AU |
| **D. Species distribution** | Per UN species, the cells where it is recorded, read at runtime by inverting `nearby.bin` (510k pairs; a one-off index of about 50 ms). | No new data. | Aggregate ALA counts (LICENSING §1d); ≈1 km cells are what ALA itself shows publicly |

The rule for photo fallback follows from A. Only 724 of 1,884 plants have a UN
photo, though 75 % of community-list entries do. **The placeholder is the
plant's growth-form pictogram, not a generic leaf**, so even an offline row
says "sedge" or "tree" at a glance.

## 3. Per screen

Format: **burden** (where she has to read now) → **proposal** → data ·
licence · priority (P1 must / P2 should / P3 nice) · milestone.

### 3.1 Map and chrome

- **Burden:** the map itself is visual. The burden is *ugliness*: at z6–9
  the TASVEG fill breaks into rectangular tile blocks (both M1 shots, the
  iPad statewide shot), and the selection outline is red.
- **Proposal:**
  - Fix the tile-dropping first: it is a pipeline/tiling fault, and both
    lenses fail on it.
  - Take DESIGN §4's cased ink selection, zoom-ramped boundaries and z14
    codes as given.
  - **Statewide view as a painting:** a per-zoom generalisation check of the
    vector pack (screenshot z5, z7, z9, z11 at each strength) as an M2 exit
    criterion.
- TASVEG pack · fine · **P1** · M2.

### 3.2 Feature card: TASVEG

- **Burden:** the peek is fine (key box, code, name). Below it, Group,
  Structure, Notable tree and Weeds are four rows of words to parse. "Plants
  · 22 named · 40 in records · 31 nearby" is a sentence of counts.
- **Proposal, peek (unchanged height):**

  ```
  ┌──┐ dob                                ✕
  │▓▓│ Eucalyptus obliqua dry forest
  └──┘ [forest glyph]  (●)(●)(●)(●)(●) +17   ← plant faces
  ```

  - **Plant faces:** the five most characteristic plants (C1 order, else B)
    as overlapping 28 pt square thumbnails. Pictogram fallback. Tap = expand
    Plants.
  - The words "22 named · 40 recorded · 31 nearby" move to the
    accessibility label and to the expanded header.
- **Proposal, medium/large:**
  - A structure glyph replaces the "Structure" row text, with the value as a
    caption.
  - **"Where else" mini-map:** the silhouette (B) with the code's presence
    cells (C) in its composited key colour and a ring at the tapped spot.
    About 120 × 110 pt, with "about 12 400 ha statewide" as a caption.
    Tapping it starts **Explore this community** (§4).
  - **Then and now:** two key boxes side by side, "Today DOB" and "Before
    1750: MVS 5 Eucalyptus open forest". The pre-1750 value comes from
    querying the pre-1750 layer at the tap point; that layer is in the
    vector pack and can be queried while hidden at opacity 0.
- Data: presence grid (C, pipeline), records, plants, pre-1750 pack ·
  licence fine (photos fetched on the device) · faces **P1**, where-else
  **P1**, then/now **P2**, structure glyph **P2** · M3 (grid pipeline in M3).

### 3.3 Geology card

- **Burden:** "About 180 million years old" and a stratigraphy string.
  Deep time is meaningless as a number.
- **Proposal:** a **geological time bar**, 0–600 Ma (Tasmania's oldest units
  are about 1,600 Ma, so use a log, or a broken axis with the Proterozoic
  compressed). It is banded by ICS periods in their ICS colours, which are
  standard, as on every stratigraphic chart. The unit's `maxMa–minMa` span is
  drawn as an ink bracket, and "Jurassic" is labelled under it. The age
  sentence stays as the caption.
- Data: geology_units maxMa/minMa plus a hand-written table of about 12
  periods · fine · **P2** · M3.

### 3.4 Pre-1750 card

- **Burden:** an extent in words and a modelling paragraph.
- **Proposal:**
  - The MVG structure glyph (A).
  - The extent as a bar against the largest class (`ha`).
  - **Then and now in reverse:** the TASVEG key box at the same point.
  - The modelling note stays as text: it is a caveat, and caveats are
    words.
- Data: pre1750_units · fine · **P2** · M3.

### 3.5 Tree card

- **Burden:** the accuracy is "±5 m" as text, and "Trees 3" as a row.
- **Proposal:**
  - Draw the **accuracy as a circle on the map** around the selected tree,
    an honest visual of "somewhere in here".
  - Show the count as n small `treeGreen` dots (up to 10, then a number).
  - Once the data sheet is on the device, show its **first-page thumbnail**
    (PDFKit, rendered on the device) as the "Open the data sheet" button.
- Data: trees.json · sheet thumbnail only from a device-fetched file, never
  cached outside Application Support · accuracy circle **P2**, sheet thumb
  **P3** · M3.

### 3.6 Plants section, lists and group list

- **Burden:** these are text lists: italic name, "common · forms", a site
  count. A planting palette is judged by eye.
- **Proposal:**
  - Rows go photo-first: a 56 pt square thumbnail (pictogram fallback), then
    the name and common name.
  - The trailing count becomes a short ink **evidence bar** (sites ÷ the
    list's maximum). The number stays in the accessibility label.
  - A **mini bloom strip** (12 × 3 pt cells, current month ticked) only when
    `flowering` exists (56 % of plants). It is quiet enough not to clutter,
    and it lets her scan "what's flowering now" down a list.
  - ~~Add a **Palette** view toggle (List | Palette) on each list~~ —
    **decided by the user (2026-11-04): the plant lists stay lists**, no
    photo grid.
  - The group list ("pinkberry · 6") as a row of its members' faces.
- Data: plants.json, records.json · photos fetched on the device (thumbs
  are about 10 KB) · rows **P1**, palette **P2**, bloom mini-strip **P2** ·
  M3.

### 3.7 Plant sheet

- **Burden:** Form, Height "2 – 3" and Flowers are rows of words. The
  flowering strip is already designed.
- **Proposal, top to bottom:**

  ```
  [photo plate 4:3, paged, credit below]
  Richea scoparia / scoparia / Ericaceae   [status mark if R/E/V]
  ┌ bloom chart S O N│D J F│M A M│J J A ┐  (DESIGN, primary graphic)
  ┌ section ─────────────┐ ┌ where recorded ─┐
  │ ▲▲  🚶     2–3 m     │ │  [Tas silhouette │
  │ shrub glyph beside a │ │   with dots]     │
  │ 1.7 m scale figure   │ │  412 sites       │
  └──────────────────────┘ └──────────────────┘
  Flowers / Fruit / Habitat / Notes (prose, as text)
  ```

  - **Height as a section drawing:** the growth-form glyph scaled to the
    height range (a min–max ghost), next to a 1.7 m human scale figure, as
    on a landscape section. The axis is log above 5 m, with tick labels.
    When height is missing (48 %), show the glyph without scale.
  - **Distribution map (D):** the field-guide convention, from cells, with
    the tapped spot ringed.
  - The **status** (Rare/Endangered/Vulnerable, 434 plants) as a small
    upright mark next to the name, never a coloured badge.
  - **Habitats** as small key-box chips only if UN classes can be mapped to
    VEG_GROUP colours without lying. Otherwise keep them as text (decision
    below).
- Data: plants.json, nearby.bin · photos fetched on the device · section and
  distribution **P1**, status mark **P2** · M3.

### 3.8 F2F reader entry

- **Burden:** "Read the description" is a bare button.
- **Proposal:** when the chapter is on the device, the button shows a
  thumbnail of **that community's page** (PDFKit renders page n on the
  device), so she sees she's opening the book at its page.
- Data: f2f_index + device-fetched PDF · never bundled · **P3** · M3.

### 3.9 Search

- **Burden:** results are text plus type glyphs (already designed), and
  telling "Elizabeth Street, Launceston" from "Elizabeth Street, Hobart"
  relies on reading.
- **Proposal:**
  - A 24 pt **locator glyph** per row: the silhouette (B) with a dot. One
    vector path, no snapshot.
  - **Results on the map:** while the sheet is at medium, every hit is a
    small numbered ink dot on the map behind it, and tapping one selects
    the row (Apple Maps pattern).
  - Results with a bounding box (roads, peaks, bays) draw their **extent
    frame** when picked.
- Data: gazetteer · fine · locator **P2**, dots on map **P2**, extent frame
  **P2** · M4.

### 3.10 Layers, legend, season slider and caption

- **Burden:** the M1 sheet is text rows ("Topographic / theLIST basemap /
  Not on this device"). Strength (Full/Light/Outlines) is three words for
  three looks. The season caption is a sentence.
- **Proposal:**
  - **Thumbnails (being built):** keep them. Make them the *only* row
    headline graphic, with the status drawn on the tile: a download arrow
    plus the size, a progress ring on it while downloading, a desaturated
    tile with "Not on this iPhone" when it isn't there.
  - **Strength:** a segmented control of three drawn key boxes (full
    composite, pale composite, edge-band box) using the colour of the
    community at the map centre. No snapshot needed.
  - **Season slider with coverage:** above each tick, a 36 pt silhouette
    with that season's footprint (z8 tile existence from the pack's PMTiles
    directory; for packs not on the device, a bundled footprint bitset from
    the build). The tick whose photo is drawn at the map centre gets an ink
    ring; that is the caption, made visual. Seasons not on the device get
    hollow ticks.
  - **Legend, "In view" first:** the top section lists only the codes
    visible on screen, from a sampled feature query on idle, sorted by
    on-screen share with a share bar. The full printed key follows. 156
    rows become the 6–10 that matter here.
  - **Geology legend as a stratigraphic column**, ordered by age (§3.3 time
    bar down the side).
  - **Pre-1750 legend** with structure glyphs, tallest to sparsest.
- Data: snapshots (on device), PMTiles directory, bundled footprints (a
  build output; confirm the licence wording if LIST's mosaic-index layer is
  used instead) · aerial/Tasmap thumbnails are drawn on the device and
  cached in Caches, never bundled or committed · status-on-tile **P1**,
  strength boxes **P1**, season coverage **P1**, in-view legend **P1**,
  strat column **P2** · M2.

### 3.11 Relief and trees toggles

- **Burden:** a checkmark row with a hint sentence.
- **Proposal:** thumbnail tiles (relief over the bare base; trees over the
  CBD, as already designed), as toggles with an ink check corner.
- · **P1** (part of the thumbnails) · M2.

### 3.12 Location states

- **Burden:** a two-line banner ("No location fix — … Wi-Fi-only iPads
  have no GPS", seen on the iPad shot) that covers map time.
- **Proposal:**
  - The **button carries the state**: `location` / `.fill` / heading, plus a
    dashed "searching" ring, and a slashed glyph when denied.
  - The accuracy circle on the map.
  - The banner shows once per session, auto-dismisses after 4 s, and stays
    as the button's VoiceOver hint. On a Wi-Fi-only iPad (no GPS hardware),
    show the slashed state from launch and never show the banner.
- · **P2** · M2.

### 3.13 Grid readout

- **Text is right here.** The visual gap is *which point* the coordinates
  belong to.
- **Proposal:** a hairline centre crosshair while the map moves and for 2 s
  after, or permanently while the pill is in lat/lon mode.
- · **P2** · M2.

### 3.14 Storage, packs and extras

- **Burden:** a list of names and sizes, so "what's taking the space" means
  comparing numbers.
- **Proposal:**
  - Each row leads with **the same thumbnail as Layers** (one visual
    identity per pack).
  - **Proportional size bars** on one shared scale (Tasmap visibly the
    giant).
  - Seasons show their footprint silhouettes (§3.10).
  - Extras (F2F, photos, sheets): a fill bar of "x of y on this device".
  - **Detailed areas as rectangles on a silhouette map** at the top of the
    section. Tap = fly there; the row list sits underneath.
- Data: sizes, footprints, area bboxes · fine · areas map **P1**, size bars
  **P2** · M5.

### 3.15 Detailed area: framing, setup and progress

- **Burden:** "Too large for one download — zoom in". Detail is "Good z16
  1.7 m / Fine z17 0.9 m / Finest z18 0.4 m", a choice made by reading
  metres per pixel. The estimate is a number.
- **Proposal:**
  - **The frame shows the estimate.** The bar carries a size gauge filling
    toward the 60k-tile cap. Past the cap, the frame becomes a grey hatched
    frame (not red; DESIGN keeps red for delete) and Next is disabled.
  - **Detail as three crops:** the same 60 pt spot at z16, z17 and z18.
    Online, live LIST tiles via the snapshotter (drawn like the map).
    Offline, a drawn **pixel-scale glyph**: a car (4.5 m) as a 3, 5 or
    11-pixel sprite.
  - **Seasons where flown:** season footprints clipped to the frame.
  - **Progress:** the system BGContinuedProcessingTask UI, plus a fill of
    the frame on the map (tiles darken as layers complete). Delight, not
    necessity.
- · gauge **P1**, detail crops **P2**, frame fill **P3** · M5.

### 3.16 Plant ID: capture, framing, results

- **Burden:** the result is a name, a percentage and a ranked text list,
  while the real decision ("is it this one?") is a visual comparison.
- **Proposal:**
  - Keep her crop top-left (DESIGN).
  - **Compare row:** her crop beside each candidate's UN photo at the same
    size, swipeable through the top 5. Thumbnails in the list carry
    pictogram fallbacks.
  - **The ladder as a stacked bar:** one ink bar per genus split into its
    species segments, with the 50 % threshold as a hairline. A genus answer
    then *shows* "one genus, nobody past the line".

    ```
    Eucalyptus ████████▓▓▓▓░░ 92 %   ┊ 50 %
               amygdalina 41 · pulchella 30 · …
    ```

  - "Recorded within 5 km": a dot-map inset (D) around the photo location.
- · UN photos fetched on the device · compare **P1**, stacked bar **P1**,
  inset **P3** · M6.

### 3.17 Credits and About

Text by nature (licences). Visual aid: each credit block leads with the
thumbnail of the layer it covers. · **P3** · M7.

### 3.18 First launch, still downloading, offline, errors, empty

- **Proposal:**
  - **No generic illustrations:** they read as "app", not "map", and DESIGN
    principle 5 rules out fluff. Instead, *show the real thing*:
    - still downloading = a progress ring on the Layers button and a greyed
      thumbnail, after a banner of 5 s at most;
    - offline photo = the growth-form pictogram;
    - empty search = the locator silhouette with the nearest typo-tolerant
      matches;
    - an error = one line with an action.
- · **P2** · M7.

### 3.19 iPad side by side

See §4 ("the map table"). Also a **comparison strip**: the last 5 tapped
communities as key boxes along the card top, tap to reselect. It is a visual
memory of the comparison. · **P3** · M8.

## 4. Exploring for pleasure

The browsing lens asks two things of each screen: does it reward idle
looking, and does it offer a next place to go without asking anything of her?

**Beauty at every zoom (M2, P1).**
- Fix the tile blocks.
- Run a per-zoom label-density review over topo, Tasmap and aerial (our
  codes from z14 only; trees cluster below z15).
- Relief by default for browsing is worth testing: it is the single biggest
  "looks like a beautiful map" lever. *Decision:* default on, or off as
  today?
- Offline above z15, the stretched tiles go soft; cap auto-zoom (search,
  clusters) at z17 so idle flights never land on mush.

**Chrome that recedes (M2/M7, P1).**
- Banners: one per session, auto-dismiss, never repeat. "Still downloading"
  collapses into the Layers-button ring.
- **Calm map:** dragging the sheet below its bar detent tucks search into a
  single glass button. On iPad, ⌘. (or a "Map only" item) hides card and
  pills; any tap brings them back.
- The scale and grid cluster fades to 40 % after 5 s idle and returns on
  movement.
- *Decision:* calm mode on a gesture, or only by command?

**Fluid motion (M2, P1).**
- Thumbnails, legend sampling and season probes stay off the main thread.
- Flights use MapLibre's zoom-out–pan–zoom-in arc, so spatial context
  survives.
- Season scrubbing toggles visibility of layers already in the style.
  Measure the 145 MB texture budget on the 16e, and if needed keep only the
  scrubbed season ±1 resident.

**Data-driven wandering (M3, P1–P2).**
- **Solo a community (P1, no new data):** tapping a legend row or "where
  else" fades every other code to 10 % and leaves this one at full, over
  the whole state. A step control (‹ 3 of 20 ›) then flies through its
  largest patches (asset C). That gives "where else does this grow" as a
  walk, not a list. The same works for a geology unit or pre-1750 class.
- **Plant range walk (P2):** from the plant sheet's distribution map, "Show
  on map" draws the species' record cells as an ink dot layer. It overlays
  any base, so she can see which communities it follows.
- **Places to wander (P3, decision):** the empty search state shows a short,
  static, data-derived set, each item with a locator glyph:
  - the rarest communities (smallest ha);
  - notable-tree clusters;
  - richest record cells (most species per km², from nearby.bin);
  - "cleared since 1750" hotspots (pipeline: pre-1750 native classes under
    TASVEG agricultural/urban codes; needs the group crosswalk).

  It never changes daily and has no "new" dot.

**Compare as a first-class tool (P2, M7, decision).**
- One mechanism: two synced map views, the top one masked by a draggable
  vertical divider. Each side gets its own layer state.
- Three presets:
  - season A | season B;
  - pre-1750 | today;
  - aerial | vegetation.
- The season slider gets a "compare with…" second thumb.
- Cost: about double the texture memory. Fine on the iPad Pro; measure on
  the 16e (phone could fall back to a press-and-hold "peek" that swaps
  state while held).
- Licence: aerial tiles are only rendered, never combined into an image, so
  it is fine.

**Serendipity at the season slider (P1, M2).** Scrubbing is the experience:
- the map swaps live (fades already off);
- a `.selection` haptic per detent;
- the footprint silhouettes above the ticks show where each year will
  change something before she scrubs.

**The iPad as a map table (P3, M8).**
- Support multiple scenes, so Split View holds two IzzyMap windows, e.g.
  aerial left and TASVEG right.
- Each scene has its own layer state. "Link cameras" is an optional per-
  window toggle.
- In landscape, the side card can collapse to its header for a near-full
  map.

**What not to do:** no feeds, no "plant of the day", no badges, streaks,
counts of places visited or "explored %", no notifications (location-based
or otherwise), no onboarding carousels, no autoplay or animated fills, no
share prompts, and no unread dots on Places to wander. Browsing is
self-directed; the map is the reward.

## 5. Top 10

1. **Fix the tile-block artefact; per-zoom beauty review** (both lenses).
   M2.
2. **Layer thumbnails carry status and size on the tile; strength as three
   drawn key boxes.** M2.
3. **Season slider with per-season footprint silhouettes, live scrub and a
   ring on the season shown here.** M2.
4. **Legend "In view" section with share bars, and solo-a-community with a
   step-through of its patches.** M2/M3, asset C.
5. **Plant faces in the collapsed Plants row; photo-first rows with
   growth-form pictogram fallback and evidence bars.** M3, asset A.
6. **"Where else" mini-map on the community card** (silhouette + presence
   grid). M3, assets B and C.
7. **Plant sheet: height as a section drawing against a human figure, and
   a distribution map from nearby.bin.** M3.
8. **Plant ID: her crop beside each candidate photo; the genus/species
   ladder as a stacked bar with a 50 % line.** M6.
9. **Chrome that recedes:** one-time auto-dismissing banners, a calm-map
   detent, state carried by the location and Layers buttons. M2/M7.
10. **Storage and areas as pictures:** shared thumbnails, proportional size
    bars, detailed areas on a silhouette map; the framing bar gauge. M5.

## 6. Risks and accessibility

- **Clutter at peek.** The peek gets exactly one new graphic (faces); the
  structure glyph, mini-map and then/now live at medium and above. Bloom
  mini-strips appear only in lists, never on the card header.
- **Colour-only encoding.**
  - Key boxes always sit beside their code.
  - Season footprints are ink silhouettes, not hues.
  - Evidence and share bars are ink.
  - Nothing relies on red/green.
- **VoiceOver.** Every graphic has a sentence label: the current text is
  that label (e.g. "Flowers September to November, in flower now";
  "Jurassic, about 180 million years"). Use Swift Charts
  `accessibilityChartDescriptor` (audio graphs) for the bloom chart, time
  bar and ID ladder. Pictograms carry their form name.
- **Dynamic Type.**
  - Pictograms are symbols, so they scale with text.
  - Thumbnails grow to 72 pt at AX sizes.
  - Mini-maps keep their size but move below the text.
- **Reduce Motion.** Solo flights, scrub previews and the frame fill become
  cuts.
- **Performance and battery.**
  - Snapshotter thumbnails are rendered once per pack version and cached in
    Caches.
  - The in-view legend samples on idle only.
  - Compare mode doubles map memory; measure on the 16e before shipping it
    there.
- **Network.** Photo-first lists fetch thumbnails online, about 10 KB each
  and lazily. Offline they fall back to pictograms, never spinners.
- **Licensing.**
  - Every aerial/Tasmap/UN/F2F/tree-sheet visual above is *rendered on the
    device* from device-held or device-fetched bytes. Nothing is bundled.
  - **The design screenshot matrix (M7) must not be committed to the public
    repo when it shows aerial or Tasmap** (that would be hosting a CC
    BY-NC-ND derivative). Keep such shots in scratch, or crop to topo and
    vector.
  - New bundled assets (silhouette, presence grids, footprints) are
    CC BY-derived facts, so add them to About.
- **Honesty.**
  - Bars show sites, not "abundance".
  - The distribution map says "where recorded, not where absent".
  - Then/now says "modelled" on the pre-1750 side.

## 7. Decisions for Leo and his partner

Round 2 answered (2026-11-04, DESIGN.md §8): relief **on** by default (1);
"Places to wander" **later** (4, NATIVE_PLAN "Future ideas"); plant lists
stay **lists**, no palette (5); habitats as **colour key boxes** (6, the
mapping derived from the records, Riparian hatched); the map stays light in
dark mode; the elevation drawings are approved. Still open: 2, 3, 7.

1. Relief on by default (browsing beauty) or off as today?
2. Calm-map mode: a gesture (sheet below the bar), a command only, or both?
3. Compare/swipe mode on iPhone (memory cost) or iPad only, with
   press-and-hold peek on the phone?
4. "Places to wander": wanted at all? It is static and data-derived, not a
   feed.
5. Palette (photo grid) as the default plant-list view, or List?
6. Habitat chips coloured by VEG_GROUP (approximate mapping) or plain text?
7. Pipeline additions (assets B and C, season footprints, the cleared-since-
   1750 crosswalk): approve as M3 pipeline work.
