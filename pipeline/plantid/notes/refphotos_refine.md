# Reference photos: refinement pass (2026-11-05)

`refine_refphotos.py` runs after `build_refphotos.py` (README "Reference
photos") and changes only photos it can justify: better picks for the 557
text-only classes, and an audit of the 15,768 training-photo picks.
Staging stays `cache/plantid/refphotos/pack/refphotos/`; work files in
`cache/plantid/refphotos/refine/`. Order: `gather → fetch --what snap →
embed → near → qtext → score → fetch --what picks → (score again until
stable) → sheets → apply`.

## Result

| | before | after |
|---|---|---|
| photos | 16,325 | 16,325 (516 replaced: 261 training-photo classes, 255 text-only) |
| pack (AVIF + index + credits) | 361.6 MB | **364.1 MB** (358.8 + 5.0 + 0.27) |
| licences CC0 / BY / BY-NC | 828 / 5,706 / 9,791 | 811 / 5,626 / 9,888 |
| observers | 3,309 | 3,314 |

Never an evaluation photo (re-checked against `eval_photo_ids()` over the
final index: 0), only CC0/BY/BY-NC. `refine/changes.jsonl` = one line per
replacement (old/new photo, observation, licence, login, bytes, reason);
the replaced AVIFs are in `refine/replaced/`, the previous index/credits
in `refine/index.before.json` / `credits.before.json` (rollback = copy
back). `apply` is idempotent (re-run: 0 to replace).

## Text-only classes (the 557)

- `gather`: every eligible candidate — research-grade observation in the
  snapshot, CC0/PD/BY/BY-NC, not an evaluation photo — capped at 10 per
  class, one photo per observation first. 3,407 eligible, 2,741 kept (the
  cap only bites for 96 classes; 73 classes have exactly ONE photo, 90 two).
  Fetch 23 s; embed 2,741 photos with BioCLIP 2.5 fp16 on MPS in 606 s
  (4.5 img/s — measured 3.1–3.9 img/s on 64/160 first; ViT-H/14 on the base
  M4 GPU, machine shared with other agents).
- Ranking: −logit P(bad) (probe below) + 0.5 × observer's lead photo + 0.5 ×
  z(cosine to the class's text vector — `australia/text.npz`, the
  "a photo of <taxo>." prompt the training's text init uses); flagged
  (P ≥ 0.5) and bad-shape (< 500 px / panorama) last. An unflagged current
  pick stays unless beaten by 2 logits (tuning round: unforced re-ranks were
  neutral or worse about as often as better).
- Text similarity says little about photo quality (AUC 0.54 against the
  labels) — it is a weak "does this look like the species' prompt" term.
  The lead photo is a real signal: 20 % of lead photos vs 35 % of others
  were hand/ex-situ in the labelled sample.
- 255 of 557 changed (88 of them because the old pick was flagged or
  labelled bad). 23 picks are still flagged — no clean candidate exists,
  e.g. *Acacia calcicola* has exactly one usable research-grade photo in the
  snapshot (the hand holding a sprig); *A. resinimarginea* two, both on cloth.
  Kept (a hand-held sprig of the right species beats no photo); dropping
  them is Leo's call.

## Training-photo classes (audit of 15,768 picks)

- No re-embedding: `near` reads the existing embeddings, takes each class's
  20 photos nearest its mean (same mean as `build_refphotos select`).
- A pick is flagged if the probe's logit ≥ 3 (~2 % of picks) or it is
  labelled bad; it is swapped for the nearest-to-mean photo among the
  class's 10 nearest with logit ≤ 0 and ≥ 4 below the flagged one (not a
  known bad shape; among the original top-5, build_refphotos' licence/size
  order). 364 flagged → 261 swapped, 103 had no clean near-mean
  alternative. Reasons: essentially all hand-held / fingers (labelled: 107
  hand, 5 ex-situ, 2 label card; 147 probe-only, by eye also hands). People,
  herbarium sheets, blur and screenshots hardly occur among near-mean picks
  — in the several hundred picks looked at, no person- or sheet-dominated
  photo, a handful of label cards / rulers / notebooks.

## The quality score — what worked and what did not

1. **Zero-shot prompts failed.** Single prompts vs "good" prompts fired on
   any diffuse photo of small flowers; prompt PAIRS ("a hand holding a
   flower" − "a flower", mean difference = a concept direction) on raw
   embeddings: AUC 0.50–0.63 against the labels; on residuals (photo − its
   class or genus mean) 0.59–0.69. Top-36 sheets: ~35–60 % hands at the
   very top, noise below. Why: BioCLIP 2.5's text side was trained on
   taxonomic captions, and — the deeper reason — its image side is trained
   to map every photo of a taxon to the same name, i.e. to be INVARIANT to
   nuisances like a hand, a ruler or a background. The concept we want to
   detect is exactly what the training objective suppresses. A generic CLIP
   would find hands trivially; with "no extra model" we have to dig the
   residual signal out.
2. **Few-shot linear probe (kept).** Logistic regression (C = 0.3) on the
   BioCLIP 2.5 image embedding, fitted to 452 photos labelled by eye from
   contact sheets (`notes/refphotos_quality_labels.json`: 256 ok, 176 hand,
   17 lab, 3 label) in three rounds: random snapshot candidates (≈ 30 % bad),
   the first swap sheet, then the probe's own top-ranked training picks
   (hard negatives — this fixed a bias towards blue/purple flowers). 5-fold
   CV AUC 0.73–0.76 (the later label sets are harder). By eye on the
   unlabelled training picks: ~60 % hands at ranks 60–108, ~55 % at
   250–298 → precision is fine where we flag; recall is not (below).
   Probabilities are not calibrated for the picks (labels ~40 % bad, picks
   a few %), hence thresholds on the logit, set by eye.

## Visual checks (looked at by me; sheets in `refine/sheets/`)

- (a) 48 random final picks of the 557 (`a_snap_new.jpg`): 23 clearly
  good, 14 acceptable (distant/small/so-so), 4 weak, **7 poor** (hand ×4,
  on cloth, herbarium-style scan, … — 3 of them have no clean alternative).
  The 24 changed ones in that sample, before → after
  (`a_snap_before_after.jpg`): 11 better, 11 neutral, 2 worse.
- (b) 48 random swapped training picks (`b_swaps_1.jpg`, `b_swaps_2.jpg`):
  **36 clear improvements** (hand/ex-situ → plant in place), 9 neutral, 3
  worse (the replacement had a hand or showed less).
  (First, zero-shot version: 18 better, 27 neutral, 3 worse.)
- (c) 24 random unchanged picks (`c_unchanged.jpg`): 18 clean, 6 with a
  hand in frame (1 minor); an earlier sample: 22/24 → 40/48 overall.
  **The audit is far from exhaustive**: perhaps ~10–15 % of the unchanged
  picks still show a hand (wide interval from 48 photos), mostly hands
  holding a twig next to an otherwise good view.

## Levers not pulled

- Lower `LOGIT_FLAG_TRAIN` (≥ 0: 1,345 picks) — needs a look at the
  0–3 band first; a false-positive swap costs little (the replacement is
  still near the mean), a bad replacement costs more.
- More labels (another round on the 0–3 band) would lift the probe.
- A generic CLIP for hands would beat all of this but is an extra model.
