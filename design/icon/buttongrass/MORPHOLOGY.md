# Buttongrass (*Gymnoschoenus sphaerocephalus*): morphology spec for the IzzyMap icon

**Subject.** A small tussock of buttongrass, *Gymnoschoenus sphaerocephalus*
(R.Br.) Hook.f. (Cyperaceae): four rigid culms, three heads in flower and one
old head. Buttongrass is the sedge that dominates Tasmania's buttongrass
moorland (TASVEG MBU, MBS, MBE, MBP, MBR and MBW). This icon replaced the
fagus leaf (`../fagus/`), which was too close to the logo of the company
Leo's partner works for.

**History.**
- Leo chose concept B, the tussock, from three concepts on 2026-11-04.
- An independent botanical review (VicFlora, PlantNET, the UTas key, Leo's
  photos) found no errors. Its refinements are applied; see "Review" below.

**How it is drawn.** Nothing is traced. `gen.py` generates the geometry from
the ratios below; every number here can be checked in that code.

## Sources

- **[VF-sp]** VicFlora, *G. sphaerocephalus*: Wilson KL (1994), *Flora of
  Victoria* 2. The same text is on PlantNET.
  - https://vicflora.rbg.vic.gov.au/flora/taxon/ef12d646-de41-4f47-a88c-8ad8d68b6e72
  - "Culms terete or somewhat compressed, striate but smooth, glabrous, often
    1 m or more high, 1–2.5 mm diam."
  - "Inflorescence 1.5–2 cm diam."
  - "involucral bracts usually 3, broad and sheathing at base", "to about as
    long as inflorescence".
  - Glumes "glistening, yellow-brown, papery".
  - "Anthers 2.5–3 mm long; apical appendage 0.3–0.7 mm long".
  - Leaf blade "often 50 cm long, 1–2.5 mm wide"; sheath "greyish
    yellow-brown".
- **[VF-gen]** VicFlora, genus *Gymnoschoenus*.
  - https://vicflora.rbg.vic.gov.au/flora/taxon/2a673656-dbd0-4302-a406-cfd1bbfffdd7
  - "Culms rigid, nodeless."
  - "blade rigid, flat or concave".
  - "Inflorescence a dense, globose head."
  - "Spikelets numerous, compressed, with 1 bisexual flower and a male one
    below it."
  - "stamens 3"; "style 3-fid".
- **[PN]** NSW Flora Online (PlantNET), K.L. Wilson. Same description as
  [VF-sp]; it calls the plant a "Big tussock-forming perennial".
  - https://plantnet.rbgsyd.nsw.gov.au/cgi-bin/NSWfl.pl?page=nswfl&lvl=sp&name=Gymnoschoenus~sphaerocephalus
- **[UTK]** Key to Tasmanian Dicots, University of Tasmania (Student's Flora
  of Tasmania 4b:119).
  - https://dicotkey.utas.edu.au/dicotkey/Cyp/gGymnoschoenus.htm
  - "large, dense clumps of long, narrow, yellow-brown leaves".
  - "a spherical head of flowers and fruit (typically about 15mm wide)".
  - "a short subtending bract".
- **[UN]** Understorey Network Tasmania plant page (text in the app's
  `plants.json`).
  - https://database.understorey-network.org.au/plant/gymnoschoenus-sphaerocephalus
  - "Densely tufted perennial sedge forming large tussocks. Stems are round in
    cross-section."
  - Flowering Sep–Feb.
  - Its two photos were viewed for reference only, not stored: flower ©
    Anna Povey, habit © Helen Morgan.
- **[F2F]** *From Forest to Fjaeldmark*, moorland chapter. Paraphrased only,
  under LICENSING.md: buttongrass moorland is the only extensive vegetation
  type dominated by a large hummock-forming tussock sedge.
- **[Leo]** Leo's three reference photos. The licence is unknown, so they are
  reference only: not traced, and never copied into the repo. What they show:
  - In flower, the globose heads read pale cream and fluffy. Fine cream
    ribbons (the anthers) droop and twist out of a core of dark brown-green
    spikelets.
  - Older heads are dark chocolate to near-black.
  - Culms are slender and stiff, pale green to golden, at several heights.
  - The tussock is fine, wiry and golden-olive.
- **Not available.**
  - Flora of Tasmania Online has no Cyperaceae treatment yet.
  - Flora of Australia Online has no profile for this species (HTTP 404).

## Spec

| # | Character | Spec (source) |
|---|---|---|
| S1 | Habit | Big, dense, tufted tussock / hummock [PN, VF-gen, UTK, F2F]. Culms rise well above the leaves, about 2× the tussock height [UN photo, Leo] |
| S2 | Leaves | Basal; blade rigid, flat or concave [VF-gen], to ~50 cm × 1–2.5 mm [VF-sp]. Yellow-brown [UTK]; sheaths greyish yellow-brown [VF-sp]. Dead leaf bases are dark at the crown [Review] |
| S3 | Culms | Rigid, nodeless [VF-gen]; terete, smooth, ≥ 1 m, 1–2.5 mm diam [VF-sp]. Pale green to golden [Leo] |
| S4 | Head | A dense, globose head [VF-gen], 1.5–2 cm [VF-sp], typically ~15 mm [UTK]. Terminal, single |
| S5 | Spikelets | Numerous, compressed; 1 bisexual flower with a male one below [VF-gen]; ~5 mm long. Glumes 6–8, glistening, yellow-brown, papery [VF-gen, VF-sp]. In flower they look olive to brown-green with dark tips [Leo] |
| S6 | Bracts | Usually 3, broad and sheathing at the base, up to about as long as the head [VF-sp]. Their bases sit at the BOTTOM of the head and they angle out [Review] |
| S7 | Anthesis | 3 stamens per flower [VF-gen], so up to 6 anthers per spikelet. Anthers linear, 2.5–3 mm + a 0.3–0.7 mm appendage [VF-sp]. Cream, fine, twisted and drooping [Leo]. Style 3-fid [VF-gen] |
| S8 | Season | Flowering spring–summer [VF-sp], Sep–Feb [UN]. Old heads go dark chocolate to near-black [Leo, Review] |

## Review refinements (2026-11-04)

| # | Change | How it is drawn now |
|---|---|---|
| 1 | Old head: from reddish rust to dark chocolate | Spikelets #3A2416 → #6A3F22 (lit), shadow #24160D, tips #0E0906, glints #7E5534. It is no longer a sweetgum or plane fruit |
| 2 | Anthers: finer, twisted, drooping; no V/Y "antler" pairs | Each anther starts from its own floret, offset ±0.08 R from the spikelet tip, and those of one spikelet hang roughly parallel (±0.24). Half-width 0.0225–0.029 R. The apparent width pulses with a 0.8–1.6 half-turn twist. A gravity sag of up to 0.65 L makes face-on anthers hang across the head. Up to 5 are drawn per front spikelet, 3 per rim spikelet (real maximum 6). This also moves the look away from Allium or a dandelion clock |
| 3 | Bracts: broad bases at the bottom, angled ~60° from vertical | Two of the three per head: 1.25 R and 0.8 R long, base width 0.2 R, at the head's base, at ±60°. Coloured #8A6A3A → #3A2416 |
| 4 | Culms: rigid, erect to leaning | Near-straight quadratic curves; the midpoint is offset ≤ 14 px |
| 5 | Tussock: more yellow-brown, dark dead bases | Leaf ramp #3B3A1E … #BFA75E. Each blade fades to #33241A over the bottom 170 px (the crown) |
| 6 | Optional: smaller heads, more culms | Tested: 6 culms with heads 20 % smaller (`TUSSOCK_SPECS["6"]`). Kept 4 culms: at 40 px the 6-culm version turns into speckle, while 4 heads still read as cream buttons with dark centres |

## Spec → drawing

R is the head radius. The real head is 15–20 mm across, so R ≈ 8.75 mm.

| # | Drawing | Status |
|---|---|---|
| S4 | Each head is a sphere with 72 spikelet axes on a Fibonacci lattice. Axes within 34° of the culm are removed, because the culm attaches there; ~35 face the viewer | ✓ |
| S5 | Each spikelet is a 3-D compressed lanceolate solid, 0.55–0.65 R long (≈ 5 mm ✓). It is widest at 58 % of its length (the outer glume backs), half-width 0.15 R. It is projected orthographically: rim spikelets show side-on, face ones as ovate glume backs. Body: olive to yellow-brown ramp, NW-lit. Tip: dark apex. Margin: thin dark stroke. A glint stands for "glistening" | ⚠ Spikelet width (~2.6 mm) and visible count were read from photos; no source gives them |
| S7 | See review item 2. Anthers are 0.30–0.62 R (2.6–5.4 mm incl. filament) against 2.5–3 + 0.3–0.7 mm in the flora | ⚠ **Thickened ~1.25× for legibility at 180 px**; the true anther width is not in the sources. Stigmas are not drawn: they are sub-pixel in this composition |
| S6 | See review item 3 | ✓ |
| S3 | Culm width 11–14 px on R 74–98 (0.11–0.19 R ✓ vs 0.11–0.29 R). Terete, with a NW highlight and smooth (striations are sub-pixel). Colour runs pale olive-green at the base → golden straw → a warm brown just under the head | ⚠ The brown flush under the head is seen in one photo (UN) and is variable |
| S1/S2 | 360 blades from a broad crown, rigid, the outer ones arching. Back blades are drawn behind the culm bases, front ones over them. Shaded inner blades are olive-brown; sunlit front ones are yellow-brown straw; bases are dark (dead). The hummock is about half the culm height (blades ~50 cm vs culms ≥ 1 m ✓) | ✓ |
| — | **Stylisation 1: heads ~10× too big.** Real culms are ≈ 50–60 head-diameters long; here ≈ 4–5. A true-scale head would be a 3 px dot at 180 px | Deliberate |
| — | **Stylisation 2: few culms.** 4 culms, where a real tussock carries 10–15+ flowering culms (photos) | Deliberate |
| S8 | Three heads in anthesis (cream) and one old head (dark chocolate, spikelets slightly longer and more open, no anthers) | ✓ photos. ⚠ The flora texts do not describe post-anthesis colour |

**Not botanical.**
- The moorland-dusk background: light #2F3D52 → #5A5230, dark #121A24 →
  #25220F, top to bottom.
- The NW light, matching the app's hillshade.
- The glass bevel and the shadows.
- The dark core disc that stands in for deep shadow between spikelets.

**Contrast (WCAG).**
- Cream anthers #EDE2BC on the sky: 8.5:1 at the top, 6.0:1 at the bottom.
- Straw culms: 4.4:1 at the top, 3.2:1 at the bottom.
- The old head is separated by hue (chocolate against slate), not by
  luminance.

## Package, appearances and size

**Groups**, listed top to bottom:

| Group | Layers | Shadow |
|---|---|---|
| Heads | anthers (the texture), head, head-back, old-head | neutral 35 % |
| Culms | leaves-front, stem (glass) | none |
| Tussock | leaves | 20 % |

**Appearances.**
- Default and Dark each have their own background gradient.
- Tinted and Clear are derived by the system from luminance.
- Exception: the old head has a `tinted` solid fill of 50 % grey. Being
  dark, it would otherwise vanish in the tinted and clear renditions.

**Size.** Measured with `actool`, one icon per catalog. An icon with empty
layers already costs 4.7 MB, because the pre-rendered 1024 px images are
stored losslessly.

| Package | Assets.car |
|---|---|
| Fagus | 6.87 MB |
| First buttongrass B | 7.86 MB (+0.99) |
| Final | **7.34 MB (+0.46 MB)** |

The final is smaller because it has:
- 360 slightly broader blades instead of 1,000;
- 5/3 anthers per spikelet instead of 6/4;
- no culm shade ribbon and no culm drop shadow;
- defs no longer duplicated across layers.

## Install / regenerate

From this directory:

```
python3 gen.py --install           # master/ + out/ButtongrassTussock.icon -> ios/.../AppIcon.icon
uv run --with pillow python fallback.py ../../../ios/IzzyMap/Resources/AppIcon.icon \
    ../../../ios/IzzyMap/Resources/Assets.xcassets/AppIcon.appiconset
uv run --with pillow python compare.py compare.png "Fagus=../fagus/Fagus.icon" \
    "Buttongrass=out/ButtongrassTussock.icon"   # Fagus.icon: run ../fagus/gen.py first
```

- `fallback.py` writes the pre-iOS-26 PNGs: `icon.png`, `icon-dark.png` and
  `icon-tinted.png`. They are full-bleed 1024 px squares. `sips` (CoreSVG)
  rasterises the layers, which are then composited in the package's order.
- `render.sh <pkg> <dir> [size] [renditions…]` renders with Icon Composer's
  `ictool`.
- `python3 gen.py --concepts` regenerates the explored concepts: (a) single
  culm, (b) tussock, (c) close crop, each on forest green, moorland dusk and
  golden-olive moor.
- `out/` is a build product.

## Open

- ⚠ Spikelet width and visible count are taken from photos.
- ⚠ The anther width is stylised.
- ⚠ The colour of the upper culm is taken from one photo.
- ⚠ The post-flowering colour rests on photos only.
