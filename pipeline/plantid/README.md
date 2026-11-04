# Plant-ID evaluation (photo → species, with a location prior)

Question: how well can an open model (BioCLIP / BioCLIP 2) running on the
phone name Tasmanian plants from a photo, and how much do training photos and
a location prior help? Nothing here ships in the app; it produces numbers to
decide on.

## Run order

```bash
pipeline/plantid/fetch_meta.sh                       # ~35 GB, ~35 min
uv run --with duckdb --with pyarrow python3 pipeline/plantid/pick_sets.py \
    --un-plants ios/IzzyMap/Resources/Data/plants.json
uv run --with duckdb python3 pipeline/plantid/fetch_photos.py --workers 48
E="uv run --with torch --with torchvision --with open_clip_torch --with pyarrow --with pillow --with numpy"
$E python3 pipeline/plantid/embed.py --model bioclip
$E python3 pipeline/plantid/embed.py --model bioclip2
uv run --with torch --with numpy --with scipy --with pyarrow \
    python3 pipeline/plantid/evaluate.py      # → cache/plantid/report/report.md
```

Every step is resumable (DuckDB stages are cached in `sets/work.duckdb`,
photos and embedding shards are skipped when present). The UN list is the
bundled `ios/IzzyMap/Resources/Data/plants.json` (`--un-plants`).

Measured on the M4 laptop (2026-11-01): S3 download ~18 MB/s, photos
~127/s with 48 workers (~150 KB each); BioCLIP ~60–74 img/s (fp16, raw),
~37/s end to end; BioCLIP 2 ~16 img/s (fp16, raw).

## Design

- **Observer split first.** Observers are hashed into val (~10 %), test
  (~20 %) and pool. Train photos, the location prior and the label set come
  only from pool observers; val/test photos only from val/test observers. A
  test photographer's garden, camera and usual walks are never in what the
  method learned from — the app's users won't be in the training data either.
- **Time cut for eval photos.** BioCLIP 2's training set (TreeOfLife-200M,
  GBIF ~May 2024) contains iNat photos, so val/test photos are Tasmanian
  observations made on/after `--cutoff` (default 2024-09-01). Pool data of
  any date is fine. The app's ALA prior (`nearby.bin`) contains iNat records
  of all observers and dates — i.e. the test observations — so the eval
  builds its own prior.
- **Shared photos.** A photo attached to more than one observation is never
  an eval photo (identical pixels could otherwise sit in train and test).
  pick_sets.py asserts the splits share no photo and no observer.
- **Labels** = species (infraspecific taxa rolled up) with a Tasmanian pool
  record ∪ Understorey Network species (active iNat names only). Eval photos
  of other species, and research-grade photos named only to genus or as a
  hybrid, stay in and count as misses ("not in label set").
- **Train photos from anywhere**, Tasmanian first, then Australian, then the
  rest; ≤ `--train-cap` per species, observer diversity first.
- **Two accuracy views.** "Photos" re-weights eval photos to the natural mix
  of species people photograph; "species" averages over species (the long
  tail counts). Plus tiers by training photos available, plant groups,
  genus-level accuracy, and confident share / right-when-confident over ALL
  photos.
- **Calibration before priors.** Each classifier's temperature is fitted on
  val (NLL), then the prior weight λ is tuned on a grid including 0, so a
  "+ prior" gain is comparable across classifiers (λ ≈ 1 = calibrated Bayes).
  The local prior is a kernel density shrunk towards statewide frequency,
  (K + α·f) / (ΣK + α), so one nearby record can't dominate.
- **Geometry fixes.** Photo and text embeddings are centred per modality
  (CLIP's modality gap; prototype hubness), and a CSLS-style hub correction
  is chosen on val. Without it, on the smoke-test sample 95 % of predictions
  went to species that had training photos and photo-less species were never
  named; with it photo-less species reached ~40 % while species with photos
  held ~70 %. The linear head keeps photo-less species frozen at their text
  vector (otherwise they only receive "not this" gradients).
- Every choice is made on val by the mean of photo-weighted and per-species
  top-1; the report's "best" row is chosen by val, numbers are test.

## Cloud run

`cloud/run_cloud.sh up` → one SPOT g2-standard-8 + L4 in us-east4 (next to
the S3 bucket), external IP (no Cloud NAT in the project; all data public),
STOP on preemption (`resume` continues), `--max-run-duration` hard cap,
self power-off when done. Only parquet + embeddings go to GCS
(`fetch` copies them here); photos stay on the VM. Then `down`, and run
evaluate.py locally.

## Phone test (can Safari run it?)

Retired: the page was deleted with the web app (last in commit 04ea5d9) and
its hosting (Pages site, R2 `plantid-test/v1/`) was torn down on
2026-11-04. The native Core ML test is `native/plantid-test/`.

`probe/plantid/` (was deployed with the app at `/probe/plantid/`) downloaded the
image encoder into OPFS, ran it with onnxruntime-web (WebGPU) and compared
its embeddings with the laptop's for three bundled CC0 test photos; the
person running it copied a results text. A memory kill by iOS reloaded the
page, which then reported the step it died in.

```bash
uv run --with torch --with torchvision --with open_clip_torch --with onnx \
    --with onnxruntime --with pillow --with numpy --with pyarrow \
    python3 -I pipeline/plantid/export_onnx.py --model bioclip25   # ~20 s
#   (and --model bioclip: the 0.2 GB fallback the page offers)
uv run --with torch --with torchvision --with pillow --with numpy \
    python3 -I pipeline/plantid/check_pilresize.py                # JS resize == Pillow
```
(`upload_test.sh`, which put this on R2 under `plantid-test/v1/`, was
deleted with the hosting — `git show 04ea5d9:pipeline/plantid/upload_test.sh`.)

- Weights: float16, 21 shards ≤ 64 MiB (resumable download, no single 1.3 GB
  buffer during download). Input float32 → cast inside the graph.
- Preprocessing is bit-exact with open_clip (`probe/plantid/pilresize.js`:
  Pillow's bicubic + torchvision's centre crop), and JPEG colour profiles are
  stripped before decoding: Pillow ignores them, Safari would convert Display
  P3 (every iPhone photo) to sRGB — that alone cost 0.02 cosine on a P3 test
  photo and flipped a close call.
- Local run (`git worktree add /tmp/izzy-web 04ea5d9` for `probe/`): serve a folder holding `probe/` and `plantid-test/v1/{bioclip25,
  bioclip,ort}` on localhost and open `/probe/plantid/?data=/plantid-test/v1/
  &auto=1`. macOS Safari 27.2 on the M4 (2026-11-02): BioCLIP 2.5 loads in
  1.7 s, 0.45 s per photo, cosine to PyTorch ≥ 0.9992 end to end.

## Shipping artefacts

`build_ship.py` (one uv env, see its docstring) → `cache/plantid/ship/`
(gitignored). Subcommands: `data` (~3.5 min: head, banks, prior, labels,
credits, pipeline.json, plus test scores computed FROM THE WRITTEN FILES by
its reference scorer `Ship`, which is the spec for the Swift side),
`encoders` (w8 13 s, p4 57 s, p6 290 s), `fp32ref` (500 photos, 3.4 min),
`embed --variant v` (5,684 test photos, 8–10 min each on the M4 ANE),
`benchall`, `report`. Results: `ship/results.json`.

- **Head** `head.bin` 5.5 MB: retrained with the eval's μ 1e-5, 40 epochs,
  and the same seed (MPS gave identical numbers on two runs). fp16 weight 2,675 × 1024
  plus the fp32 image-mean `centre`. No bias: the evaluated head has none. Its
  rows for species without photos are their centred text vectors, so the
  separate text prototypes aren't needed.
- **Prior** `prior.bin` 0.32 MB: 95,444 pool-observer records (no val/test
  observer) as counts on the eval's own 2.5 km (σ/2) cells: 47,796
  (cell, species) pairs, a dense 153 × 197 row-pointer grid. The app applies
  the σ = 5 km Gaussian (cut at 3σ) at the photo's point and then the
  shrinkage (K + 32 f)/(ΣK + 32). This matches evaluate.GeoPrior to
  5e-7 in log p. Pre-smoothing onto 0.05° cells would mean 664k non-zeros
  (~2 MB) and cell-centre error, so that version was not built.
- **Every `*.bin`** is an "IZPL" blob: magic, a JSON header (arrays,
  offsets, parameters), and 64-byte-aligned little-endian arrays. Each
  bank's header carries its own `scoring` (k, τ, temperatures, ω, λ).
  `pipeline.json` holds the steps, preprocessing, file sizes and sha256.
- **labels.json** (0.53 MB): genus/family/order/class per label. 1,617
  labels have a UN profile (`un.key` = plants.json `species`, `un.ids`);
  9 of these were matched by spelling variant (e.g. Podocarpus lawrencei →
  lawrencii). The other UN names that differ from iNat's (genus moves such
  as Deyeuxia, Paraprasophyllum, Corunastylis) stay unlinked.
- **Credits**: `credits.json` (13,068 observers with login, name, photo
  count and licences; 1.2 MB) and `credits-photos.tsv.gz` (82,649 photo id,
  login, licence). Licences: 69,615 BY-NC, 9,882 BY, 3,152 CC0. The
  observers table (`meta/observers.csv.gz`, 2026-11-01 snapshot) is not
  pulled by fetch_meta.sh.

Test set, 5,684 photos, prior on (λ 0.5). Encoder = Core ML on the M4,
compute units ALL. "cos" = cosine to PyTorch fp32 on 500 test photos
(mean / min):

| encoder | size | bank | bank size | top-1 | top-5 | cos | notes |
|---|---|---|---|---|---|---|---|
| (eval, cloud fp16 emb.) | – | fp16 | 169 MB | 94.68 | 99.04 | 1.0000 / 0.9988 | reproduces 94.7 / 99.0 and the ladder (96.3 % named, 95.4 % right) |
| fp16 | 1.26 GB | fp16 | 169 MB | 94.67 | 99.04 | 0.9996 / 0.9968 | |
| fp16 | 1.26 GB | int8 | 85 MB | 94.67 | 99.04 | | int8 per-row bank: no loss |
| fp16 | 1.26 GB | proto1 | 5.3 MB | 94.25 | 99.07 | | k-means, 1 per species (proto2 10 MB 94.24, proto4 20 MB 94.24, cached emb.) |
| fp16 | 1.26 GB | none | 0 | 94.22 | 99.22 | | head + prior only |
| w8 | 0.63 GB | int8 | 85 MB | 94.69 | 99.05 | 0.9998 / 0.9991 | int8 linear per-channel; 0.080 s/photo (fp16 0.101) |
| p6 | 0.48 GB | int8 | 85 MB | 94.16* | 99.62* | 0.9984 / 0.9953 | *512-photo subset only; same photos: fp16 94.75, w8 94.17 (noise ±1 pt) |
| p4 | 0.32 GB | int8 | 85 MB | 94.04 | 98.83 | 0.965 / 0.850 | 4-bit k-means LUT per 16 channels; ladder: 5.2 % wrong answers vs 4.9 % |
| p4 | 0.32 GB | none | 0 | 93.64 | 99.04 | | smallest total (~0.33 GB) |

Statistical noise: the 95 % interval on one top-1 is about ±0.6 pt. Variants
scored on the same photos differ by less (paired comparison). Gaps of
≤ 0.1 pt (fp16 vs int8 bank, fp16 vs w8 encoder) are noise. The
≈ 0.45 pt gap for bank vs no bank and the ≈ 0.6 pt gap for p4 are small
but consistent across banks.

Mac load and memory, measured in a fresh process (`/usr/bin/time -l`, two
runs each). Load: fp16 11–18 s, w8 8–17 s, p4 18–23 s, p6 28–40 s (both
runs include Core ML's on-device compile; noisy). Peak memory footprint is
~370 MB for every variant. Max RSS is fp16 3.0 GB, w8 1.7 GB, p6 1.4 GB,
p4 1.1 GB. RSS counts the mapped weight file, and footprint does not. Which
of the two iOS jetsam effectively charges on the 16e is exactly what the
pending TestFlight test measures, so the Mac numbers don't settle it.

**Shipped (decided 2026-11-04, milestone 6): the 8-bit w8 encoder.** It
ties fp16 (94.69 vs 94.67 % top-1, noise) at half the size, so the
`plantid` pack (`pipeline/build_packs.py plantid`, 0.73 GB on the device,
0.68 GB `.aar`) holds, in a `plantid/` folder:

- `PlantEncoder-w8.mlmodelc` — the w8 `.mlpackage` compiled by
  `xcrun coremlcompiler compile --platform iOS --deployment-target 26.0`
  (~1 s; the program is re-encoded, the 0.63 GB weight file copied
  verbatim — build_packs.py checks). Shipping it compiled (what Xcode puts
  in app bundles) means no on-device compile and no second 0.6 GB copy;
- `head.bin`, `bank-int8.bin`, `prior.bin`, `labels.json`,
  `pipeline.json`, `credits.json` (+ `credits-photos.tsv.gz`), each
  SHA-256-checked against `pipeline.json` when staged.

The int8 bank ties the fp16 bank at half the size and RAM (85 MB), so it is
the default (`bank_default`). The app's scorer (IzzyKit `PlantIDScorer`)
reproduces `Ship` on these files to 4e-6 in log p on 50 test photos'
w8 embeddings, and the app's preprocessing reproduces Pillow's resize
byte for byte (`build_ship.py fixture` writes the numbers-only fixtures to
ios/IzzyKit/Tests/Fixtures/plantid-*). On the 27.2 simulator the w8
model gives Python's top-1 on the three CC0 sample photos (IzzyMapTests
`realModelMatchesPython`, local only).

Fallback ranking if the 16e can't hold w8 (fp16 if it holds more):

1. ~~**w8** encoder (0.63 GB): no measurable loss, and slightly faster.~~ Shipped.
2. **p6** (0.48 GB): cosine 0.998. Only indicative so far, from a
   512-photo subset; run `embed --variant p6` (~10 min) before relying on it.
3. **p4** (0.32 GB): −0.6 pt top-1 and a min cosine of 0.85 on single
   photos.

If the bank's RAM matters, `bank-proto1.bin` (5 MB) or no bank costs
≈ 0.45 pt with any encoder.

Not done:

- A "final" build that also trains on the val/test observers' photos and
  records (more data, but nothing left to verify it on).
- Load and memory on a real iPhone.

## Open-vocabulary evaluation

Question (2026-11-04): a garden Protea came back as *Telopea truncata* 95 % —
the shipped scorer only knows the 2,675 labels. Would a hybrid "Tasmanian
specialist + rest-of-world zero-shot" name such plants without hurting wild
Tasmanian accuracy? Evaluation only; nothing ships. Code:
`eval_open_vocab.py` (`labels → text → fetch → testset → embed → score →
points`, env in its docstring); outputs in `cache/plantid/openvocab/`
(`results.json` incl. every sweep row, `points.json`, `B-credits.tsv`).

- **Global list**: BioCLIP 2.5's own training taxonomy (TreeOfLife-200M
  `embeddings/txt_emb_bioclip-2.5-vith14.json`, 84 MB: 794,878 taxa,
  348,987 Plantae species), kept where the binomial has ≥ 5 research-grade
  iNat observations worldwide (open-data snapshot in `sets/work.duckdb`):
  92,106, of which 2,283 are local labels → **89,823 global-only species**.
  Text vectors from BioCLIP 2.5's text tower with the eval's prompt
  ("a photo of <kingdom phylum class order family genus epithet>."), MPS
  fp16, ~100 prompts/s (15 min). Context cut to the longest prompt per batch
  — exact (min cos 1.00000 vs the 77-token pass); recomputed local vectors
  match the eval's `text.npz` to cos ≥ 0.9996.
- **Test set B**: iNat API, Tasmania, Plantae, `captive=true`, species rank,
  photo licence CC0/BY/BY-NC, 3,947 observations (all dates; casual grade by
  definition). Label quality: kept only observations whose current
  species-level IDs all agree and come from **≥ 2 users** (`rg2`, 1,444) or
  from **one identifier who is not the observer** (`one_other`, 406);
  dropped 1,917 observer-only IDs, 19 disagreements, 155 infraspecific taxa
  without a species name in the API answer. One photo per observation, ≤ 8 per
  species → 1,495 photos, 612 species; observer-hash halves: **tune** 651
  (B1 213 / B2 438), **report** 844 (B1 265 photos, 174 species / B2 579,
  278 species). B1 = species not among the 2,675 (95.5 % of B1-report photos
  have their species in the global list = the ceiling), B2 = in them (planted
  natives and naturalised garden species). Photos 500 px "medium" as in the
  eval, embedded with the **shipped w8 Core ML encoder** (compute units ALL,
  `build_ship.preprocess`, 0.073 s/photo). A-test uses its cached w8
  embeddings, A-val the eval's cloud fp16 ones (tuning only).
- **Variants.** v0 = `Ship` (int8 bank, prior) as shipped. **v1** =
  zero-shot cosine × κ over local ∪ global text vectors, global logits − b
  (rest-of-world penalty; no location prior for them) → P_out = zero-shot
  mass on global species; local answer distribution = (1 − P_out) · p_Ship;
  a global species is named only if its probability beats the best local by
  e^m; then the usual ladder (species ≥ .5, genus ≥ .5, else not sure);
  global answers and P_out ≥ .5 carry a "not on IzzyMap's list" flag. **v2**
  = v0 + an OOD flag that replaces the answer with "not sure — may not be on
  the list": kNN top-1 similarity < θ, or P_out ≥ θ. Sweep: centring raw /
  centred, κ ∈ {25, 35, 50, 70, 100}, b ∈ {0…12}, m ∈ {0, 1, 2}, θ (v1 210,
  v2 216 settings). Choice = best B-tune utility (+1 right species, +0.5
  right genus only, −1 any wrong answer) among settings whose **A-val**
  top-1 drops ≤ 0.3 pt, wrong answers rise ≤ 0.3 pt, species-named rate
  drops ≤ 1 pt. Reported on A-test and B-report only.

Results (A = 5,684 wild test photos, photo-weighted as in the eval; B per
photo; "conf. wrong" = a Tasmanian species named at p ≥ .5 that is wrong):

| | A top-1 | A top-5 | A named | A named right | A wrong ans. | A flagged | B1 species right | B1 genus right | B1 flagged | B1 conf. wrong | B2 top-1 | B2 species named right |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v0 shipping | 94.7 | 99.0 | 96.4 | 95.4 | 4.8 | 0 | 0 | 29.1 | 0 | **68.7** | 90.5 | 89.8 |
| v1 raw, κ 100, b 8, m 2 | 94.3 | 99.0 | 96.1 | 95.1 | 5.1 | 0.8 | **49.4** | 70.6 | 69.1 | 18.1 | 90.0 | 88.1 |
| v2 P_out ≥ .7 (raw, κ 70, b 4) | 94.7 | 99.0 | 95.1 | 95.5 | 4.7 | 1.7 | 0 | 12.1 | 75.5 | 16.6 | 90.5 | 88.1 |
| v1 unconstrained (κ 70, b 2, m 0) | 90.9 | 98.4 | 92.0 | 93.6 | 6.7 | 7.0 | 63.8 | 84.9 | 89.4 | 7.9 | 85.7 | 81.5 |

- v1's A cost is real but small: paired on A-test, 11 of 5,567 in-label
  photos lose their right top-1 to a global species, none gain (−0.4 pt
  weighted; the A-val guard allowed 0.3 — selection noise). A stricter guard
  (≤ 0.1/0.1/0.5 pt on val: centred, κ 70, b 12, m 1) still lost 8 photos
  (A 94.6) and was worse on B1 (38.9 % right, 29.1 % conf. wrong).
- B1 under v1 is stable across label tiers (rg2 50.3 % / one_other 47.8 %
  right) and dates (before / from 2024-09-01: 48.9 / 50.0 %), so neither
  label quality nor pretraining overlap shows up in these numbers.
  Species-averaged B1: 48.9 %.
- The Protea case: 16 Protea / Leucadendron / Leucospermum photos in B. v0
  names *Osteospermum moniliferum*, *Telopea truncata*, *Hakea drupacea*,
  *Cyathodes glauca* … or not sure (0/16 right); v1 names the right species
  on 15 and the genus (*Protea*) on the 16th, all flagged.
- Reading b: e^−8 per global species × 89,823 species ≈ 30 "label
  equivalents" against 2,675 local ones, i.e. a built-in ≈ 1 % prior that
  a photo shows something off the list. The κ chosen (100) is the model's
  own logit scale (98.9).
- **int8** global matrix (per-row symmetric, like the bank): identical
  results (B1 49.8 vs 49.4 % right, A unchanged).
- Displayed probabilities of global answers are near 1.00 even when wrong
  (no calibration fitted for them); the app should not show a percentage
  for a global answer without fitting one first.

App cost of v1: the 89,823 × 1024 text matrix is 184 MB fp16 or **92 MB
int8** (+ ~2–3 MB names/genus), i.e. the 0.73 GB `plantid` pack → ~0.83 GB.
Scoring = one matrix-vector product, 92 M multiply-adds (≈ 0.06 % of the
ViT-H/14 encoder's ~167 G), memory-bound: one pass over 92 MB is a few ms
at the A18's memory bandwidth, plausibly ≤ 20–30 ms on one CPU core with
NEON int8 dot products, ~50–100 ms if the pages have to come from flash
first. Memory: the matrix is file-backed and mmap-able (clean pages the
OS may drop), ~92 MB resident while scoring. Not measured on a phone.

Caveats: B is small (B1-report 265 photos: ±6 pt at 50 %), only Tasmanian
gardens, and its labels are casual-grade community IDs (one third rest on
a single non-observer identifier). Global names are matched by exact
binomial (GBIF vs iNat synonyms count as misses; B1 truth coverage 95.5 %).
A's 117 not-in-label photos count any answer as wrong (the eval's rule),
so a correct global answer there is scored as a miss. Only one rest-of-world
model (zero-shot text) was tried; a calibrated global temperature, a
"cultivated" prior near houses, or v1 + v2 together remain unexplored.

## Australia-wide evaluation

Question (2026-11-04): Leo's partner (landscape architect) wants **all
Australian native plants**, "in particular all the Eucalyptus variants".
How far does a cheap zero-shot extension get, and what would a trained
Australia-wide model cost? Evaluation only; nothing ships. Code:
`eval_australia.py` (`labels → text → testset → embed → prior → score`, plus
`bench` and `plan`; env in its docstring); outputs in `cache/plantid/australia/`
(`results.json` incl. every sweep row, `results.md`, `C-credits.tsv`,
`plan/`). Local compute for everything: ~20 min.

**Label set** = Australian Plant Census (APC, NSL taxon export CSV, 100 MB,
CC BY 3.0 AU, downloaded 2026-11-04): accepted species, scientific names
only (1,683 phrase names and 520 hybrids/intergrades skipped), native in at
least one mainland state/territory or Tasmania (3,021 naturalised-only and
296 external-territory-only species out) → **21,204 native species**. APC
synonyms (34,478 usable species-rank names) map iNat and TreeOfLife names
onto them. iNat's own `native=true` filter was rejected: it relies on
checklist establishment means and gives only 8,186 Australian vascular
species with research-grade records (17,218 with `introduced=false`).
Universe U = the 21,204 ∪ the 2,675 shipped labels: 1,757 of those attach
to an APC native, the other 918 (weeds, mosses, algae, a few name
mismatches) become extra classes → **22,122 classes**.

| | APC natives | in BioCLIP's ToL list (accepted / via synonym) | ToL coverage | iNat name | with any AU research-grade obs | ≥ 5 CC-licensed AU obs | ≥ 20 |
|---|---|---|---|---|---|---|---|
| all | 21,204 | 18,701 / 654 | 91.3 % | 91.8 % | 15,307 | 10,755 | 6,821 |
| *Eucalyptus* | 720 | 696 / 4 | 97.2 % | 95.0 % | 679 | 524 | 264 |
| *Corymbia* | 94 | 90 / 1 | 96.8 % | 97.9 % | 92 | 72 | 36 |
| *Angophora* | 10 | 10 / 0 | 100 % | 100 % | 10 | 10 | 9 |
| *Acacia* | 1,072 | 1,045 / 2 | 97.7 % | 97.6 % | 760 | 459 | 277 |

("CC-licensed" = an observation with a CC0/BY/BY-NC photo; AU = the coarse
Australia box incl. Tasmania.) Text vectors (eval prompt, kingdom → epithet):
2,675 reused from the eval's `text.npz`, 9,570 from the open-vocab shards
(re-embedded check: min cos 0.99995), 9,877 embedded here (75 s on MPS);
names not in ToL take iNat's lineage (1,285), else a ToL genus's (541) or
family's (83) upper ranks — the text tower never saw those exact strings.

**Test set C** (local iNat open-data snapshot, no API): research-grade,
Australia box minus Tasmania, observed on/after 2024-09-01 (after BioCLIP's
training snapshot), val/test-role observers only — so never a training,
prior or A/B observer (asserted against `train.parquet`) — no shared photo,
first CC0/BY/BY-NC photo, species = an APC native; ≤ 10 photos per
observer. Eligible: 291,698 observations, 9,180 species (428 eucalypts),
6,867 observers. **C-main**: one photo each of 2,400 random species;
**C-euc**: 600 eucalypt photos round-robin over species. Observer-hash
halves: tune (main 989 / euc 257) and **report (main 1,411 photos =
1,411 species; euc 343 photos, 270 species)**. Licences 2,724 BY-NC, 257
BY, 19 CC0; observer logins in `C-credits.tsv`. Embedded with the shipped
w8 Core ML encoder (0.074 s/photo). C-main "sp." = per species (each photo
is its own species); "w" re-weights to the natural mix of observations.

**Location prior (z1)**: 1,793,939 research-grade pool-observer records
(no val/test observer; positional accuracy ≤ 5 km), aggregate counts on
0.1° cells (535,666 (cell, class) pairs), Gaussian kernel σ at the photo,
shrunk as in Tasmania: (K + α f)/(ΣK + α). **Hybrid (h)**: z1 over U
(with a penalty b on non-shipped classes); its mass on the 2,675 is
redistributed by the shipped scorer (`Ship`, int8 bank, Tasmanian prior);
a non-shipped species goes first only if it beats the best shipped one by
e^m. z0/z1 tuned on C-tune (½ C-main per-species + ½ eucalypt top-1); h
under an A-val guard (top-1 and confidently-wrong within 0.3 pt of v0;
**h strict**: within 0.05 pt). "Conf. wrong" = top-1 p ≥ .5 and wrong, over
all photos. Temperatures (on the final log p, ranking unchanged except
through m) fitted on C-tune NLL: z0 0.75, z1 2.0, h 2.0, h strict 1.5.

| variant | A top-1 | A conf. wrong | C-main top-1 sp. / w | C-main top-5 sp. | C-main genus sp. | C-main conf. wrong (cal.) | euc top-1 | euc top-5 | euc genus | euc conf. wrong (cal.) |
|---|---|---|---|---|---|---|---|---|---|---|
| v0 shipping | 94.7 | 4.5 | 10.0 / 35.9 | 12.3 | 45.1 | 50.2 | 4.7 | 6.1 | 83.7 | 44.0 |
| z0 zero-shot (raw, κ 50) | 77.0 | 4.3 (8.8) | 60.0 / 82.6 | 81.6 | 87.6 | 4.1 (10.2) | 39.7 | 60.9 | 93.3 | 0.9 (8.7) |
| z1 + AU prior (centred, κ 70, σ 25 km, α 16, λ 1) | 86.6 | 12.1 (6.7) | **70.3 / 90.6** | 86.4 | 88.0 | 23.6 (11.9) | **58.3** | **81.6** | 93.6 | 28.9 (9.6) |
| h (z1 settings, b 0, m 0) | 94.1 | 4.8 (1.8) | 69.9 / 87.0 | 85.8 | 88.0 | 22.9 (9.9) | 58.6 | 81.3 | 93.6 | 28.6 (7.9) |
| **h strict** (κ 50, λ 0.75, b 0, m 2) | **94.6** | 4.3 | 68.4 / 86.6 | 85.8 | 87.7 | 18.2 | 56.9 | 81.6 | 93.0 | 17.5 |
| h strict, calibrated (T 1.5) | **94.7** | 2.9 | 67.1 / 86.2 | 85.8 | 87.5 | **9.9** | 56.6 | 81.6 | 93.0 | **7.0** |

- **Tasmania doesn't regress under h strict**: paired on A-test, 6 of 5,567
  in-label photos lose their right top-1, none gain (94.6; calibrated
  94.7 = v0). Plain h (guard 0.3 pt on val) lost 41 (−0.6 pt) — again the
  val guard lets selection noise through, so use the strict one.
- **z1 on A = 86.6** with 22,122 labels vs 87.7 for the eval's zero-shot +
  local prior over the 2,675 alone: an 8× larger label set costs only ~1 pt
  in Tasmania when a location prior is on.
- **Eucalypts**: ~57–58 % right species, ~82 % in the top 5, **93 % right
  genus** (Eucalyptus/Corymbia/Angophora); per-species 56–57 %. Misses are
  mostly a close relative (*E. capitellata* → *E. agglomerata*, both
  stringybarks; *E. consideniana* → *E. multicaulis*). The prior matters
  most here: z0 → z1 is +19 pt on eucalypts, +10 pt per species on C-main.
- **Calibration is needed**: uncalibrated z1/h put p ≥ .5 on 85–92 % of
  photos and are wrong on a quarter to a third of those; with T fitted on C-tune the
  confidently-wrong share drops to 7–10 % (A: 2.9 %), right-when-confident
  81–86 %. The app must not show z-style percentages uncalibrated.
- In C-main, species among the 2,675 (183 photos — Tasmanian species seen on
  the mainland) score 77 % under v0 and 74–80 % under z1/h; the other 1,228
  photos 0 % (v0) vs 67–69 %.
- Noise (95 %): C-main report ±2.4 pt at 70 %, eucalypts ±5.2 pt at 58 %;
  paired A comparisons are much tighter. Truth = iNat research grade,
  mapped to APC by name/synonym; a name APC splits or lumps differently can
  count as a miss. Only APC natives are in C; naturalised species
  Australia-wide are not in U at all (only Tasmania's 918 extra labels).

App cost of h: 22,122 × 1024 text matrix (19,447 non-shipped rows: 40 MB
fp16 / **20 MB int8**) + the 0.1° prior (535,666 pairs, ~2–3 MB) +
names — i.e. less than the open-vocab v1's 92 MB, because the label list is
4.6× shorter. Not built, not measured on a phone.

### Trained Australia-wide model: data plan and cost (estimate; nothing run)

Prepared already (`eval_australia.py plan`, DuckDB only, 5 s): observer-
disjoint manifests from the 2026-10 iNat open-data snapshot —
`australia/plan/train.parquet`: **598,062 photos over 15,768 of the 22,122
classes** (pool observers, CC0/BY/BY-NC first photo, no shared photo, ≤ 100
per class, ≤ 3 per (class, observer) before others fill in, Australia first
— 85 % Australian — then the rest of the world, already-embedded photos
preferred); `eval.parquet`: val 34,240 / test 44,617 photos (val/test
observers, Australia incl. Tasmania, ≥ 2024-09-01, ≤ 8 per class). Classes
by training photos: 3,892 at the cap, 3,401 with 20–99, 3,950 with 5–19,
4,525 with 1–4; natives with ≥ 5: 10,369 (eucalypts 578), ≥ 20: 6,468
(275); 6,349 natives have none (frozen text vector, as in Tasmania).
Licences: 513k BY-NC, 73k BY, 11k CC0. Also ready: `labels.parquet` +
`text.npz` (all 22,122 text vectors), `inat_map.parquet`,
`prior_counts.parquet`. 82,583 train and 3,513 eval photos are already
embedded (`emb/bioclip25`) → **590,823 photos to fetch and embed, 90.7 GB**
at the measured 153.5 KB mean "medium" photo.

Throughput: BioCLIP 2.5 on one L4 = **104.9 photos/s end to end, measured**
(`emb/bioclip25/info.json`, the 2026-11-01 cloud run: 92,006 photos, fp16,
batch 128, 7 loader workers). Here on the M4: 7.1 photos/s MPS fp16 (batch
32, GPU only), 13.5/s Core ML w8 — locally the embedding alone would take
~12 h, so it has to be the cloud. T4 = **estimate** 0.45× L4 ≈ 47 photos/s:
fp16 tensor peak 65 vs 121 TFLOPS (0.54×), and a 70 W T4 throttles under
sustained load; published inference comparisons put L4 at ~2–2.5× T4. Photo
download ~135/s with 48–64 keep-alive workers (measured from the laptop),
overlapped with embedding. Head: 598k × 1024 → 22,122, 40 epochs ≈ 3·10¹⁵
FLOP, minutes on either GPU (estimate); prototypes (1 per class) and prior
seconds.

SPOT prices (Cloud Billing catalog, read 2026-11-04, us-central1):
g2-standard-8 = L4 $0.3352 + 8 vCPU × $0.01495 + 32 GB × $0.001751 =
**$0.511/h**; n1-standard-8 + T4 = $0.1981 + 8 × $0.01621 + 30 × $0.002172 =
**$0.393/h**. Disk pd-balanced $0.10/GB-month; S3 → GCE is free (AWS Open
Data bucket, GCP ingress free); GCS egress to the laptop $0.12/GB.

| option (1 GPU — GPUS_ALL_REGIONS = 1) | embed | wall-clock (incl. ~0.5 h setup + head) | GPU-VM $ | × 1.5 SPOT safety | disk 200 GB × 24 h + GCS + egress | **total** |
|---|---|---|---|---|---|---|
| **L4, g2-standard-8, us-central1** | 1.6 h (measured rate) | **~2.1 h** (~3 h with preemptions) | $1.07 | $1.61 | ~$0.9 | **≈ $2.5** |
| T4, n1-standard-8, us-central1 | 3.5 h (estimated rate) | ~4 h (~6 h) | $1.57 | $2.36 | ~$0.9 | ≈ $3.3 |

Footnote: 4 × L4 shards (not possible while GPUS_ALL_REGIONS = 1): same
GPU-hours plus 3 more setups (+~$0.4), wall-clock ~0.6 h.

**Recommendation: one SPOT L4 in us-central1** — cheapest per photo
(≈ $1.4 vs ≈ $2.3 per million photos) and fastest. Quotas: GPUS_ALL_REGIONS ≥ 1
(granted 1) and PREEMPTIBLE_NVIDIA_L4_GPUS us-central1 ≥ 1 (granted 3) —
nothing to request. Fallbacks without a request: L4 us-east1 (2), T4
us-central1 (4). Console: IAM & Admin → Quotas & System Limits
(`console.cloud.google.com/iam-admin/quotas?project=leo-superresolution`),
filter "Preemptible NVIDIA L4 GPUs". Even 10× these estimates stays
well below the $100 line.

Job design (resumable): upload `plan/*.parquet` + the existing
`emb/bioclip25` shards to GCS; the VM (SPOT, `--instance-termination-action
=STOP`, `--max-run-duration=6h`, startup script re-runs the job) walks
1,000-photo shards: skip if `emb/shard-NNNN.npz` exists in GCS, else fetch
(prefetching the next shard) → embed → upload → delete the photos. A
preemption loses ≤ 1 shard. Then head training with per-epoch checkpoints to
GCS, prototypes, prior, val/test scoring, artefacts to GCS, power-off; the
laptop fetches ~0.1 GB and runs `down`. Needed before launch (code only, no
compute): `fetch_photos.py`/`embed.py` reading the plan manifests (they read
`sets/` today), a shard loop, and a 22k-class head trainer (build_ship's
`train_head` on the new arrays); `run_cloud.sh` takes PROJECT/ZONE from the
environment (`PROJECT=leo-superresolution ZONE=us-central1-a`), and needs
outbound internet (external IP or Cloud NAT) for the S3 bucket.

On-device artefacts (estimate): head 22,122 × 1024 fp16 45 MB (int8
23 MB); prototype bank 15,768 × 1024 int8 16 MB instead of a 598k-row kNN
bank (612 MB int8; in Tasmania proto1 cost ≈ 0.4 pt vs the full bank);
prior ~3 MB at 0.1° (+ the 0.3 MB Tasmanian 2.5 km grid); labels ~4 MB;
credits ~10 MB → the `plantid` pack stays ≈ 0.7 GB (the 85 MB int8 bank
goes away).

Expected gain — the only evidence we have: in Tasmania, zero-shot + local
prior → trained head ⊕ kNN + prior went 87.7 → 94.7 % (photo-weighted; 57 %
fewer errors) and 81.1 → 87.2 % per species (32 % fewer). Carried over to
z1 that would be C-main ~96 % photo-weighted / ~80 % per species and
eucalypts ~70 % — an extrapolation, not a measurement: Australia has 8×
the classes, 4,525 classes with 1–4 photos and 6,349 natives with none,
and eucalypt species are unusually close. The trained model's own
val/test split (above) would measure it.

### Trained Australia-wide model: the run

Code: `train_australia.py` (`manifest → vm-embed → vm-train → score`),
laptop side `cloud/run_au.sh`, VM side `cloud/vm_au.sh` (its startup script:
runs at every boot, pulls code, inputs and the model weights from GCS, so a
SPOT VM stopped by a preemption resumes with `run_au.sh start`; no ssh). Work
bucket `gs://leo-superresolution-izzy-plantid/au` (us-central1). Photos are
fetched into memory and never written to disk.

- Manifest: plan train ∪ eval = 676,919 photos, 86,095 already embedded →
  **590,824 to embed = 591 shards of 1,000** (`train/todo.parquet`).
- Smoke test (2026-11-04, 3 shards, one SPOT g2-standard-8 + L4, us-central1-a):
  **102.6 photos/s end to end, measured** (3,000 photos in 29 s incl. the S3
  download at 13.5 MB/s with 48 threads; 0 missing). Matches the 2026-11-01 run
  (104.9/s). Two hiccups on the way: the first boot was preempted after 4 min,
  and its half-finished Hugging Face download left a corrupt cache → the
  weights now come from GCS (copied from the laptop's HF cache, offline on the
  VM).
- Full run launched 11:41 UTC in us-central1-a at 108–111 photos/s; preempted
  at 11:56 after 94 shards, then **stockout** for SPOT L4 in us-central1-a/b/c
  → the VM was recreated in **us-east1-c** (L4 SPOT quota 2; resumes from the
  shards in GCS — `ZONE=us-east1-c run_au.sh …` for that VM).
- **Bound, written before the full launch:** 587,824 photos / 102.6 per s =
  **1.6 h embedding** + ~0.1 h boot + head training (estimate ~0.15 h: 2 μ ×
  40 epochs of 598k × 1024 → 22,122 on the L4; 45 min on the M4's GPU,
  measured per step) ≈ **1.9 h** → `--max-run-duration=4h` hard cap.
  Cost: VM $0.511/h × 1.9 h ≈ $0.97 (× 1.5 for preemptions ≈ $1.5) + disk
  120 GB pd-balanced $0.016/h (≤ 24 h kept: $0.4) + external IP ~$0.005 +
  GCS ~5.6 GB ($0.11/month; the 3.9 GB model copy is deleted afterwards) +
  egress to the laptop ~1.5 GB ($0.18) ≈ **$2.2** (cap: 4 h × $0.53 = $2.1 of
  VM time per boot).
- **Actual:** us-east1-c boot 11:59 → 13:36 UTC (497 shards, 496,813 photos in
  4,924 s = **100.9/s**, 11 photos gone upstream, 0 failed; then both heads,
  6 min each on the L4 = 3 × 94 s per 10 epochs). GPU VM time over all boots
  ≈ 2.0 h (smoke 2 × ~4 min, 15 min before the preemption, 97 min) ≈ $1.0 at
  the us-central1 SPOT rate; disks ≈ $0.13; egress ≈ $0.3 (laptop 1.5 GB,
  us-central1 → us-east1 reads ~5 GB) → **≈ $1.5**. VM and disks deleted;
  GCS keeps the embeddings + heads + inputs (1.75 GB ≈ $0.04/month; the
  model copy was deleted). Train set: 598,052 of 598,062 photos (10 gone
  upstream), 15,768 classes.

### Trained Australia-wide model: results

`train_australia.py score` (~9 min on the M4) tunes on **AU-tune** — 12,029
photos of the plan's val observers (≥ 2024-09-01, Australia incl. Tasmania),
minus every C-report and A-test observer — plus A-val for the Tasmanian
guard; it then writes the shipping files and scores everything FROM THE FILES
(`build_ship.AuShip`). Never tuned on A-test, C-report or AU-test.

Model (chosen on AU-tune): head μ 1e-5, 40 epochs (of {1e-5, 1e-4} × {10, 20,
40}), int8 per-row (no loss: objective 0.8117 vs 0.8118); kNN over 15,768
prototypes (1 per class, int8) k 10, τ 0.05, ρ 0.5, ω 4 (ω 0 → 4: objective
0.812 → 0.831); zero-shot pull κ 30, ω 0.25 (+0.001 only); Australia-wide prior
on 0.05° cells σ 10 km, α 4, λ 0.25 (0.832 → 0.883); final temperature
T 1.48 (log p / T, NLL on AU-tune). Hybrid (Tasmanian scorer for its 2,675
labels): τ 1.5, b 2, m 2, T 1.0 — only 4 of 36 settings passed the strict
A-val guard (top-1 and confidently-wrong within 0.05 pt of v0). **tg** = the
pipeline default: the hybrid inside the Tasmania box (lon 143.5–149, lat −44…
−39.2) or without a location, the trained model alone elsewhere.

Same columns as the table above (A = 5,684 Tasmanian test photos, photo-
weighted; C-main 1,411 species; euc 343 photos / 270 species; "conf. wrong" =
named at p ≥ .5 and wrong, over all photos) plus **AU-test** = the plan's test
observers (44,616 photos, 9,209 classes, ≤ 8 per class, weighted to the
natural mix; embeddings cloud fp16, all other sets w8 Core ML):

| variant | A top-1 | A conf. wrong | C-main top-1 sp. / w | C-main top-5 sp. | C-main genus sp. | C-main conf. wrong | euc top-1 | euc top-5 | euc genus | euc conf. wrong | AU-test top-1 w / sp. |
|---|---|---|---|---|---|---|---|---|---|---|---|
| v0 shipping | 94.7 | 4.5 | 10.0 / 35.9 | 12.3 | 45.1 | 50.2 | 4.7 | 6.1 | 83.7 | 44.0 | 45.6 / 18.7 |
| z1 + AU prior (above) | 86.6 | 12.1 (6.7) | 70.3 / 90.6 | 86.4 | 88.0 | 23.6 (11.9) | **58.3** | **81.6** | 93.6 | 28.9 (9.6) | 88.8 / 70.4 |
| h strict, calibrated (above) | 94.7 | 2.9 | 67.1 / 86.2 | 85.8 | 87.5 | 9.9 | 56.6 | 81.6 | 93.0 | 7.0 | – |
| trained head only, no prior | 84.1 | 10.3 | 68.4 / 79.9 | 87.3 | 89.3 | 17.8 | 39.7 | 62.4 | 91.8 | 20.4 | 83.0 / 69.3 |
| t1 trained (head ⊕ protos ⊕ zs + prior), cal. | 91.6 | 2.4 | **74.3 / 87.8** | 88.9 | **90.0** | **6.1** | 51.9 | 67.9 | 92.7 | **4.7** | 90.7 / 75.8 |
| **tg** = hybrid in Tasmania, t1 elsewhere, cal. | **94.7** | 4.1 | **74.3 / 87.8** | 88.9 | **90.0** | **6.1** | 51.9 | 67.9 | 92.7 | **4.7** | **90.8 / 76.0** |

(z1 on AU-test computed for this table with the same settings as above.)

- **Tasmania holds:** tg on A-test = 94.69 % (v0 94.69): paired, 0 of 5,567
  in-label photos lost, 0 gained; top-5 98.8 (v0 99.0). t1 alone would cost
  2.6 pt in Tasmania (251 lost, 97 gained) — hence the gate. AU-test's
  Tasmanian photos: tg 95.0, v0 95.0, t1 93.5.
- **Mainland:** C-main +4.0 pt per species over z1 (74.3 vs 70.3; ±2.4 pt
  noise), photo-weighted −2.8 (87.8 vs 90.6, single photos per species: noisy).
  On the much larger AU-test the trained model leads z1 by +2.0 photo-
  weighted and **+5.6 per species** (76.0 vs 70.4); mainland 90.5 vs 88.8. By
  training photos of the true class (AU-test per species): 100 photos 89.7 %,
  20–99 81.6, 5–19 65.5, 1–4 31.5, none 0 (239 photos — the frozen text rows
  never win against trained ones).
- **Eucalypts: no gain from training.** C-euc 51.9 % vs z1's 58.3 (−6.4 pt,
  beyond the ±5 pt noise, top-5 68 vs 82); on AU-test's 1,762 eucalypt photos
  62.7 % vs z1's 63.1 (tie). Genus right 92.7 %. C-euc is round-robin over
  species (many rare ones), where z1's text prompts + stronger prior (λ 1,
  σ 25 km) do better than a head trained on ≤ a few photos. Not tried: tuning
  on a eucalypt subset, a larger zero-shot weight for classes with few photos,
  λ per class group, more eucalypt photos (the cap of 100 binds for 275
  eucalypt species, 2026-10 snapshot).
- **Calibration works:** t1's confidently-wrong share 12.8 → 6.1 % on C-main
  and 16.9 → 4.7 % on eucalypts after T 1.48 (right when confident: C-main
  91 %, eucalypts 88 %, A 97 %). The hybrid's own fitted T is 1.0, so A's
  confidently-wrong 4.1 % is the Tasmanian scorer's (v0 4.5).
- C-main split: species among the 2,675 81.4 % (v0 77.0), the other 1,228
  photos 73.2 % (v0 0).

**Eucalypt round (2026-11-05, local only, `eucalypt_tail.py`).** Tuned on
AU-tune + the 638 AU-val eucalypt photos (val observers minus C-report/A-test
ones), reported on A-test, C-report and AU-test. Tried: (a) logit adjustment
−τ·log(n+1) (τ ≤ 1), (b) a per-class zero-shot weight w0 + w1/(1 + n/n0),
(c) both with λ/σ re-tuned — 504 settings, criterion ½ AU-tune + ½ eucalypt
top-1: best C-euc 51.6–55.1 / top-5 ≤ 74.6, i.e. the top-5 gap stayed. (d) A
z1-like ensemble — image weight α ∈ {0.5, 1}, zero-shot κ 70 with w0 ∈ {0.5, 1,
2}, prior σ 25 km, λ ∈ {0.5, 1}, τ, w1 — 72 settings, criterion ½ AU-tune +
¼ eucalypt top-1 + ¼ top-5 → **chosen: α 0.5, κ 70, w0 0.5, λ 1, σ 25 / α 16,
τ 0, w1 0, T 1.80** (no per-class vector needed; hybrid unchanged). Scored
from the files (tg):

| variant | A top-1 (paired vs v0) | C-main top-1 sp. / w | C-main top-5 | C-main conf. wrong | euc top-1 | euc top-5 | euc genus | euc conf. wrong | AU-test euc top-1 / top-5 (1,762, natural mix) |
|---|---|---|---|---|---|---|---|---|---|
| z1 | 86.6 | 70.4 / 90.6 | 86.3 | 23.6 | 58.3 | 81.6 | 93.6 | 28.6 | 63.1 / 86.5 |
| tg (first round) | 94.7 (−0/+0) | 74.3 / 87.8 | 88.9 | 6.1 | 51.9 | 67.9 | 92.7 | 4.7 | 62.7 / 74.7 |
| **tg, eucalypt round (shipped)** | 94.7 (−0/+0) | 70.7 / 90.9 | 88.9 | 14.8 | 54.8 | **81.9** | 93.0 | 18.7 | **64.2 / 88.5** |

The price: per species on C-main −3.6 pt (74.3 → 70.7, still ≥ z1) and on a
6,000-photo AU-test sample −3.2 (83.9 → 80.7), and the confidently-wrong share
rises (C-main 6.1 → 14.8 %, eucalypts 4.7 → 18.7 %) because the flatter
ensemble is calibrated on AU-tune's natural mix. Eucalypt top-1 on C-euc is
still 3.5 pt under z1 (inside the ±5 pt noise); in the natural mix it is
ahead (+1.1 top-1, +2.0 top-5). Previous au files: `ship/au-v1/`. Format:
`au-protos.bin` scoring gains `image_weight` (L_img = log_softmax(image_weight
· L_img + zs_omega · L_zs); default 1); `au-prior.bin` header σ 25 km, α 16.

**Answer ladder on the AU path** (`eucalypt_tail.py ladder`, 2.6 min): the
Tasmanian path (Tasmania box or no location) keeps species 0.5 / genus 0.5;
outside it the app uses **species 0.7 / genus 0.7** (`pipeline.json`
`australia.ladder`, fixtures `ladder_au`). On AU-tune's natural mix the 0.5
rule already stated a wrong species on only 4.2 % of photos — the confident
errors are in the long tail — so the thresholds were chosen on AU-tune per
photo (≤ 8 per class) and the 638 AU-val eucalypts (natural mix): the lowest
species threshold with "species stated but wrong" ≤ 7 % on both, then the
lowest genus threshold whose genus answers are no less reliable. Mainland
photos only (share answered / error of that rung):

| set | thresholds | species | species err. | species wrong / all | genus | genus err. | not sure |
|---|---|---|---|---|---|---|---|
| C-main | 0.5 / 0.5 | 79.7 | 18.6 | 14.8 | 10.3 | 7.6 | 10.1 |
| C-main | **0.7 / 0.7** | 64.0 | 12.3 | 7.9 | 18.2 | 3.5 | 17.8 |
| C-euc | 0.5 / 0.5 | 64.4 | 29.0 | 18.7 | 31.5 | 3.7 | 4.1 |
| C-euc | **0.7 / 0.7** | 39.9 | 14.6 | 5.8 | 50.1 | 2.3 | 9.9 |
| AU-test eucalypts, natural mix | 0.5 / 0.5 | 76.6 | 16.1 | 12.3 | 20.4 | 7.0 | 3.0 |
| AU-test eucalypts, natural mix | **0.7 / 0.7** | 57.3 | 9.5 | 5.4 | 34.8 | 1.5 | 7.9 |
| AU-tune, natural mix (all species) | **0.7 / 0.7** | 85.5 | 2.1 | 1.8 | 6.6 | 2.6 | 7.9 |

Shipping files (in `ship/`, staged by `build_ship.py au` + the same
`build_packs.py` stage): `au-head.bin` 22.7 MB (22,122 × 1024 int8 + fp16
row scale + fp32 centre), `au-protos.bin` 16.2 MB (15,768 int8 prototypes,
header `scoring` + `hybrid`), `au-text.bin` 22.7 MB (centred text vectors,
int8), `au-prior.bin` 5.2 MB (kind `plantid-prior-deg` v2: 0.05° grid 690 ×
850 from 44° S / 112° E, CSR rows, 699,071 (cell, class) pairs, query-latitude
cos correction — see `DegPrior`; σ 25 km, α 16 after the eucalypt round), `au-labels.json` 3.0 MB; `credits.json`
(3.8 MB) / `credits-photos.tsv.gz` (4.2 MB) now cover the union of both
training sets (598,116 photos, 42,572 observers; 513k BY-NC, 73k BY, 12k CC0).
`pipeline.json` gains an additive `australia` section (steps, parameters,
hashes); the Tasmanian files are unchanged. Pack with the new files (scratch
build with them added to the file list): **0.803 GB on the device, 0.747 GB
`.aar`** (now 0.733 / 0.688), verified byte for byte. Shipping it needs
the five `au-*` names in `asset_packs.json` AND `Packs.swift`
(`packPaths`), and the app scorer port — not done here. The previous ship
files are in `ship/tas-2026-11-04/`.

## Licences

Only photos under CC0 / PD / CC BY / CC BY-NC are fetched (iNat's
per-photo licence, `license` column). ND and SA are excluded because a model
trained on them might count as an adaptation (which ND forbids sharing and
SA would force under the same licence). Australia has no text-and-data-mining
exception (ruled out Oct 2025), so the CC licence is the permission.
Photos stay in `pipeline/cache/` (gitignored) and are never committed or
uploaded. If a trained head ever ships, it needs a credits file (photo id,
observer login, licence) — `train.parquet` has the ids, the observers table
(`observers.csv.gz`, 18 MB) the logins.
