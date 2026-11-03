# Fagus leaf (*Nothofagus gunnii*): morphology spec for the IzzyMap icon

**Subject.** One adult leaf of *Nothofagus gunnii* (Hook.f.) Oerst. — the
deciduous beech, or fagus — in autumn colour (Leo, 2026-11-03).

**Colourways.** Two, drawn on the same leaf:
- **(A) autumn gold.** The default, installed in the app.
- **(B) mid-turn.** Yellow-green along the midrib and base, shading to gold and
  amber at the margin.

**Revision 2.** This version follows the independent review, Leo's field photo
and a second reference photo. Nothing was traced: the geometry is generated in
`gen.py`, and every count and ratio below can be checked against that code
(`python3 gen.py` prints them).

## Sources

- **[FoA]** *Flora of Australia* vol. 3 (Hewson 1989), as reported by the
  independent reviewer. It gives a "shallowly cuneate to truncate base" and
  leaves "yellow to golden-brown or red" in autumn. I have not seen the
  printed text myself.
- **[FoT]** Duretto MF & de Salas MF (2009). *Nothofagaceae*, version 2019:1.
  Flora of Tasmania Online, Tasmanian Herbarium, TMAG.
  https://flora.tmag.tas.gov.au/pdf/Nothofagaceae_2019_1.pdf. It reads:
  "broadly ovate to almost orbicular, 15–22.5 mm long, margin regularly
  crenate, narrowly recurved, adaxial surface plicate, with the pinnate
  lateral veins deeply impressed … apex ciliate at first, base with a swollen
  hardened knob". The key contrasts "leaves plicate" (*N. gunnii*) with
  "leaves flat" (*N. cunninghamii*).
- **[UTK]** Key to Tasmanian Dicots, University of Tasmania
  (dicotkey.utas.edu.au, Fagales). It reads: "veins leading to the gaps
  between the rounded teeth" (*N. gunnii*) against "veins leading to teeth"
  (*N. cunninghamii*), and "the leaf lamina bulges up between the major
  veins".
- **[TSO]** Trees and Shrubs Online, *Nothofagus gunnii*. It gives the leaf
  as "10–20 × 9–17 mm", "ovate to orbicular", with an apex "obtuse or
  emarginate". It has "4–6 secondary veins on each side of the midrib",
  "usually one tooth in between the tip of each lateral vein", and
  "impressed, parallel lateral veins" (wording as quoted by the reviewer). The
  petiole is "0–3 mm" and autumn colour "golden-yellow (rarely red or
  orange)".
- **[UN]** Understorey Network Tasmania, as committed in `plants.json`. It
  describes leaves "deeply indented on the upper surface" that turn
  "golden-brown to reddish".
- **[Leo]** Leo's own field photo of *N. gunnii* in autumn. Used for
  proportions, the margin and colour only.
- **[Ref2]** A Wikipedia photograph of many leaves part-way through turning.
  Used for reference only: it is not copied and not stored with the project.
- **[Review]** The independent botanical review: Flora of Australia, Flora of
  Tasmania, the UTas key, Trees and Shrubs Online and 16 iNaturalist photos.

## Spec

| # | Character | Spec (source) |
|---|---|---|
| S1 | Blade | broadly ovate to almost orbicular [FoT, TSO]. Nearly round in the photos [Leo, Ref2] |
| S2 | L:W | 10–20 × 9–17 mm [TSO], so ≈ 1.0–1.2 |
| S3 | Apex | obtuse or emarginate [TSO]. Rounded in the photos, any notch very shallow [Leo]. The apical lobes must not be the largest [Review] |
| S4 | Base | **shallowly cuneate to truncate** [FoA]. Broad, truncate, nearly sessile [Leo, Ref2]. Crenations run almost to the petiole [Review, Leo] |
| S5 | Margin | regularly crenate [FoT]. Lobes rounded but **sinuses sharp and cut fairly deep** (crenate-serrate silhouette); lobes lean slightly toward the apex [Leo, Ref2]. Narrowly recurved [FoT] |
| S6 | Teeth vs veins | lateral veins end in the SINUSES between the teeth [UTK]; usually one tooth between successive vein tips [TSO] |
| S7 | Secondary veins | pinnate, impressed, **parallel**, 4–6 per side [FoT, TSO]. Straight, sub-parallel, ~55° to the midrib near the base and ~42° near the apex [Review: photos 45–55°] |
| S8 | Tooth count | ≈ 6–8 per side [Leo]; ≈ 7–9 per side [Ref2] |
| S9 | Plication | adaxial surface plicate, veins deeply impressed [FoT]; the lamina bulges between the veins [UTK]. Each lobe is a pleat running from the midrib to the lobe tip [Leo] |
| S10 | Petiole | short [FoT], 0–3 mm [TSO]: **very short, ≤ ~0.07 L, straight, no knob** [Review]. The "swollen hardened knob" of [FoT] is at the LAMINA base [Review] |
| S11 | Colour | golden-yellow, rarely red or orange [TSO]; yellow to golden-brown or red [FoA]; fine brown speckling [Leo]. Mid-turn leaves are green or yellow-green near the midrib and base and gold to amber toward the margin, often within one leaf [Ref2] |

### Reconciling the counts (S7 vs S8)

TSO gives 4–6 secondary veins per side, but the photos show 7–9 teeth per
side. Both hold for a truncate-based leaf:

- Between the lowest and the highest secondary there is one lobe per vein
  interval, plus one apical lobe.
- Below the lowest secondary, the truncate base edge carries further small
  crenations. Their sinuses are reached by short outer branches of the lowest
  secondary, not by additional secondaries.

The drawing therefore has 6 secondaries (TSO's upper end) and 9 lobes per side
(3 basal + 5 between veins + 1 apical), at the upper end of the photo counts.

The basal branches are an inference about venation; no source states it.
Geometry forces the problem: a truncate base (edge at ~77° to the midrib) with
straight secondaries at ≤ 56° leaves about 40 % of each half-margin below the
lowest vein's tip. Something must supply the "crenations almost to the
petiole" there, and outer tertiary branches of the basal secondaries are the
usual arrangement in toothed, pinnately veined leaves. **Flagged for the
reviewer.**

## How the drawing satisfies it

The figures are measured from `gen.py`, in blade-length (L) units.

| # | Drawing | Status |
|---|---|---|
| S1 | Spline outline, widest at ~0.43 L; it reads as nearly round | ✓ |
| S2 | Measured outline 1.017 × 0.966, so **L:W 1.05** | ✓ within 1.0–1.2 |
| S3 | Obtuse apex. The midrib ends in a 0.010 L notch, which is barely visible. Apical lobe arc 0.10 of the half-margin; the largest lobe is a basal one at 0.133 | ✓ shallow notch; apical lobes are not the largest |
| S4 | The base edge leaves the petiole at ~77° to the midrib (truncate to shallowly cuneate). It carries 3 low crenations right down to the petiole | ✓ |
| S5 | Each lobe is two cubics: round tip, **V-sinus 0.046 L deep**, flanks leaving the sinus steeply. Tips sit at 0.58 of the sinus-to-sinus span, leaning toward the apex | ✓ crenate-serrate. The recurved rim is not drawn separately: the glass edge carries it |
| S6 | Every secondary is a straight line from the midrib ending **exactly at a sinus** (the sinus lies on the vein line). There is one lobe per vein interval | ✓ the diagnostic character against *N. cunninghamii* |
| S7 | **6 pairs**, straight. Angles 56°, 53°, 50°, 47°, 45°, 42° from base to apex; origins at 0.01, 0.14, 0.28, 0.44, 0.61, 0.79 L | ✓ sub-parallel, 55° → 42° as specified |
| S8 | **9 lobes per side**: 3 basal (on branches of vein 1, drawn thinner), 5 between secondaries, 1 apical | ✓ within the photo range; see the reconciliation above |
| S9 | Every lobe is a pleat: a ridge from the midrib to its tip, split into two flanks. Each flank is a gradient from a crisp, darker crease at the impressed vein to the flat tone at the rounded ridge. Light comes down the leaf axis from the NNW (close to the app's NW hillshade), so both halves read equally. The veins are thin amber #B8650F grooves (5 → 2.2 px; midrib 9 → 3 px), darker than every blade tone, so the tinted and clear appearances keep the structure. The basal crenations are shallower pleats | ✓ the crinkle comes from relief, not strokes |
| S10 | Petiole 0.044 L (≈ 0.7 mm on a 15 mm blade), straight, slightly tapering, no knob. The broad midrib base (9 px) stands in for the swollen lamina base | ✓ |
| S11 | **(A)** gold ramp #B5600C → #D98A16 → #EDB026 → #F8D04A → #FDE68C, with an orange flush (#E2621C, radial, ≤ 55 %) at two lobe tips. **(B)** the same, plus a yellow-green copy of the relief (#7C8E16 → #F0EE98), masked by a radial falloff from the lower midrib: green at the base and midrib, gold to amber at the margin. Both have 420 fine brown flecks (#8A4A12 at 18–40 % opacity, ~1–2 px at 1024), which disappear below 180 px | ✓ |

**Not botanical.**
- The dark-green background: gradient #34503A → #1C2F23, or #142219 →
  #08110C in dark mode.
- The Liquid Glass bevel and the neutral 30 % drop shadow.
- The hillshade lighting convention.
- The upper-surface hairs, which are invisible at icon sizes, so they are
  omitted.

## Open for the reviewer

- The basal crenations served by outer branches of vein 1 (S8 reconciliation).
- Whether the flecks (S11) belong on an icon at all.
