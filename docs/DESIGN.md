# IzzyMap native — design brief and design language (2026-11-03)

Companion to `NATIVE_PLAN.md` (§4 interface, milestone 7). Drafted at the end
of milestone 1 so every later milestone builds to it; the M1 screenshots it
critiques are functional placeholders, not designs.

## 1. Brief

**Subject.** Tasmania's mapped vegetation: 156 TASVEG communities over LIST
topo, aerial and paper maps, with the plants that make each community up.

**Audience.** Above all, a landscape architect. She reads cartography,
planting plans and printed keys professionally, writes botanical names
correctly, and sees a muddy tint or lazy line weight before the feature.
Secondary: Leo, the household iPad.

**Primary job.** *"Which plant community am I standing in — and what grows
in it?"* Everything else (search, trees, plant ID, downloads) serves that
question or the walk to it.

**Contexts.**

- iPhone 16e outdoors: sun glare, one hand, sometimes gloves, often offline,
  battery matters. Glances, not sessions.
- iPad Pro 12.9" at home, landscape, keyboard and trackpad: planning a walk,
  comparing communities side by side, reading F2F descriptions.

**Design principles.**

1. **Colour is data; chrome is ink.** The TASVEG palette is fixed and loud
   (29 saturated fills, 1990s-GIS acid greens). It looks considered only if
   nothing competes with it: no brand hue in the chrome. Every colour on
   screen means something — a community, a photo, the GPS dot, a delete.
2. **The map is a printed sheet.** It never goes dark, never animates its
   fills, and is annotated as a cartographer would: cased ink lines,
   keylined key boxes, codes on polygons, a checkered scale bar.
3. **Names are typeset.** Living things (communities, plants, trees) are
   set in New York with botanical italics; everything else is SF — a rule
   mechanical enough to implement, visible enough that she'll notice.
4. **The answer fits in a glance.** The smallest tapped-feature detent
   (key box, code, name) answers the primary job, and the map stays
   tappable for the next comparison.
5. **Honest states.** Uncertainty, offline and "still downloading" are said
   plainly with the next step; no shimmer, no reward for an unsure answer.

## 2. Tokens

### Colour roles

Chrome uses system materials and system label colours throughout; Liquid
Glass, Increase Contrast and Reduce Transparency are the system's. The
custom roles are few:

| Role | Light | Dark | Use |
|---|---|---|---|
| `ink` | `label` (#000000) | `label` (#FFFFFF) | app tint: glyphs, links, prominent buttons (ink fill, inverse text), progress |
| `mapInk` | #000000 | #000000 (map is always light) | selection line, map code labels |
| `mapHalo` | #FFFFFF @ 85 % | same | halo under every map ink line/label |
| `keyline` | #000000 @ 50 % (= #808080 on white, 3.98:1) | #FFFFFF @ 45 % (≥ 4.2:1 on #1C1C1E/#2C2C2E) | 0.5 pt border on key boxes, flowering cells, scale bar |
| `keyPlate` | #FFFFFF | #FFFFFF | opaque ground under every key box on glass |
| `treeGreen` | #1F5130 (9.2:1 on white) | same | Hobart significant trees on the map only |
| `location` | system blue | system blue | the user dot — a platform convention, not ours |
| `destructive` | system red | system red | Remove, Delete |

- **No accent hue.** App tint = `ink`; prominent buttons are ink capsules
  (21:1). **No `Toggle`s** — an ink toggle in dark mode is a white knob on a
  white track; binary choices are checkmark rows, like a key's tick-boxes.
- **Key boxes are opaque.** Glass tints whatever sits on it (the M1 card's
  RPW swatch floats on a rainbow of refracted map), so every key box sits on
  `keyPlate` and is judged against white, as on paper.
- **Key box colour = the map:** the official fill composited at the current
  strength over white (RPW #3232FE at 0.55 → #8E8EFE), because the key's job
  is matching what she sees. The card lists the official hex as a fact
  ("Map colour #3232FE"). See open question 4.
- **Why red selection is out.** #FF3B30 on SMM #CB6565 at 0.5 is 1.9:1, on
  SHS #FE9898 2.5:1, and topo roads are red-brown. Ink on a white halo is
  ≥ 7.5:1 on every composited fill; over dark aerial forest the halo does
  the work (black alone 1.7:1, white halo 12:1).

### Typography

SF everywhere in chrome; **New York (`design: .serif`) for names of living
things**; every style is a Dynamic Type text style.

| Element | Style |
|---|---|
| Community name (card title) | `.title3` NY semibold; taxa italic |
| Community code ("DOB") | `.footnote` SF semibold `.uppercaseSmallCaps()`, tracking +0.5 |
| Card facts (group, structure, weeds) | `LabeledContent`: label `.subheadline` secondary, value `.body` |
| Section headers ("Plants", "Base map") | `.headline`, sentence case |
| Plant row | botanical `.body` NY italic; common name `.subheadline` SF secondary |
| Plant sheet title | botanical `.title2` NY italic; common `.title3` SF regular below; family `.subheadline` SF upright |
| Field-guide prose (habitat, notes) | `.body` SF, line spacing +3, measure ≤ 70 ch |
| Photo credit | `.caption2` SF secondary, under the photo |
| Search result | name `.body`; locality `.subheadline` secondary; distance trailing `.subheadline` monospaced digits |
| Grid readout | `.footnote` SF medium, `.monospacedDigit()` |
| Scale bar labels | `.caption2` monospaced digits |
| Sizes, percentages, counts | `.monospacedDigit()` wherever they update or align |

- **Botanical convention.** Genus and epithets italic; rank words
  (`subsp.`, `var.`, `f.`, `sp.`, `aff.`) and hybrid `×` upright. Community
  names contain taxa and get the same treatment: "*Eucalyptus obliqua* dry
  forest", "*Nothofagus*–*Atherosperma* rainforest" (the table's " - "
  becomes a closed-up en dash in the UI, never on the map — Latin-1). An
  IzzyKit formatter returns an `AttributedString` from the genus set in
  `plants.json` plus TASVEG names; unit-tested.
- **Codes: SF small caps, not SF Mono.** "DOB" is a reference mark, like the
  code beside a box on a printed TASVEG sheet. Small caps sit at x-height,
  so it doesn't shout over the name; monospace reads as computer output.
  In the key the code column gets a fixed width measured from "WWW".
- **Numerals.** Proportional in prose; monospaced digits wherever figures
  tick or stack. MGA grouped by thin spaces, as surveyors write it. Units
  after a no-break space ("3.2 GB").
- **Map labels** (Latin-1 glyph PBFs): Noto Sans Bold for codes and
  clusters, Regular for tree names. SF's licence doesn't cover re-encoding
  it as glyph PBFs.

### Space, corners, elevation

- Spacing scale 4 / 8 / 12 / 16 / 24 / 32. Card and sheet content inset 16
  (20 on iPad); rows 12 vertical; between sections 24.
- **Two shape families.** *Chrome* is concentric: radii come from the
  sheet/card via `ConcentricRectangle` / `.containerShape` (inner = outer −
  inset); buttons are capsules. *Data* is square: key boxes, flowering
  cells, scale bar, photos and thumbnails have 0 radius — printed matter.
  No 8 pt "friendly" radius anywhere in between.
- **Elevation is the system's.** Glass only on the navigation layer
  (controls, sheet/card, grid cluster, framing bar); never on content, never
  glass on glass, no custom shadows.
- **Touch.** Map controls 48 pt (gloves); everything else ≥ 44 pt. No
  swipe-only actions.

### Iconography (SF Symbols, monochrome ink, regular weight)

- Map: Layers `square.2.layers.3d`; Location `location` → `location.fill`
  → `location.north.line.fill`; Attribution `info.circle` in an ink glass
  button (replaces MapLibre's blue (i)).
- Sheet: `magnifyingglass`; Identify a plant = custom `leaf.viewfinder`
  (`viewfinder` corners round `leaf`; fallback `camera.macro`).
- Content: Key `list.bullet.rectangle`, Read the description `book.pages`,
  data sheet `doc.text`, Relief `mountain.2`, trees `tree`, seasons
  `photo.stack`, Storage `internaldrive`, area `square.dashed`; download /
  on device / remove `arrow.down.circle` / `checkmark.circle` / `trash`.
- Result types: `mappin`, `road.lanes`, `house`, `mountain.2`, `drop`,
  `building.2`, `tree`.

### Haptics (`.sensoryFeedback`)

- `.selection`: a feature is selected; a season slider detent; key-row tap.
- `.success`: plant ID names a **species**; an area download finishes in
  the foreground. A genus answer gets `.selection`; "Not sure" gets nothing
  — a success buzz for an unsure answer would be a lie.
- `.impact(weight: .light)`: location mode changes.
- `.error`: only when a user-started action fails (download, PDF fetch).
- Never on pan/zoom, async data arriving, or detent snaps (system).

### Motion

- **Moves:** camera flights after a search (duration ∝ log distance, capped
  1.2 s); sheet detents (system springs); list → plant sheet as a zoom
  transition from the thumbnail (`navigationTransition(.zoom)`); framing
  frame follows the finger 1:1.
- **Never moves:** the selection line (appears instantly — no pulse, no
  draw-on), fills on strength change, season swaps (fades already off),
  progress numbers, the key.
- **Reduce Motion:** flights become a cross-fade cut; the zoom transition
  becomes the system cross-fade; following keeps north-up.

## 3. Layout

Size class decides, never device: **compact width with regular height** →
bottom sheet; **regular width or compact height** → floating leading card
(so iPhone landscape behaves like the iPad, as Apple Maps does).

Sheet detents (iPhone portrait): **bar** (search field only, ~76 pt) ·
**peek** (bar + card header, ~176 pt — the glance) · **medium** (~45 %) ·
**large**. Tapping a feature raises the sheet to *peek*, never higher.

```
iPhone portrait — map idle          iPhone — tapped, peek detent
┌──────────────────────────┐        ┌──────────────────────────┐
│                     ┌──┐ │        │                     ┌──┐ │
│                     │▤ │ │ Layers │      ╭──────╮       │▤ │ │
│      map (paper)    │➤ │ │ Locate │     ╱ ▓▓▓▓▓▓ ╲ ink  │➤ │ │
│                     └──┘ │        │     ╲▓▓RPW▓▓╱ +halo └──┘ │
│                          │        │      ╰──────╯            │
│ ▮▯▮▯ 10 km               │        │ ▮▯▮▯ 10 km               │
│ ┌E 526 340  N 5 252 210┐ │        │ ┌E 526 340  N 5 252 210┐ │
│╭────────────────────────╮│        │╭────────────────────────╮│
││ 🔍 Search places    ⌖🍃││        ││ 🔍 Search places    ⌖🍃││
│╰────────────────────────╯│        ││┌──┐ rpw              ✕ ││
└──────────────────────────┘        │││▓▓│ Athrotaxis       ││
                                    ││└──┘ cupressoides open  ││
 ⌖🍃 = leaf.viewfinder              ││     woodland           ││
                                    ││ Plants  22 named  ⌄    ││
                                    │╰────────────────────────╯│
                                    └──────────────────────────┘
TASVEG card, medium → large         Tree card (medium)
╭────────────────────────╮          ╭────────────────────────╮
│ 🔍 Search places    ⌖🍃│          │ 🔍 Search places    ⌖🍃│
│┌──┐ rpw               ✕│          │ ● Hobart significant ✕ │
││▓▓│ Athrotaxis cupres- │          │ English oak            │  NY roman
│└──┘ soides open woodland│          │ Quercus robur          │  NY italic
│ Group      Rainforest… │          │ 18 Davey St, Hobart    │
│ Structure  Open wood…  │          │ Trees      3           │
│ Weeds      —           │          │ Accuracy   ±5 m        │
│ Map colour #3232FE     │          │ Register note …        │
│ [📖 Read the description]          │ [📄 Open the data sheet]│
│ Plants                 │          ╰────────────────────────╯
│  Named in the description (14)
│  ┌──┐ Athrotaxis cupressoides     ┌──┐ = square UN thumb
│  └──┘ pencil pine                  │
│  ┌──┐ Richea scoparia             │
│  └──┘ scoparia                     │
│  Often recorded here (40) ›        │
│  Recorded near here (31) ›         │
╰────────────────────────╯
```

Plant sheet (pushed; large detent on iPhone, card on iPad):

```
╭──────────────────────────╮
│ ‹ Plants             ✕   │
│██████████████████████████│  photo plate, full width, 4:3,
│██████████████████████████│  contain on paper, square corners,
│█████████ 1 / 3 ██████████│  paged; no text on the photo
│ Photo: J. Smith, with permission    caption2, under the plate
│                          │
│ Richea scoparia          │  title2 NY italic
│ scoparia                 │  title3 SF
│ Ericaceae                │  subheadline, upright
│                          │
│ Flowering                │
│ S O N │D J F│M A M│J J A │  spring-first bloom chart:
│ ■ ■ ■ │■ □ □│□ □ □│□ □ □ │  ■ ink, □ keyline; today ▴
│       ▴                  │
│ Form     Shrub to 2 m    │
│ Flowers  Pink, white…    │
│ Habitat  Subalpine…      │
│ Notes    …               │
│ [View on Understorey Network]
╰──────────────────────────╯
```

The bloom chart starts in **September**: a January start splits Tasmania's
main (summer) flowering across both ends of the strip; seasons sit in
contiguous threes with a gap between them, like a planting-plan bloom chart.

```
iPhone landscape (compact height)       iPad landscape (regular width)
┌───────────────────────────────────┐   ┌──────────────────────────────────────────┐
│╭──────────╮                 ┌──┐  │   │╭────────────╮                       ┌──┐ │
││🔍 Search ⌖│                │▤ │  │   ││🔍 Search  ⌖🍃│                     │▤ │ │
││┌─┐ dob   ✕│      map       │➤ │  │   ││┌──┐ dob    ✕│        map          │➤ │ │
│││▓│ E. obl- │                └──┘  │   │││▓▓│ Euca-   │   (live beside the   └──┘ │
││└─┘ iqua…  │                      │   ││└──┘ lyptus… │    card: tap another      │
││ Plants ⌄  │▮▯▮▯ 1 km  E…  N…     │   ││ facts…      │    polygon to compare)    │
│╰──────────╯                       │   ││ Plants …    │                           │
└───────────────────────────────────┘   │╰────────────╯ ▮▯▮▯ 1 km  E 526… N 5 252… │
 card 320 pt, full height − margins     └──────────────────────────────────────────┘
                                         card 380 pt; content-sized, max full height
iPad portrait: same card, 360 pt; Layers is a popover from the button.
```

Search results (sheet at medium/large, card on iPad):

```
╭──────────────────────────╮
│ 🔍 mount wel│          ✕ │
│ ▲ Mount Wellington       │  .body
│   Wellington Park   18 km│  locality secondary, distance trailing
│ ▲ Wellington Range       │
│   Wellington Park   21 km│
│ ⌂ 12 Wellington St       │
│   Launceston       190 km│
╰──────────────────────────╯
selected → sheet header: "Mount Wellington  ✕" and an ink pin on the map
```

Layers and the key:

```
Layers (sheet / iPad popover)           Key (pushed)
╭──────────────────────────╮            ╭──────────────────────────╮
│ Layers               ✓   │            │ ‹ Layers    Vegetation   │
│ Base map                 │            │ Dry eucalypt forest     A│
│ ✓ Topographic  on iPhone │            │ ┌──┐ dac  E. amygdalina  D│
│   Aerial    Download 1.9 GB           │ │  │      coastal …      G│
│   Paper map Download 3.2 GB           │ │  │ dad  E. amygdalina  H│
│   Photos by season       │            │ │  │      on dolerite    M│
│   ├──●───────┤ 2023–24   │            │ └──┘ … (9 codes, one box) N│
│   Showing 2023–24 photos here         │ ┌──┐ dde  E. delegatensis R│
│ Overlay                  │            │ └──┘ …                   S│
│ [Veg|Pre-1750|Geology|Off]            ╰──────────────────────────╯
│   TASVEG 5.0 communities │
│ Strength  [Full|Light|Outlines]       one box per colour run, spanning
│ Also show                │            every code that shares the fill;
│ ✓ Relief    ✓ Hobart trees            native section index trailing
│ Key ›          Storage › │
╰──────────────────────────╯
```

Plant ID:

```
1 capture            2 frame                     3 result ladder
system camera  →  ┌────────────────────┐  →  ╭──────────────────────────╮
or PhotosPicker   │ photo, full bleed  │     │┌────┐ Eucalyptus          │
                  │   ┌ ─ ─ ─ ─ ┐      │     ││crop│ amygdalina          │ species: NY italic title
                  │     square        │     │└────┘ black peppermint    │
                  │   └ ─ ─ ─ ─ ┘      │     │ Recorded within 5 km      │
                  │ (drag / pinch;     │     │ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ 71 %    │ ink bar, mono digits
                  │  outside dimmed)   │     │ Other possibilities       │
                  │╭──────────────────╮│     │┌──┐ E. pulchella  12 %    │
                  ││Frame one plant   ││     │└──┘ white peppermint      │
                  ││       [Identify] ││     │┌──┐ E. viminalis   6 %    │
                  │╰──────────────────╯│     │└──┘ …                     │
                  └────────────────────┘     ╰──────────────────────────╯
 Genus verdict: "A Eucalyptus — species unsure". No verdict: "Not sure.
 These are the closest matches." Her crop stays top-left so every row can
 be compared against it. No traffic-light colours.
```

Storage:

```
╭──────────────────────────────╮
│ Storage                    ✓ │
│ ▮▮▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯ │ one bar: IzzyMap / other / free
│ IzzyMap 6.1 GB, 41 GB free   │
│ On this iPhone               │
│  Vegetation, geology…  0.39 GB│ (installs with the app)
│  Topographic           2.04 GB│
│ Available                    │
│  Aerial photos   [Download 1.93 GB]
│  2025–26 season  downloading 62 %  ✕
│ Field guide extras           │
│  F2F descriptions   37 MB  ✓ │
│  Plant photos      152 MB  [Download]
│ Detailed areas               │
│  Mount Field, z17    410 MB  │
│  [ ⬚ Download an area… ]     │
╰──────────────────────────────╯
```

States (copy is the design):

- **First launch.** TASVEG over plain paper while topo arrives, one glass
  banner: "The topographic map is still downloading (1.2 of 2.0 GB). The
  vegetation map works now." No onboarding; location is asked on the first
  Locate tap.
- **Loading.** Plants section: "Loading plants…" with a small spinner in the
  summary row. No skeletons.
- **Offline.** No global banner — offline is normal. Only an action that
  needs the network says so, in place: "This photo isn't on the iPhone yet.
  Connect, or get all plant photos in Storage."
- **Empty search.** "No places match "Mt Welington". Try a street, suburb or
  peak name."
- **No location.** One pill per session (NATIVE_PLAN §3); denied adds
  "Open Settings".
- **Unmapped tap** (sea outside TASVEG): no card; nothing happens.

Accessibility sizes: card headers reflow (key box above the text). Floating
map chrome is capped at `.accessibility1` with the Large Content Viewer — in
M1 the readout pill grows into the sheet at AX-L.

## 4. Cartography

**Overlay strength defaults** (per base; names unchanged):

| Base | Full | Light | Outlines |
|---|---|---|---|
| Topographic | 0.55 | 0.30 | band (below) |
| Paper map (Tasmap) | 0.50 | 0.25 | band |
| Aerial / seasons | 0.40 | 0.20 | band + boundaries always on |

**Community boundaries** (Full and Light): none ≤ z10, then 0.25 pt z11 →
0.5 z13 → 0.75 z15 → 1.0 z17+. Graphite (#000000 @ 20 %) on topo and
Tasmap, paper (#FFFFFF @ 45 %) on aerial. The QML outlines #ECE9D8 and
#D4D0C8 are the Windows XP and 2000 button-face greys — ArcMap defaults,
not cartographic intent — so replacing them recolours nothing the provider
designed. Fills stay exactly official.

**Outlines mode = edge band.** A 3 pt band of the official colour just
*inside* each polygon (`line-offset` inward, 85 %) plus a 0.5 pt graphite
boundary — the hand-tinted boundary ribbon of old printed maps: ground
readable, sides unambiguous. If tile-clip edges show as seams on device,
fall back to a centred 2 pt line.

**Selection (replaces #FF3B30).**

- Tapped polygon: **2.5 pt `mapInk` over a 6 pt `mapHalo` casing** — the
  printed sheet's "this one". It reads on every fill and over dark photos,
  and never borrows a hue from the data. A tapped tree gets it as a ring.
- Other polygons of the **same community**: 0.75 pt ink @ 55 %, dashed
  [2, 2], from z11 — "where else is this?" without a second colour.

**Labels.**

- TASVEG codes on polygons from z14 (Noto Sans Bold 10 → 12 pt, tracking
  0.1 em, ink @ 85 %, 1.5 pt halo), as on the official TASVEG mapsheets.
  It matters because **156 codes share only 29 fills**: colour names a
  family (nine dry-forest codes are #98FE00); the code names the community.
- Needs a pipeline label-point layer (polylabel, area threshold per zoom).
  Geology's unit symbols get the same if `SYMB` is Latin-1. Topo lettering
  is in the raster, so ours stays small.

**The key as a printed map key.**

- Boxes 28 × 18 pt (3:2), 0.5 pt `keyline`, on `keyPlate`; small-caps code
  column; NY names with italic taxa; sections = the 11 VEG_GROUPs (curated
  short names).
- One box per run of codes sharing a fill, spanning those rows, as printed
  keys bracket a shared symbol. The box mirrors the mode (composited fill,
  or an edge-band box in Outlines).
- Tapping a row draws the same-community line for it and, on iPhone,
  returns to the map.

**Scale bar** (own SwiftUI view, not MapLibre's ornament): alternating
ink/paper segments 4 pt tall, 0.5 pt keyline, 1–2–5 steps, ≤ 120 pt (phone)
/ 160 pt (iPad), labels `0  10  20 km` with the unit on the last figure. It
shares one glass cluster with the grid readout: `E 526 340  N 5 252 210`
plus a small-caps `mga55`; tap → `42.88060° S  147.32500° E`.

**Trees:** 7 pt `treeGreen` disc with a 1.5 pt white ring; areas a 1.25 pt
line over a 15 % fill; clusters a 22 pt disc with a white count. A second
dataset, so the one non-ink map colour is spent here.

**Fix before polish.** The M1 shots (iPhone card, iPad landscape) show
rectangular tile-shaped blocks of differing density in the TASVEG fill at
z6–9 — per-tile feature dropping or mixed-zoom tiles, not styling. She
will read it as a broken map; investigate in M2.

## 5. App icon (iOS 27 layered, Icon Composer)

Concept: **a eucalypt leaf cut into vegetation communities.** It shows the
same thing the app does: a plant, read through the map.

- **Background** (1024 canvas): pure #FFFFFF; three 6 px contour lines in
  LIST-topo brown #B8946A @ 55 %, running lower-left to upper-right.
- **Group 1, leaf patches** (glass: specular on, translucency off, faint
  shadow). An adult *falcate* eucalypt leaf (sickle-curved, asymmetric
  base, drip tip), 780 px long, axis rotated 35°, petiole at lower left.
  Two boundary curves cross the blade into four patches, each an official
  TASVEG fill:
  - base: buttongrass MBS #FEFE32;
  - lower: *E. amygdalina* DAM #98FE00;
  - upper: *E. regnans* WRE #00CBCB;
  - tip: rainforest RMT #0065CB.

  The leaf runs from moorland to rainforest, the state's own gradient.
- **Group 2, ink** (flat, no glass): leaf outline and boundaries #000000,
  8 px; the WRE patch carries the selection idiom (14 px ink on a 10 px
  white casing).
- **Dark:** background #000000, contours #FFFFFF @ 18 %, lines #FFFFFF.
  **Tinted:** patches as greys at 30/50/70/90 % luminance, so the tint
  reads as four tones. **Clear:** patches frosted white @ 40 %.
- **No** map pin, no Tasmania outline, no lettering.

## 6. Review against the brief

Where the first plan drifted to defaults, and what changed:

1. **Accent.** First draft: forest green plus wattle gold — the nature-app
   default and the web app's pine/wattle, and greens collide with 52 of 156
   communities. Now: no accent; ink.
2. **Swatches.** M1's rounded squircles → square, keylined, opaque key
   boxes. A rounded swatch is a UI chip; and M1's white FUR swatch vanishes
   without a keyline.
3. **Selection.** "A stronger red" → a cased ink line (measured 1.9:1 on the
   salmon heaths; clashes with topo roads).
4. **Data type.** SF Mono for codes and coordinates (the "monospace data
   label" tell) → SF small caps and monospaced *digits*.
5. **Plant sheet.** Photo hero with the name on a gradient → a book plate
   with the credit as a caption: legible in sun, honest attribution.
6. **Plant ID.** Green/amber/red confidence badges → words, ink bars and
   percentages; traffic lights add three hues and imply a safety verdict.
7. **Loading.** Shimmer skeletons → one line of plain status text.
8. **Meta strings.** "Kingston · 12 km" → locality with trailing distance.
9. **Dark mode.** A dark map style → the map stays a light printed sheet.
10. **Icon.** A generic leaf or pin → one specific leaf in the data's own
    colours, carrying the selection mark.

## 7. Open questions for her

1. In lists and on the plant sheet, botanical name first (planting-schedule
   order) or common name first?
2. Bloom chart: spring-first (Sep → Aug, as proposed) or calendar Jan → Dec?
3. Overlay strength: at 0.55 / 0.40 / 0.30, how much topo or photo should
   show through? Show her three screenshots.
4. Key boxes: blended as they appear on the map (proposed), or the official
   full-strength colour?
5. Community codes on the map from z14: a help in the field, or clutter
   over the topo's own lettering?
6. The dashed "same community elsewhere" line on selection: useful, or
   noise when tapping around to compare?
