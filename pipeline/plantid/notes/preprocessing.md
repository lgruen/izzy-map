# Image preprocessing audit + training-view pilot (2026-11-05)

Code: `pipeline/plantid/preproc_audit.py` (subcommands in its docstring),
cloud: `cloud/preproc_run.sh` (laptop) + `cloud/preproc_vm.sh` (VM startup).
Outputs: `pipeline/cache/plantid/preproc/` (gitignored). All numbers
MEASURED unless marked "estimate".

## 1. The 0.77 "same photo" pairs: not a pipeline bug — the small is 160–180 px

`preproc_audit.py repro` rebuilt the calibration's pairs (expand_inat
`calibrate-emb`, seed 3, 60 photos) and fetched iNat's small / medium /
large / original of each. ONE pipeline for every file (open_clip eval
transform, **fp32** on MPS; fp16 re-run alongside):

| pair (vs the 500 px medium) | min | p10 | p50 | p90 |
|---|---|---|---|---|
| small (240 px long side) | 0.727 | 0.898 | 0.959 | 0.994 |
| same, fp16 | 0.726 | 0.899 | 0.959 | 0.994 |
| medium resized by us to the small's size (Lanczos) | 0.804 | 0.928 | 0.981 | 0.998 |
| large (1024 px) | 0.922 | 0.990 | 0.997 | 0.999 |
| fp16 vs fp32, same medium | 1.000 | 1.000 | 1.000 | 1.000 |

- Same files, sizes and URLs as the calibration (`/photos/<id>/{small,medium,
  large,original}.<ext>` in the open-data bucket); none is iNat's "square".
- **EXIF orientation: tag = 1 (or absent) on all 240 files**, and on all
  38,495 local iNat photos scanned (`scan`: `photos/`, `australia/photos/`,
  `extra/inat/`) — iNat bakes the rotation into every size. Not the cause.
- **ICC**: identical profile in every size of a photo (29 none, 19 Display
  P3, 12 sRGB variants); every size read the same way (raw values). Not the
  cause. fp16 vs fp32: not the cause (identical to 4 decimals).
- **Root cause: resolution.** iNat's "small" is 240 px on the LONG side, so
  a 3:2 photo is 240 × 160: the eval transform UPSCALES its short side
  160 → 224 (1.4×), while the medium is downscaled 333 → 224. The model
  sees a soft image without the fine texture (bracts, hairs, venation)
  the medium has. Median cos by the small's short side: 160 px 0.935
  (n 12), 180 px 0.959 (38), ≥ 200 px 0.988 (9); the 2.3:1 panorama (240 ×
  103 → 2.2× upscale) 0.864. Our own clean downscale of the medium to the
  small's size loses most of the same (median 0.981, correlation with the
  small's cosine 0.83) — the rest is iNat's resampling/JPEG of the small.
  Lowest pair (0.727): six eucalypt capsules on bark, 240 × 160 — the
  capsule texture is the whole signal.
- The model is texture-sensitive even WITHOUT upscaling: large vs medium
  (both downscaled to 224) still goes to 0.92 on that photo; a JPEG q50
  re-encode or a 90 % crop of the medium to 0.85 (calibration). So
  "cos ≥ 0.95 = duplicate" is not a property of this model; the de-dup
  guard's two-stage design (hash first, cos only to confirm) is the right
  one, and no preprocessing bug distorts it. The training/eval embeddings
  all come from the 500 px medium (never the small), so this does not
  touch the classifier.

## 2. Consistency audit: every place an embedding is made

| where | decode | EXIF | colour | geometry | model |
|---|---|---|---|---|---|
| `embed.py` (Tasmanian sets, cloud/MPS) | Pillow, `convert("RGB")` | ignored | raw values, ICC ignored | open_clip: short side → 224 Pillow bicubic (antialiased), centre crop | torch fp16 |
| `train_australia.py vm-embed` (598k AU training + AU-val/test, L4) | same | ignored | raw | same | torch fp16, `model.visual.half()` |
| `dedup.calibrate_emb`, `refine_refphotos` (local MPS) | same | ignored | raw | same | torch fp16 MPS |
| `build_ship.py embed` (A-test / C eval, Mac ANE) | Pillow | ignored | raw | numpy port of the same (asserted ≤ 1e-4 vs open_clip) | Core ML w8 |
| **app** (`PlantIDPhoto` + IzzyKit `PlantIDPreprocess`) | ImageIO, drawn in the image's OWN colour space | applied (`upright`, exact re-index) | raw values (P3 stays P3 numbers) | her square crop (default: largest centred square), then a byte-exact port of Pillow's bicubic to 224 | Core ML w8, `.all` (ANE) |

Findings:
- EXIF: the app uprights, the pipeline ignores — consistent, because iNat
  files never carry a rotation tag (0 of 38,495). RGB order everywhere;
  CLIP mean/std identical (constants checked in Swift and Python).
- Colour: ~1/3 of iNat photos carry a Display P3 (or P3-gamut) profile,
  ~1 % Adobe RGB, ~45 % none; Pillow reads raw numbers, and the app does
  the same, so an iPhone P3 photo reaches the model exactly as an iPhone
  P3 upload to iNat did in training. Converting the query to sRGB instead
  (what a colour-managed app would do) changes nothing measurable (below).
- Geometry: the app crops the square in whole pixels FIRST and resizes it,
  torchvision resizes first (long side truncated to int) and crops after —
  a sub-pixel shift of the sampling grid.

Measured on 500 random AU-test photos (`parity`; Core ML w8 on the M4 ANE;
v2 head `v2fix-e12-tasw3`, 22,122 classes, no prior; per species / natural):

| variant | cos vs training embedding (min / p1 / p50) | top-1 sp / nat | top-5 sp / nat | top-1 flips vs training emb. |
|---|---|---|---|---|
| training recipe (cloud torch fp16) | 1 | 79.4 / 85.8 | 93.0 / 96.0 | – |
| same pixels, Core ML w8 | 0.9986 / 0.9992 / 0.9998 | 79.2 / 85.7 | 93.2 / 96.1 | 5 |
| app geometry (square first), w8 | 0.968 / 0.979 / 0.998 | 79.8 / 86.4 | 93.9 / 96.1 | 24 |
| app geometry from the ORIGINAL (≤ 2048 px, phone-like resolution), w8 | 0.912 / 0.956 / 0.996 | 78.4 / 86.3 | 93.0 / 96.1 | 26 |
| app geometry + ICC → sRGB (170 non-sRGB photos converted), w8 | 0.967 / 0.975 / 0.996 | 79.4 / 86.3 | 93.2 / 96.0 | 29 |

(on the 170 converted photos alone: raw 76.7 / 85.1, sRGB 77.3 / 87.5 —
noise). **No mismatch costs measurable accuracy**: every difference is
within ±1 pt (the 95 % interval on 500 photos is ±3–4 pt, and the flips go
both ways). The w8 encoder is the closest to the training recipe; tiny
geometric changes already flip ~5 % of top-1 answers (near-ties between
congeners), which is the noise floor of any single-crop identification.
Not checked: the camera path's Core Graphics downscale for > 4096 px photos
(only matters for 48 MP captures; it precedes a ≥ 18× Pillow-port downscale)
and HEIC 10-bit decode (ImageIO hands 8-bit values of the image's own space).

## 3. Crop strategy (v2 head trained on centre crops)

`views` (cloud L4, torch fp16, 500 px medium; the VM's centre crop vs the eval
embedding: cos ≥ 0.9976). 1,000 A-test + 1,000 AU-test photos, stratified 250
per training-count bucket (0, 1–9, 10–49, 50+) — so absolute numbers sit
below the full-set ones; compare rows. Embedding average = mean of unit
embeddings, renormalised. Paired = photos that became right / wrong vs centre.

| query views | encoder runs | A top-1 sp / nat | A top-5 sp | A paired +/− | AU top-1 sp / nat | AU top-5 sp | AU paired +/− |
|---|---|---|---|---|---|---|---|
| centre crop (current) | 1 | 80.0 / 85.4 | 94.2 | – | 58.3 / 69.0 | 73.9 | – |
| whole photo padded to square | 1 | 72.7 / 75.4 | 89.5 | +29 / −104 | 49.5 / 58.3 | 70.2 | +30 / −111 |
| squash to square | 1 | 79.7 / 85.5 | 94.1 | +37 / −36 | 55.7 / 67.3 | 73.8 | +26 / −48 |
| avg(centre, padded) | 2 | 79.7 / 84.4 | 94.0 | +22 / −29 | 57.7 / 68.8 | 74.1 | +26 / −31 |
| 5-crop avg (256 → 4 corners + centre 224) | 5 | 81.0 / 86.1 | 94.4 | +39 / −29 | 59.2 / 70.9 | 74.6 | +37 / −27 |
| **avg(centre, 5-crop)** | 6 | **81.4 / 86.5** | **94.8** | **+26 / −14** | **59.4 / 70.9** | **75.2** | **+21 / −10** |
| avg(centre, padded, squash) | 3 | 80.6 / 85.6 | 94.2 | +23 / −18 | 57.4 / 68.8 | 74.2 | +21 / −27 |

- Padding the whole photo is clearly worse (−7 to −9 pt): the head was
  trained on centre crops, the plant shrinks to ~⅔ of the frame and grey
  bars enter. Squash is neutral to −2.5.
- Multi-crop helps a little and consistently: centre + 5-crop gains 47
  photos and loses 24 over both sets (sign test p ≈ 0.01) ≈ **+1 pt top-1,
  +0.6–1.3 top-5**, at **6 encoder runs** per identification (0.08 s each on
  the M4 ANE as w8 → ~0.5 s on the Mac; on the 16e's ANE an estimate of
  ~0.5–1 s more per photo). Eucalypt / 1–9 subsets are ~40–200 photos each:
  too few to read (shown in `preproc/views.json`).

## Cloud bound (written BEFORE launch)

One SPOT g2-standard-8 + 1× L4, us-central1-a, project leo-superresolution
(no other VM running at launch: `gcloud compute instances list` empty).
Work: crop experiment 2,000 eval photos (1,000 A-test + 1,000 AU-test,
500 px medium) × 8 views = 16k encodes; pilot 500 classes: 15,099 training
+ 2,157 test photos at 1024 px "large" → OWLv2 (base, 960 px) on 17,256
photos, ~7 views per training photo (centre, 3 zooms, ≤ 3 organ crops),
~4 per test photo → ~90–110k encodes. Shards of 500 photos to
`gs://leo-superresolution-izzy-plantid/preproc/out/`, resumable per shard.

- Estimate: encodes at ~110/s (L4 fp16, measured 101–109 photos/s end to
  end for the same model) ≈ 17 min; OWLv2 at an assumed 20–40 photos/s
  (not measured on an L4; ~0.3 photos/s incl. model load on the M4 smoke
  test) ≈ 7–15 min; boot + env + HF downloads (4.3 GB) ≈ 10 min →
  **~0.6–0.8 h**.
- Cost: $0.511/h × 0.8 h ≈ $0.41 (× 1.5 preemptions ≈ $0.6); hard cap
  `--max-run-duration=1.5h` per boot (≤ $0.80), at most 3 boots → ≤ $2.4;
  disk 100 GB pd-balanced ≈ $0.01; GCS + egress of ~0.25 GB of fp16
  embeddings ≈ $0.03. **Cap $4** (coordinator). VM + disk deleted after.

**Actual run:** VM up 00:10 → job end 01:06 UTC (one boot, no preemption,
zone us-east1-c after a us-central1-a stockout), deleted with its disk at
01:08 → ~0.96 h × $0.511 ≈ **$0.50**. Measured: crop experiment 11 photos/s
= 88 encodes/s (CPU-bound preprocessing of 8 views); pilot 5.8–6 photos/s
with OWLv2 + ~5.3 views/photo (≈ 32 encodes/s; detector ≈ 9–10 photos/s,
derived from the shard timings). 0 photos missing upstream. GCS prefix
deleted afterwards; local copy `preproc/work/` (≈ 0.45 GB).

## 4. Training-view pilot: does training on zooms / organ crops help tight queries?

Question (Leo): her queries are tight squares on a plant or organ, while
training embeddings are centre crops of often-wide iNat photos — would
extra training views close that gap?

Setup (`plan`, `work`, `pilot`): **500 classes** (100 eucalypts, 158 with
1–9 / 167 with 10–49 / 175 with 50+ training photos, each with ≥ 1 test
photo), their training photos (≤ 60 per class, 15,099) and A-test + AU-test
photos (≤ 15 per class and set; 2,105 photos, observer-disjoint as in every
eval) at iNat "large" (1024 px). Detector: OWLv2 base (ensemble), prompts
flower / fruit / flower bud / leaf / tree bark; a crop = box with score ≥
0.25, long side ≥ 12 % of the photo's short side, ≤ 60 % of its area, NMS
0.5, ≤ 3 per photo, squared around the box (× 1.15), shifted inside or padded
with CLIP-mean grey, → 224. Training views per arm:
(a) centre crop; (b) + 3 random square zooms 1.5–2.5×; (c) + the organ
crops; (d) organ crops ONLY (centre crop when none). Head per arm = v2
recipe on the 500 classes (text init s0·centred text, logit-adjusted CE τ 1,
AdamW 1e-3, decay to the text init 0.01, warmup + cosine) with the SAME
step budget (2,000 × 512) for every arm; checkpoint by per-species val
top-1 (AU-val ∪ A-val centre crops of the pilot classes, so mildly tilted
towards centre queries — rerun with the final step and with 4,000 steps,
seed 1: same picture). Queries: **centre** = the full photo's centre crop
(her default square); **organ** = the best detector crop of the TEST photo
(65 % of test photos have one, else the centred 2× zoom); mix = 50/50.

Top-1 / top-5 per species (val-selected checkpoint; 500-way, so far above
the 22,122-way numbers):

| arm | train views | centre | centre euc | centre 1–9 | organ | organ euc | organ 1–9 | mix 50/50 | mix euc | mix 1–9 | paired vs (a), centre / organ |
|---|---|---|---|---|---|---|---|---|---|---|---|
| (a) centre (current) | 15,099 | **89.7**/97.8 | 66.8/91.6 | **87.0**/97.6 | 79.1/90.1 | 51.9/79.8 | 75.6/90.0 | **84.4**/94.0 | 59.3 | **81.3** | – |
| (b) + 3 zooms | 60,396 | 88.8/97.7 | 64.5/91.0 | 84.9/97.3 | 79.1/90.3 | 53.0/80.3 | 75.0/90.1 | 83.9/94.0 | 58.7 | 79.9 | +44 −54 / +68 −64 |
| (c) + organ crops | 34,806 | 88.9/97.6 | 66.3/90.5 | 85.4/97.0 | **79.9/91.5** | **54.4**/80.6 | 75.7/90.7 | 84.4/**94.5** | **60.3** | 80.6 | +35 −58 / +74 −62 |
| (d) organs only | 24,993 | 89.0/97.4 | 66.9/89.7 | 86.0/97.3 | 78.5/91.3 | 53.7/81.0 | **71.3**/90.6 | 83.7/94.4 | 60.3 | 78.6 | +47 −63 / +79 −75 |

(n: 2,105 photos / 467 eucalypt / 266 in 1–9 classes; natural-mix top-1
centre 96.2 / organ 85.3 for (a), all arms within ±1. Final-step and
4,000-step reruns: every arm within ±1.5 of (a) on organ queries, (d) again
−3 to −6 on the 1–9 bucket.) The production v2 head (22,122 classes) on the
same queries: centre 67.9 / 85.0, organ **53.0** / 71.8, centred 2× zoom
64.0 / 81.9 per species — the tight-crop penalty is larger at full scale.

- **No arm closes the gap.** Organ-query top-1 moves by ≤ 0.8 pt
  (paired: gains ≈ losses, e.g. (c) +74 / −62 of 2,105 photos, p ≈ 0.35);
  eucalypt organ queries +2.5 for (c)/(d) is within noise for 467 photos of
  100 classes; centre queries lose 0.7–0.9 for every extra-view arm (paired
  −10 to −23 net); (d) costs the 1–9 bucket 4 pt on organ queries (fewer,
  noisier training views for the rarest classes).
- **The gap is information, not a view mismatch**, by organ type (arm a;
  the SAME photos' centre crop alongside):

| detector crop (test photo) | photos | organ-crop top-1 / top-5 | centre crop of the same photos |
|---|---|---|---|
| flower | 253 | **98.0** / 100 | 97.2 / 100 |
| flower bud | 294 | 79.3 / 88.8 | 97.6 / 99.7 |
| leaf | 507 | 67.5 / 81.7 | 90.9 / 98.4 |
| tree bark | 306 | 66.0 / 78.1 | 85.0 / 95.1 |
| fruit | 15 | 53 / 67 | 93 / 100 |
| none (centred 2× zoom) | 730 | 90.4 / 96.7 | 90.6 / 98.1 |

  A flower fills the square and identifies as well as the whole photo; a
  single leaf, a bud or a patch of bark loses 15–25 pt, and training on
  such crops does not buy it back (arm c: bark 68.0, leaf 68.8, bud 79.9).
  (Natural-mix percentages per photo; all organ crops of the test photos
  give the same ranking: flower 97, bud 79–81, leaf 67–70, bark 68–70,
  fruit 57–67.)
- **Fallback (no usable organ crop) for arm (d): 5,286 of 15,099 training
  photos (35 %)** — grasses 69.5 %, sedges/rushes/restios 56 %, Proteaceae
  49 %, ferns 48 %, other Myrtaceae 45 %, other 35 %, Fabaceae 33 %,
  Asteraceae 32 %, eucalypts 30 % (their crops are mostly bark/leaf),
  orchids 15 %. Crops per training photo 1.31: leaf 8,080, flower bud
  4,985, bark 3,790, flower 2,553, fruit 299.
- **Visual check** (`sheet`, 48 training crops of the first shard's 4
  classes — Abutilon micropetalum, Acacia acradenia / browniana /
  brachyclada; `preproc/sheet-*.jpg`): 37 show the labelled plant, **7 a
  different plant** (eucalypt trunks behind a shrub, a dead eucalypt leaf
  in the litter — 5 of the 9 "bark" crops), 3 mixed scenes, 1 a hand only.
  ≈ 15 % wrong-plant crops; "tree bark" is the dangerous prompt in
  shrub/herb photos. (One small sample from 4 classes: indicative only.)

## 5. Recommendations

1. **No preprocessing bug to fix.** The 0.77 pairs are iNat's 240 px
   "small" being upscaled; never embed "small" (nothing does). Keep the
   app's raw-colour policy (it matches Pillow on the training side; adding
   colour management in the app alone would create the mismatch) and its
   EXIF uprighting (iNat files are already upright). The crop-then-resize
   sub-pixel difference is harmless (+0.4 / −0.0 pt, noise); aligning it to
   torchvision's resize-then-crop exactly is possible but not worth code.
   If the training set is ever re-embedded, a consistent sRGB conversion on
   BOTH sides is the principled choice — measured gain today: none.
2. **Multi-crop at query time: optional, small.** centre + 5-crop (6 encoder
   runs) ≈ +1 pt top-1 and +0.6–1.3 top-5 on both test sets (p ≈ 0.01
   pooled); estimate +0.5–1 s per identification on the 16e's ANE. Never
   pad the whole photo (−7 to −9). Not tested: 5-crop INSIDE her framed
   square (the experiment cropped the full photo).
3. **Do not re-embed the training set with extra views.** Neither zooms nor
   detector organ crops (with or without the centre crop) improve tight-crop
   or centre queries in the pilot; organ-only hurts rare classes and adds
   ~15 % wrong-plant crops. Cost had it helped (measured L4 rates, 598k +
   260k extras = 858k photos): 3 zooms = 2.6 M encodes / 88 per s ≈ 8 h ≈
   $4 (× 1.5 SPOT ≈ $6); organ crops = 858k / ~6 photos/s ≈ 40 h ≈ $20–30.
   What the evidence does support is **guidance in the framing step**:
   frame a flower or a whole branch/plant, not a single leaf or bark — a
   square on a flower is as good as the whole photo, on a leaf or bark it
   is ~20 pt worse (and the v2 head's tight-crop penalty is ~15 pt at full
   scale). The current default (largest centred square) is the strongest
   single query in every arm.

Files: `preproc/repro.json`, `scan.json`, `parity-w8.json`, `views.json`,
`pilot-{sel,last,last4k}.json`, `sheet-*.jpg`, `in/` (plans), `work/`
(shards + 60 sample crops).
