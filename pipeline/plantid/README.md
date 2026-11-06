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

## Single model (v2): one trained classifier

Code `train_v2.py` (design in its docstring). Data (`v2 data`, 24 s): 598,115
train photos (plan train ∪ the Tasmanian run's 82,649; 15,770 classes with
photos of 22,122), AU-val 17,055 + A-val 3,677 photos for early stopping /
selection; zero-shot scale s0 = 50 (val NLL). **Measured locally:** one epoch
on a 5 % sample = 2.7 s on the M4 (MPS) → ~55 s per full epoch → ~27 min per
30-epoch run, ×15 runs ≈ 7 h → cloud. **Bound (written before launch):** one
SPOT L4, 9.4 s/epoch (measured 2026-11-04 for the same 598k × 1024 → 22,122
matmul) + ~1 s val per epoch → ≤ 5.2 min per 30-epoch run; 9 sweep runs (τ ∈
{0.5, 1, 1.5} × L2-SP wd ∈ {0.01, 0.1, 1}) + 6 one-change runs (random init,
plain CE, no L2-SP, 25 % / 50 % data, genus sharing) ≈ 70 min + ~10 min boot
≈ 1.4 h ≈ $0.7 VM + disk $0.03 + egress (15 heads × 45 MB ≈ 0.7 GB) $0.08 ≈
**$0.8**; `--max-run-duration=3h` cap (≤ $1.6 per boot). Resumable per run
(each head uploaded to `v2/runs/` as it finishes, finished runs skipped).

## Reference photos

One offline photo per Australia-wide label, so a result without an
Understorey Network profile still shows something to compare against.
`build_refphotos.py` (`select → fetch → encode`, or `all`; env in its
docstring; measured 2026-11-05 on the M4):

- **select** (7 s warm; the first run scans `meta/photos.csv.gz` once for
  original sizes, 126 s → `refphotos/dims.parquet`). Classes with training
  photos (plan `train.parquet` ∪ the Tasmanian `sets/train.parquet`: pool
  observers, first CC0/BY/BY-NC photo, no shared photo — 598,119 embedded):
  the 5 photos whose BioCLIP 2.5 embedding is nearest the class mean (a
  typical view), then original ≥ 500 px and not a panorama, CC0/PD > CC BY >
  CC BY-NC, original ≥ 1000 px, nearer the mean. 70 % of picks are the
  nearest photo itself. **Text-only classes** (6,354, no training photo): any
  research-grade observation in the snapshot, any observer role, anywhere,
  with a CC0/PD/BY/BY-NC photo — 557 classes have one (mostly val/test
  observers, whose non-evaluation photos are fine to show; the plan only
  excluded them from training). No embedding to judge these by, so: the
  observer's lead photo, unshared, Australian, licence, size — weaker (a
  hand holding a sprig shows up). Never an evaluation photo (plan
  `eval.parquet`, `C.parquet`, `sets/test.parquet`; asserted for training
  photos). Each class keeps ranked candidates; a photo gone upstream falls
  through to the next.
- **fetch**: the 500 px "medium" from the iNat open-data bucket, 48
  keep-alive workers → `refphotos/src/` (resumable). 16,325 photos, 2.09 GB
  in 116 s (140/s, 18 MB/s), none gone upstream.
- **encode**: sRGB (ICC converted), long edge ≤ 512 (the medium is ≤ 500 px
  — never upscaled), AVIF speed 6. Sweep on random picks (mean KB per photo ×
  16,325): q45 16 KB / 264 MB, q50 18–19 / 292–315, **q55 21–23 / 344–371**,
  q60 28 / 452; q45 smears fine foliage at 2×, q55 ≈ q60 by eye → **q55**.
  5.6 min on 10 cores.

Result: **16,325 of 22,122 labels** (15,768 from training photos + 557 from
the snapshot); 5,797 text-only classes have no usable research-grade photo
in the 2026-10 snapshot (4,616 of the 6,354 had an iNat name at all) — the
app shows none for them. Licences: 9,791 CC BY-NC, 5,706 CC BY, 828 CC0;
3,309 observers. Staging (gitignored) `cache/plantid/refphotos/pack/
refphotos/`: `<slug>.avif` (slug of the au-labels name, e.g.
`eucalyptus-globulus.avif`) 356 MB, `index.json` 5.0 MB (name → u, file,
w, h, licence, observer name as iNat shows it + login, ready-made
`attribution` "© name, CC BY-NC, via iNaturalist" (CC0: "name, CC0 (no
rights reserved), via iNaturalist"), photo id, observation uuid, ext; URL
templates for the photo page, observation and source), `credits.json`
0.27 MB → **0.362 GB** as a pack (one `refphotos/` directory entry; not yet
in `asset_packs.json` / `Packs.swift`). The app must show `attribution`
next to each photo; BY-NC = non-commercial only (IzzyMap is private).
Resizing/re-encoding is an adaptation, allowed by CC0/BY/BY-NC (no ND/SA
photo is ever selected).

### Single model (v2): results (2026-11-05)

Run: 18 heads on one SPOT L4 (us-east1-c, ~45 min of VM incl. three boots lost
to a broken `uv` — an interrupted install left an EMPTY binary that "runs" as
an empty shell script with exit 0; `vm_au.sh` now checks its output) ≈ $0.6;
VM and disk deleted. 10.3 s/epoch measured. Eval `eval_v2.py` (8 min, M4):
everything chosen on AU-val **per species** (class-balanced); report sets
untouched. 19 duplicate classes (5 sharing an iNat taxon + 14 `photo_flow:
merge` from `names/apc_inat_map.json`) are merged at evaluation (twin column
masked, truths remapped; `train_v2.class_merges` asserts unique taxon ids and
names; the data step applies it for the next training run).

**Recipe (final):** head init = s0 · centred text (s0 = 50 by val NLL), logit-
adjusted CE τ = 1 (balanced softmax), AdamW lr 1e-3, decoupled decay toward the
text init wd 0.01, warmup 1 epoch + cosine over **12** epochs (best epoch 9),
no kNN/prototypes, prior = sqrt-flattened counts, σ 10 km, α 16, λ 0.75 (×
p_bal, Bayes), T 1.65 (class-balanced val NLL), ladder 0.55 / 0.55 (val:
stated-wrong 6.5 % per species), one path for all of Australia.

Per species / natural mix (top-1, top-5), genus per species, conf. wrong per
species — full table incl. every ablation in `australia/v2/eval.md`:

| model | A top-1 | A top-5 | C-main top-1 | C-main top-5 | C-euc top-1 | C-euc top-5 | AU-test top-1 | AU-test top-5 | AU-test euc top-1 | AU-test euc top-5 |
|---|---|---|---|---|---|---|---|---|---|---|
| **v2 single model** | 85.4 / 93.6 | 96.1 / 99.0 | **77.0** / 92.0 | **91.8** / 98.0 | 55.9 / 71.1 | 81.7 / 91.7 | **78.1** / **92.8** | **90.8** / 98.4 | **58.7 / 77.3** | 82.4 / 93.7 |
| gated hybrid (staged) | **87.1 / 94.7** | 96.7 / 99.0 | 70.7 / 90.9 | 88.9 / 97.2 | 52.8 / 66.0 | 80.6 / 93.8 | 72.5 / 90.3 | 88.6 / 97.5 | 55.1 / 74.0 | 83.2 / 92.4 |
| z1 zero-shot + prior | 79.7 / 86.7 | 92.9 / 94.3 | 70.3 / 90.6 | 86.4 / 96.3 | 57.4 / 66.2 | 81.9 / 93.0 | 70.4 / 88.9 | 86.8 / 96.2 | 56.1 / 70.2 | 81.8 / 91.0 |

- **Tasmania regresses:** A-test natural 93.6 vs 94.7 (paired vs the gated
  hybrid: 173 lost, 105 gained; per species 85.4 vs 87.1). The Tasmanian
  specialist (Tasmania-first training photos, 82k-photo kNN bank, 2.5 km
  prior) still earns ~1 pt there; prototypes/kNN did NOT help the single
  model (val per species 0.883 → 0.874 at ω 0.25). A Tas-specific path stays
  justified until more data closes it — Leo's call.
- **Ablations (vs the same-schedule base, AU-test per species):** random init
  75.8 vs 77.4 (1–9-photo bucket 43.6 vs 47.3); plain CE 73.9; post-hoc logit
  adjustment on plain CE (τ' 1.5 on val) 78.0 — as good as the balanced loss
  (better on eucalypts: 60.6 vs 57.0, worse on A 83.8 vs 84.7); L2-SP pull wd 0
  vs 0.01: no difference (77.3 vs 77.4) — text init + early stopping do the
  work; genus sharing (γ 0.5): 77.4 (C-euc 54.6 vs 52.4, within noise); no
  location prior 74.5 (C-euc 40.9!); prior kinds count / log1p / sqrt /
  presence within 0.2 pt on val; on test, count is best overall (78.8) and
  worst on eucalypts (C-euc 52.0 vs 55.9): range-like priors suit the rarer
  species.
- **Diagnostics** (`australia/v2/curves.png`, `reliability.png`,
  `data_size.png`): train loss → 0.03 (memorises), val loss bottoms at epoch
  ~10 (0.74 with the 12-epoch cosine vs 0.82 with 30); AU-test per species by
  training photos: 0 → 0.6 %, 1–9 → 49.3, 10–49 → 77.4, 50–100 → 89.9 (gated
  hybrid 0 / 39.5 / 70.0 / 86.5); per-class fit acc ≈ 0.35 + 0.29·log10(n);
  data-size curve (25 / 50 / 100 % of each class): AU-test per species 74.8 /
  76.1 / 77.4 — about +1.3 pt per doubling, not flat; ECE per species 0.115 →
  0.023, natural 0.029 → 0.021 after T. Ladder on test: stated-wrong per
  species 8.7 % (AU-test), 9.9 (C-main), 13.3 (C-euc) — above the val target.
- **Caveat (bug, fixed afterwards in `train_v2.py`):** early stopping compared
  the per-species val top-1 against the stored *mixed* objective, so the 30-
  epoch runs stopped by patience at ~epoch 16 and the kept epoch was within
  ~0.4 pt of the true best (final run: epoch 9 of 12, 0.810 vs best 0.811).
  The stage-1 ranking margins (≥ 0.7 pt) and the ablation directions are
  larger than that; the 12- vs 30-epoch schedule comparison is confounded.
- **Tail data** (`tail_data.py`, `australia/v2/tail_data.json`): classes with
  1–9 training photos (6,534) use 22,946 photos; the same observations hold
  53,893 more usable photos (×2.3, but same plant), SA/ND-only observations
  add 3,020 (+13 %), the held-out val/test observers 12,318 observations. The
  6,352 photo-less classes have almost nothing in the snapshot (1 pool obs,
  1,116 held-out obs, 1,073 SA/ND photos). The snapshot contains CC0/BY/BY-NC
  AND SA/NC-SA/ND/NC-ND photos (2.2M NC-SA, 2.0M SA, 1.7M NC-ND, 0.35M ND of
  119M), never all-rights-reserved; iNat API sample of 50 tail AU species
  (≤ 1 req/s): 13.4 % of research-grade AU observations with photos are ARR
  only, 8.9 % SA/ND only.
- **Encoder fine-tuning (not run; estimate):** measured ViT-H/14 inference on
  the L4 101–109 photos/s fp16; fwd + bwd ≈ 3× → ~35 photos/s (estimate), so
  3 epochs over 598k photos ≈ 14 h ≈ $7 SPOT per run (+ re-fetching 90 GB of
  photos per epoch, or a 150 GB disk), a minimal 3-run sweep ≈ $25 and ~2
  days, then a new Core ML export + w8 validation. Judgement: unlikely to pay
  off now — the head already memorises the training set, the gains left are
  in the tail where a 632M-parameter encoder would overfit 1–9 photos and can
  erode the BioCLIP text alignment the photo-less classes rely on; more photos
  per tail class (+1.3 pt per doubling) is the better lever. Revisit (LoRA /
  last blocks) after the data expansion.

### Single model (v2): Tasmania gap, ladder, error analysis (2026-11-05)

**Corrected headline** (early-stopping fix; run `v2fix-e12`, 12-epoch cosine,
best epoch 12, val per species 0.8105, trained locally on the M4, 17 min):
A 85.3 / 93.4 (per species / natural), C-main 77.4 / 91.3 (top-5 91.3),
C-euc 56.1 / 69.7 (top-5 80.4), AU-test 78.2 / 92.7 (top-5 91.0), AU-test
eucalypts 58.0 / 76.7 (top-5 81.7); A paired vs the gated hybrid −173 / +96.

**Why Tasmania drops** (`tas_gap.py`, A-test natural top-1, weights on A-val
only; NB: the shipped Tasmanian prior is iNat-based too — pool-observer
records on 2.5 km cells — not ALA):

| | top-1 nat. | per sp. | vs shipped (lost / gained) |
|---|---|---|---|
| shipped Tasmanian scorer (head ⊕ 82k-photo bank + Tas prior) | 94.6 | 87.0 | – |
| Tasmanian head ⊕ bank, no prior | 91.4 | 85.7 | −219 / +84 |
| v2 head, no prior, 22,122 classes | 87.0 | 81.7 | −482 / +102 |
| v2 head, no prior, only the 2,675 | 90.8 | 85.4 | −283 / +126 |
| v2 (head + AU prior) | 93.4 | 85.3 | −177 / +112 |
| v2, only the 2,675 | 93.8 | 86.0 | −152 / +115 |
| v2 head + the Tasmanian prior (2,675) | 93.7 | 83.1 | −202 / +89 |
| Tasmanian head ⊕ bank + v2 prior | 93.7 | 84.1 | −140 / +55 |
| F: prior strength re-tuned in Tas. (λ 1.5) | 93.0 | 81.0 | −270 / +103 |
| F: prior σ 5 km | 93.2 | 84.1 | −209 / +97 |
| F: + ALA lift (nearby.bin, 1,727 UN species, σ 5) | 94.0 | 86.7 | −150 / +129 |
| F: + Tasmanian-bank kNN (ω .25) inside Tasmania | 94.2 | 87.0 | −115 / +110 |
| F: Tasmanian photos ×3 in training (head) | 93.5 | 85.4 | −163 / +110 |
| **F: Tas ×3 head + Tasmanian-bank kNN (ω .5) inside Tasmania** | **94.5** | **86.9** | **−100 / +102** |

Reading: it is the HEAD side, not the prior — the 19k extra classes cost ~0.5
pt (v2 vs v2 on the 2,675) and the missing dense Tasmanian photo bank ~0.7
pt; the Tasmanian prior does not help the v2 head (it was tuned with its own
head). Only 41k of the 598k training photos were taken in Tasmania. A kNN
term over the Tasmanian bank, used where that bank is dense (the Tasmania
box), plus Tasmanian photos ×3 in training closes the gap (94.5 vs 94.6,
paired −100 / +102); the ×3 weighting leaves the mainland unchanged
(AU-test 78.1 / 92.7, C-euc 55.4, C-main 77.7). That keeps the 85 MB int8
bank in the pack but drops the separate Tasmanian head, prior and the hybrid.

**National ALA prior (estimate, not pulled):** the biocache facet query of
build_records.py nationally (ABSENT, generalised/sensitive, uncertainty > 1 km,
fossils out; AU box), 20 species measured: median 0.8 s, max 2.2 s per
species, responses up to 3.4 MB → 22,122 species ≈ 11 h at 1 request/s, ~4 h
with 3 workers (build_records' setting), a few GB of JSON. ALA holds 16.6 ×
iNat's research-grade AU records for 10 random natives (11,445 vs 688) and
3.5 × for the 10 most recorded — far more for exactly the rare species. In
Tasmania the ALA lift alone gave +0.6 pt natural / +1.4 per species; its
effect on AU-test / C-euc is not measured (expected largest for tail species
and eucalypts — an expectation, not a result).

**Ladder:** the val → test gap in "stated but wrong" (val 6.5 %, test 8.7 – 13.3
% per species at 0.55) is a class-mix gap: per-species val classes are 76 %
well-photographed (50–100 photos) vs 52 % on AU-test and 32 % over all
species with an AU record, and stated-wrong on val is 23 % / 7.6 % / 4.6 % for
classes with 1–9 / 10–49 / 50–100 photos. Re-weighting val to the label-free
mix of all species with an AU record gives species 0.80 / genus 0.55: test
stated-wrong per species 3.6 % (AU-test), 4.3 (C-main), 3.0 (C-euc), 6.5 (A),
but species answers fall (AU-test 80 → 66 % per species; the rest mostly
become genus answers, 2–4 % of them wrong). A threshold per training-count
bucket of the NAMED class would keep more species answers — not built.

**Error analysis** (`error_sheets.py`; sheets `australia/v2/errors/sheet-*.png`,
cases in `cases.json`; looked at one by one). 74 "wrong but sure" (p ≥ 0.80,
wrong species; AU-test 30 incl. 10 eucalypts, C-main 15, C-euc 9 = all of
them, A 20): close congener the photo does show (c) 20; not identifiable from
this photo — bark, distant canopy, sterile sprig (b) 17 (9 of the 19
eucalypts); true species has 0–9 training photos (g) 18; truth not in the
label set — Tasmanian garden weeds / hybrids / mosses (f) 7 (all A); photo
problem — habitat scene, far-off plant, the plant isn't the subject (e) 6;
prior flipped a right image answer (d) 4; label looks wrong (a) 2. Across
categories 19 / 74 were PRIOR-INFLATED: the image alone said < 0.5, the prior
lifted a wrong, locally common congener to ≥ 0.8 (e.g. #47 E. exilis →
gittinsii 0.12 → 0.82; #33 Grevillea tetragonoloba → hookeriana 0.42 →
0.82). 30 of Tasmania's 173 lost photos: close congeners (c) 17 (orchids
Thelymitra / Caladenia / Prasophyllum / Corunastylis, Leptecophylla,
Westringia, Pomaderris …), prior flips (d) 5, not identifiable (b) 4, photo
problems (e) 2, label (a) 1, other 1; 17 of the 30 were low-confidence
(p < 0.55, i.e. not stated as species anyway).
Implications: (g) more photos for tail classes + a stricter species threshold
for named classes with few photos; (b)/(c) UX: when the top answers share a
genus and are close, show the genus plus the 2–3 candidates instead of one
species; (d)/prior inflation: don't let the prior alone create confidence —
e.g. state a species only if the image-only p of that species is ≥ ~0.3, or
temper λ for classes the image doesn't support; (e) photo guidance ("the
flower or leaves, close"); (f) the planned cultivated/weed data; (a) nothing.
Examples: `errors/sheet-05.png` #47 (prior-inflated tail eucalypt),
`sheet-03.png` #25 (ironbark bark only), `sheet-00.png` #7 (orchid photo shows
its host tree), `sheet-07.png` #61 (arum lilies in a paperbark scene),
`sheet-08.png` #65 (prior flips a right Ranunculus), `sheet-09.png` #78
(Corunastylis congeners, Tasmania lost).

### Single model (v2): ladder v3 and the final-run recipe (2026-11-05)

**Ladder v3** (`ladder_v3.py`, AU-val re-weighted to the label-free mix of all
species with an Australian record): species threshold per training-count
bucket of the NAMED class, chosen greedily to ≤ 7 % stated-wrong per species
→ 0.50 (0 photos), 0.50 (1–9), 0.65 (10–49), 0.85 (50+); image-only support
floor f searched over {0 … 0.4} → **0** (no gain on val); close-congener rule
(genus + top-3 when the top two share a genus and p2 ≥ r·p1) → **r 0.3**; genus
threshold 0.60. The wrong confident answers mostly NAME a well-photographed
class (rare truths are named as common congeners), hence the high threshold
for the 50+ bucket. Test, per species (natural mix in the last column):

| set | ladder | species | species right | stated wrong | genus (wrong) | not sure | natural: species / stated wrong |
|---|---|---|---|---|---|---|---|
| A-test | v3 | 73.1 | 66.7 | 6.3 | 17.5 (3.6) | 9.4 | 83.5 / 1.6 |
| A-test | 0.80/0.55 | 74.1 | 67.5 | 6.5 | 17.2 (3.5) | 8.7 | 85.0 / 1.7 |
| C-main | v3 | 67.1 | 62.9 | 4.2 | 22.0 (1.9) | 10.9 | 79.8 / 0.9 |
| C-main | 0.80/0.55 | 65.7 | 61.4 | 4.3 | 24.8 (2.2) | 9.5 | 81.2 / 1.2 |
| C-euc | v3 | 36.1 | 33.1 | 3.0 | 58.3 (1.5) | 5.6 | 41.8 / 0.5 |
| C-euc | 0.80/0.55 | 33.9 | 30.9 | 3.0 | 61.7 (2.0) | 4.4 | 45.7 / 0.5 |
| AU-test | v3 | 68.3 | 64.3 | 3.9 | 21.0 (1.5) | 10.7 | 82.3 / 1.1 |
| AU-test | 0.80/0.55 | 66.0 | 62.4 | 3.6 | 24.7 (2.1) | 9.3 | 84.2 / 1.3 |
| AU-test euc | v3 | 37.0 | 33.5 | 3.5 | 56.3 (1.7) | 6.7 | 46.7 / 2.3 |
| AU-test euc | 0.80/0.55 | 33.2 | 30.4 | 2.8 | 61.9 (2.6) | 4.9 | 51.2 / 2.2 |

**Final run** (waiting for the extras' embeddings; nothing run yet):

```bash
X=pipeline/cache/plantid/extra; D=pipeline/cache/plantid/australia/v2/data-final.npz
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch \
   --with numpy<2.3 --with scipy --with pyarrow --with pillow --with duckdb --with matplotlib python3 -I"
V2DATA=$D $E pipeline/plantid/train_v2.py data --extra $X/extra_photos.parquet \
    --extra-emb <dir of the extras' shard-*.npz> --reassign $X/reassign_train.parquet
V2DATA=$D $E pipeline/plantid/train_v2.py local \
    '{"name": "final-v3", "tau": 1.0, "wd": 0.01, "epochs": 12, "tas_weight": 3.0}'
V2DATA=$D FINAL=final-v3 $E pipeline/plantid/eval_v2.py      # all report sets
V2DATA=$D $E pipeline/plantid/tas_gap.py final-v3            # A: D5 = without, F4 = with the Tasmania-box bank kNN
V2DATA=$D $E pipeline/plantid/ladder_v3.py final-v3
```

Recipe = v2fix (text init s0 50, logit-adjusted CE τ 1, AdamW lr 1e-3, decay to
the text init 0.01, 12-epoch cosine, per-species early stopping) + Tasmanian
photos ×3 + the 260,501 extras (`add_extra`: any CC licence, de-duplicated
against training by photo id, Tasmania flag from lat/lon, embeddings looked up
by photo id under `--extra-emb`) + the 81 reassignments + the 19 class merges
(applied in `data`). Training time, measured on the current 598k photos: 87 s
per epoch on the M4 (MPS, 1,045 s for 12 epochs incl. val); with the extras
(×1.44 photos) ≈ 25 min locally — local, no cloud needed (L4: 10.3 s/epoch
measured → ~3 min, but boot + a 1.9 GB upload cost more than they save).

**Prior from any occurrence table** (`prior_v2.py build [--counts T.parquet[:w]
…] --name N`): tables of (lat, lon or cy, cx, u, n) summed onto the 0.05°
grid, written raw (√ applied at scoring); `V2PRIOR=…/prior-N.bin` switches
eval_v2 / ladder_v3 / tas_gap to it. The default (iNat) rebuild is identical
to `ship/au-prior.bin` (rowptr, classes and counts checked). An ALA pull
(build_records' facet method, nationally) would write (lat, lon, u, n) rows.

### Imbalance ablation (uncapped direction; bound written before launch, 2026-11-05)

Data: current 598k + the 250,411 capped extras (`extra_photos_final.parquet`,
`--reassign`, 19 merges) = 848,526 photos over 16,909 classes
(`v2/data-extras.npz`, 1.84 GB) — more skewed than the cap-100 set. Grid
(`train_v2.grid_imbalance`, 10 configs × seeds 0 and 1 = 20 runs, 12-epoch
cosine, v2fix otherwise): (i) balanced softmax + uniform sampling; (ii) BS with
log π from the data + class-balanced sampling (50 / class / epoch, with
replacement — the double correction); (iii) BS + √n class sampling (log π from
the sampler); (iv) plain CE + loss weights 1/n; (v) CE + 1/√n; (vi) plain CE
(+ post-hoc logit adjustment τ' chosen on val at evaluation); (vii) BS τ 0.5 and
1.5; (viii) (i) with the no-extras step budget (292 steps/epoch); (ix) (i)
without the extras. Bound: one SPOT L4, 10.3 s/epoch per 598k photos measured
→ ~14.6 s/epoch here, ~3.2 min per run (2.1 for viii/ix) → ~60 min + ~10 min
boot/data ≈ 1.2 h ≈ $0.6 VM + ~$0.1 egress (20 heads) ≈ **$0.75**; cap
`--max-run-duration=3h` (≤ $1.6). Evaluated locally as each head lands
(`eval_v2.py` light mode + ECE).

**Imbalance ablation — results** (one SPOT L4 us-east1-c, 01:34–03:00 UTC,
20 runs × 172 s = 14.4 s/epoch for 848k photos measured, ≈ $0.75; VM and disk
deleted). Evaluated with the leak-free prior (iNat pool + ALA − iNat +
generalised), T and prior weight re-fitted per run on val; mean ± half-range
over seeds 0 / 1; `_sp` per species, `_w` natural mix; b19 = AU-test classes
with 1–9 training photos IN THAT RUN'S DATA (so ix's bucket holds different
classes); ECE on AU-test (%):

| run (seeds) | val_sp | AU_sp | AU_w | AU_top5_sp | A_sp | A_w | Ceuc_sp | Ceuc_top5 | b19_sp | b19_w | ece_sp | ece_w |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g-i-bs-uniform (2) | 89.2 ± 0.0 | 82.7 ± 0.0 | 92.7 ± 0.0 | 94.5 ± 0.1 | 87.9 ± 0.1 | 94.1 ± 0.0 | 60.1 ± 0.8 | 86.9 ± 0.2 | 55.6 ± 0.5 | 60.0 ± 0.1 | 1.4 ± 0.1 | 1.5 ± 0.0 |
| g-ii-bs-classbalanced (2) | 89.1 ± 0.2 | 83.4 ± 0.3 | 92.5 ± 0.0 | 95.0 ± 0.2 | 88.5 ± 0.3 | 94.1 ± 0.1 | 63.1 ± 0.6 | 87.0 ± 0.2 | 63.4 ± 0.4 | 67.5 ± 0.7 | 1.5 ± 0.3 | 1.4 ± 0.2 |
| g-iii-bs-sqrt (2) | 89.0 ± 0.0 | 82.2 ± 0.3 | 92.7 ± 0.0 | 94.3 ± 0.2 | 87.8 ± 0.6 | 94.1 ± 0.1 | 61.4 ± 0.8 | 86.7 ± 0.4 | 54.5 ± 1.2 | 59.0 ± 0.9 | 1.9 ± 0.3 | 1.4 ± 0.3 |
| g-iv-ce-iw1 (2) | 89.0 ± 0.0 | 81.9 ± 0.0 | 92.8 ± 0.0 | 93.7 ± 0.0 | 87.7 ± 0.0 | 94.2 ± 0.0 | 59.0 ± 0.5 | 86.2 ± 0.1 | 51.3 ± 0.3 | 55.9 ± 0.2 | 1.8 ± 0.0 | 1.6 ± 0.0 |
| g-ix-no-extras (2) | 88.8 ± 0.0 | 81.2 ± 0.1 | 92.8 ± 0.1 | 94.1 ± 0.0 | 87.5 ± 0.0 | 94.0 ± 0.2 | 57.1 ± 0.3 | 83.7 ± 0.4 | 59.7 ± 0.3 | 63.5 ± 0.3 | 1.6 ± 0.1 | 1.7 ± 0.1 |
| g-v-ce-iw0.5 (2) | 88.9 ± 0.0 | 81.7 ± 0.2 | 92.8 ± 0.0 | 93.6 ± 0.2 | 87.6 ± 0.5 | 94.2 ± 0.1 | 58.0 ± 0.6 | 86.1 ± 0.2 | 46.1 ± 1.0 | 51.6 ± 1.2 | 2.2 ± 0.1 | 1.4 ± 0.1 |
| g-vi-ce-plain (2) | 88.8 ± 0.0 | 81.1 ± 0.3 | 92.5 ± 0.1 | 93.1 ± 0.2 | 87.3 ± 0.1 | 93.9 ± 0.1 | 57.9 ± 1.2 | 85.6 ± 0.1 | 42.5 ± 0.3 | 45.3 ± 0.4 | 1.9 ± 0.1 | 1.8 ± 0.2 |
| g-vi-ce-plain-posthoc1 (2) | 89.2 ± 0.0 | 82.7 ± 0.0 | 92.7 ± 0.0 | 94.3 ± 0.0 | 87.9 ± 0.0 | 94.1 ± 0.0 | 60.0 ± 0.7 | 86.8 ± 0.1 | 56.1 ± 0.5 | 60.6 ± 0.1 | 1.5 ± 0.0 | 1.4 ± 0.0 |
| g-vii-bs-tau0.5 (2) | 89.0 ± 0.0 | 81.9 ± 0.0 | 92.7 ± 0.0 | 94.2 ± 0.0 | 87.6 ± 0.1 | 94.1 ± 0.1 | 58.1 ± 0.6 | 86.1 ± 0.0 | 49.0 ± 0.5 | 53.9 ± 0.7 | 2.3 ± 0.3 | 1.3 ± 0.2 |
| g-vii-bs-tau1.5 (2) | 89.2 ± 0.1 | 83.2 ± 0.0 | 92.5 ± 0.1 | 94.8 ± 0.0 | 88.0 ± 0.0 | 94.1 ± 0.1 | 61.5 ± 0.6 | 86.7 ± 0.0 | 61.5 ± 0.3 | 65.5 ± 0.3 | 1.2 ± 0.1 | 1.7 ± 0.0 |
| g-viii-bs-budget292 (2) | 89.4 ± 0.0 | 82.9 ± 0.1 | 92.9 ± 0.1 | 94.9 ± 0.1 | 88.3 ± 0.0 | 94.2 ± 0.1 | 61.9 ± 0.5 | 87.1 ± 1.0 | 57.9 ± 0.0 | 61.8 ± 0.1 | 1.4 ± 0.4 | 1.6 ± 0.3 |

**This grid table is TEST-INFORMED** (it reads the report sets for every
strategy) — it is exploration, not a selection. The final strategy is chosen
on val re-weighted to the label-free all-AU-species class mix (below), with 3
seeds; the test sets are read once afterwards.

- **Per species, the strongest tail correction wins**: balanced softmax with
  log π from the data PLUS class-balanced sampling (ii — the "double
  correction" of Ren et al. 2020) gives the best AU-test (83.4 vs 82.7), C-euc
  (63.1 vs 60.1) and 1–9-photo bucket (63.4 vs 55.6), A 88.5 vs 87.9, for −0.2
  pt natural mix and equal ECE; τ 1.5 points the same way (83.2 / 61.5 / 61.5).
  The "over-correction" is what a per-species objective wants. Val (unweighted
  per species, 76 % well-photographed classes) does not separate them (89.1 vs
  89.2) — the tail is under-represented on val, as in the ladder analysis.
- **Extras help**: i vs ix (same recipe, without the 250k extras): AU-test
  82.7 vs 81.2 per species, C-euc 60.1 vs 57.1 (top-5 86.9 vs 83.7), A 87.9 vs
  87.5; natural mix unchanged (92.7 vs 92.8).
- Frequent classes don't eat the step budget harmfully: viii (the no-extras
  step budget, 70 % of the steps) ties or slightly beats i (82.9 vs 82.7).
- Plain CE + post-hoc logit adjustment (τ' 1 on val) = balanced softmax
  (82.7); importance weights (1/n 81.9, 1/√n 81.7), √n sampling (82.2), τ 0.5
  (81.9) and plain CE (81.1; 1–9 bucket 42.5) are worse per species.

**Why a stronger-than-balanced correction can help (theory note).** Balanced
softmax (log π_y added to the logits during training) is the Bayes-correct
adjustment if the head learned p(x | y) equally well for every class; then
removing log π gives the class-balanced posterior. With finite samples it
doesn't: a class with n photos gets O(n) gradient signal, so its weight
vector stays shrunk toward its initialisation (here the text vector, with
decay) and its logits are systematically under-confident relative to
well-photographed classes — the estimation error is not symmetric across
classes (the "minority collapse"/norm-shrinkage effect seen in long-tailed
learning: rare-class weight norms are smaller). Balanced softmax corrects the
prior shift but not this variance-driven shrinkage; an extra correction — more
weight on rare classes via class-balanced sampling with log π from the data,
or τ > 1 — partly compensates, at the price of more false rare answers on the
natural mix. How much extra correction is right depends on the shrinkage,
i.e. on n, which is why it has to be tuned on a tail-representative objective
(the re-weighted val), not assumed.

**Deciding comparison** (bound before launch: 6 new runs — seed 2 of (i), (ii),
τ 1.5 and seeds 0–2 of (ii) + τ 1.5 — ≈ 20 min of L4 + boot ≈ 45 min ≈ $0.4,
cap 2 h; evaluated with the exact leak-free eval prior; objective = AU-val per
species re-weighted to the all-AU-species training-count mix).

**Decision on the re-weighted val** (AU-val per species, classes re-weighted to
the all-AU-species training-count mix; exact leak-free eval prior; 3 seeds,
mean ± half-range; no test set read for this):

| strategy | val re-weighted top-1 | top-5 | val 1–9-photo classes |
|---|---|---|---|
| (i) BS + uniform | 76.5 ± 0.5 | 91.1 ± 0.9 | 55.6 ± 2.0 |
| (ii) BS (data π) + class-balanced | 78.4 ± 0.5 | 93.3 ± 0.3 | 62.7 ± 1.8 |
| BS τ 1.5 | 77.8 ± 0.4 | 92.4 ± 0.2 | 59.9 ± 1.4 |
| (ii) + τ 1.5 | **79.3 ± 0.2** | **93.4 ± 0.3** | **65.0 ± 1.6** |

Further rows requested (bound before launch: focal γ 1 / 2 on (i) and (ii),
LDAM margins ∝ n^-1/4 with BS — 5 configs × 3 seeds = 15 runs ≈ 51 min of L4
+ boot ≈ 1.2 h ≈ $0.6, cap 2.5 h; τ-normalisation of (i)'s class weights is
post hoc, local): see below.

**Class-weight norms by training-photo bucket** (mean ‖W_c‖ over 3 seeds;
photo-less classes stay at the text init, s0 = 50; bias b_c in logits):

| run | 0 | 1–9 | 10–49 | 50+ | bias 1–9 / 50+ |
|---|---|---|---|---|---|
| (i) BS + uniform | 50.0 | 62.5 | 68.5 | 72.1 | +0.14 / −0.13 |
| (ii) BS + class-balanced | 50.0 | 61.6 | 68.7 | 70.5 | +0.24 / −0.22 |
| BS τ 1.5 | 50.0 | 63.5 | 68.9 | 71.9 | +0.25 / −0.18 |
| (ii) + τ 1.5 | 50.0 | 62.6 | 68.9 | 70.1 | +0.35 / −0.30 |

Under (i) rare classes DO have shorter weight vectors (62.5 vs 72.1) — the
finite-sample shrinkage is there. But the stronger corrections do not close
that norm gap; they shrink the frequent classes' norms a little (72 → 70) and
mostly move the per-class BIAS toward rare classes. So the evidence supports
"rare classes are under-scored after balanced softmax" but not "the fix acts
by equalising norms"; τ-normalisation (Kang et al. 2020) tests the norm route
directly (below).

**Further rows on the re-weighted val** (3 seeds each; no test read):

| strategy | val re-weighted top-1 | top-5 | 1–9-photo classes |
|---|---|---|---|
| BS + focal γ 1 / γ 2 | 75.6 ± 1.0 / 75.9 ± 0.9 | 91.0 / 91.3 | 52.7 / 54.1 |
| (ii) + focal γ 1 / γ 2 | 77.4 ± 0.1 / 77.2 ± 0.9 | 92.9 / 92.6 | 59.3 / 58.3 |
| BS + LDAM (n^-1/4, max margin 0.3·s0) | 77.2 ± 0.2 | 89.9 | 56.1 |
| (i) + τ-norm 0.25 / 0.5 / 1.0 (post hoc, scale kept) | 78.0 / 78.5 / 78.8 | 91.6 / 92.4 / 91.7 | 58.3 / 59.8 / 62.7 |
| (ii) + τ 1.5 + τ-norm 0.5 | **81.0 ± 0.9** | **93.9 ± 0.5** | 71.6 ± 5.1 |
| (ii) + τ 1.5 + τ-norm 1.0 | 80.5 ± 0.7 | 93.3 | 73.8 |

τ-norm is the Kang et al. (2020) re-scaling W_c ← W_c (mean‖W‖ / ‖W_c‖)^τ,
here keeping the mean norm so the image logits stay on the scale the prior
weight was tuned for (the unscaled form W_c / ‖W_c‖^τ shrinks every logit
and lets the prior take over — it collapsed for τ ≥ 0.5). Equalising norms
post hoc helps (i) (+2.3) and ADDS to the bias route of (ii) + τ 1.5 (+1.7):
consistent with the finite-sample-shrinkage reading — the shorter rare-class
norms cost accuracy, and training-time corrections fix it only partly. Focal
loss doesn't help here; LDAM helps top-1 a little but costs top-5.

**Chosen on the re-weighted val: (ii) + τ 1.5 + τ-norm 0.5** (BS with log π
from the data, class-balanced sampling, τ 1.5, scale-kept τ-norm 0.5 post hoc).
**Test, read once** (3 seeds; exact leak-free prior; per species / natural):

| | val rw | AU-test | AU top-5 sp | A | C-main | C-euc top-1 / top-5 | AU euc top-1 / top-5 | 1–9 bucket | ECE sp / nat |
|---|---|---|---|---|---|---|---|---|---|
| (i) BS + uniform | 76.5 | 82.9 / 92.8 | 94.7 | 88.1 / 94.2 | 82.0 | 58.8 / 87.5 | 62.9 / 87.2 | 56.1 | 1.5 / 1.6 |
| **chosen** | **81.0** | **83.2** / 92.4 | 94.8 | 88.1 / 94.0 | **82.6** | **61.5** / 86.1 | 62.4 / 87.2 | **71.6** | 1.4 / 1.3 |

The val gain shows up on test where the tail is: classes with 1–9 training
photos 56 → 72 %, C-euc +2.7; elsewhere it is ±0.5 (AU-test per species +0.3,
natural −0.4, C-euc top-5 −1.4) — AU-test's own class mix is far less
tail-heavy than "all species".

### Location prior from ALA (2026-11-05)

ALA occurrence counts (`sources/ala_counts/`, 20.2M records, 19,484 labels;
filters as build_records.py) via `prior_v2.py`. **Leak:** ALA contains 3.35M
iNaturalist-Australia records (dr1411), including the val/test observations
themselves, so a raw ALA prior "knows" the test photo's own record — raw ALA
gave AU-test 82.9 per species and A 89.7 / 95.0, which are NOT valid. Leak-free
variants (v2fix head, everything tuned on val; per species / natural):

| prior | val sp | A | C-main | C-euc top-1 / top-5 | AU-test | AU-test euc top-1 / top-5 | 1–9 bucket |
|---|---|---|---|---|---|---|---|
| iNat pool √counts (v2) | 0.882 | 85.3 / 93.4 | 77.4 | 56.1 / 80.4 | 78.2 / 92.7 | 58.0 / 81.7 | 49.9 |
| ALA − all iNat records (subtracted per cell × class) | 0.874 | 87.0 / 93.4 | 78.2 | 55.7 / 82.0 | 79.7 / 91.8 | 57.3 / 82.0 | 56.3 |
| … + ALA generalised (2,498 labels without precise records) | 0.877 | 86.2 / 93.3 | 79.3 | 56.3 / 81.9 | 79.8 / 92.0 | 57.1 / 81.6 | 58.9 |
| **iNat pool + ALA − iNat + generalised** | **0.887** | 86.8 / **94.0** | **80.5** | 56.9 / 82.0 | **80.9 / 92.6** | **59.6 / 82.2** | **59.9** |

(√counts, σ 5 km, α 64, λ 1.0 chosen on val; ECE 1.5 % natural / 1.8 % per
species.) The generalised table only covers labels without precise records,
so "all labels" and "only those" are the same. The subtraction leaves ALA's
iNat records that are not in our snapshot (~0.5M: ARR photos, newer); the
exact fix — a re-pull with `-dataResourceUid:dr1411` — is the evaluation
prior once it lands, the subtraction stays as a cross-check.
Exact fix, landed: ALA re-pulled with `-data_resource_uid:dr1411`
(16.88M records): **iNat pool + ALA(no iNat) + generalised(no iNat)** → val
0.885 (√, σ 10 km, α 64, λ 0.75; σ 5 / λ 1 scores 0.884 — a tie), A 87.0 /
93.5, C-main 80.7, C-euc 55.7 / 82.4, AU-test 80.9 / 92.5, AU-test eucalypts
58.6 / 83.0, 1–9 bucket 58.2, ECE 1.1 % natural / 2.5 % per species — the
subtraction version agrees within noise (80.9 / 80.9 on AU-test, ±1.7 pt on
the smaller sets). Builds: `prior-eval-inatpool+ala-noinat.bin` (evaluation),
`prior-ship-inatall+ala-noinat.bin` (19.8M records, 5.58M cell × class pairs,
24.8 MB — the shipped one, see below).
**Shipped prior** (decided): built from ALL data — iNat records of every
observer + ALA without dr1411 (= de-duplicated against iNat) + generalised —
with the parameters chosen on the leak-free val (leakage only matters for
measuring). Both builds are recorded in provenance (`prior_v2.py` steps).

### Final training at full scale (plan; measured basis)

Expected data: ~3.4M photos (K = 1,000 uncapped iNat set 3.15M + ALA field
photos + Commons) → `v2/data-final.npz` ≈ 7 GB (fp16) + val arrays.
Measured: 14.4 s per epoch for 848,526 photos on one L4 (imbalance grid,
2026-11-05) → **~58 s/epoch → 12 epochs ≈ 12 min** on the L4; the M4 (MPS,
87 s per 598k-photo epoch) would need ~8 min/epoch ≈ 1.7 h — so the L4.
Memory: 3.4M × 1,024 fp16 = 7 GB fits the L4's 24 GB (`V2_GPU_BYTES` default 8 GB
keeps it on the GPU; larger sets stream batches from RAM automatically); the
g2-standard-8 has 32 GB RAM for the npz. Overheads measured this week: VM
boot + uv env 5–25 min (PyPI speed varies), laptop → GCS upload ~12 MB/s
(7 GB ≈ 10 min). Bound per final run ≈ 0.75 h ≈ $0.4; a 2-seed final + the
with/without-bank comparison ≈ $1. Sampling: uniform over ALL photos +
balanced softmax (see the imbalance ablation), no dataset cap.

### Rebuild (provenance; CLAUDE.md "Plant-ID provenance")

Every v2 step (`train_v2.py data / local`, `prior_v2.py`, `eval_v2.py`,
`ladder_v3.py`) appends a line to `australia/v2/provenance-steps.jsonl`: argv,
env (V2DATA / V2PRIOR / FINAL), git commit of pipeline/plantid and whether it
was clean (a dirty tree prints a warning — commit before the output ships),
torch/numpy versions, device, the chosen parameters, sha256 of inputs and
outputs. `provenance.py section` turns the log into `provenance.json` (git,
steps, iNat open-data snapshot files, BioCLIP revision, input hashes + GCS
paths, embedding prefixes, seeds, determinism note); `provenance.py ship`
merges it into `ship/pipeline.json` as `provenance`. Start each release with a
fresh log (`mv provenance-steps.jsonl provenance-steps-<date>.jsonl`).

Determinism: training seeds torch (cfg seed 0) and numpy (data fractions);
the val subsets are sha256(observer) hashes. Two identical 1-epoch runs gave
bit-identical weights on MPS and on CPU (torch 2.7, measured 2026-11-05);
MPS, CPU and CUDA differ from each other in float reduction order, so rebuild
on the device recorded in the step.

From GCS (`gs://leo-superresolution-izzy-plantid/au`, content-addressed small
inputs under `inputs/<sha256>/<name>`, listed in `australia/v2/inputs-gcs.json`
and the `provenance` section):

```bash
B=gs://leo-superresolution-izzy-plantid/au; C=pipeline/cache/plantid
gcloud storage rsync $B/emb  $C/australia/train/emb          # 590,824 photos (2026-11-04 run)
gcloud storage rsync $B/emb0 $C/emb/bioclip25                # 92,006 photos (2026-11-01 run)
# + the extras' shards (their GCS prefix is recorded as extra_emb in the data step)
# inputs: copy each inputs/<sha>/<name> to its path (provenance.INPUTS maps name → path)
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch \
   --with numpy<2.3 --with scipy --with pyarrow --with pillow --with duckdb --with matplotlib python3 -I"
D=$C/australia/v2/data-final.npz
V2DATA=$D $E pipeline/plantid/train_v2.py data --extra $C/extra/extra_photos.parquet \
    --extra-emb <extras dir> --reassign $C/extra/reassign_train.parquet
$E pipeline/plantid/prior_v2.py build [--counts …]           # iNat default = ship/au-prior.bin
V2DATA=$D $E pipeline/plantid/train_v2.py local '{"name": "final-v3", "tau": 1.0, "wd": 0.01, "epochs": 12, "tas_weight": 3.0}'
V2DATA=$D FINAL=final-v3 $E pipeline/plantid/eval_v2.py
V2DATA=$D $E pipeline/plantid/ladder_v3.py final-v3
$E pipeline/plantid/provenance.py section    # then, when the v2 files are staged: provenance.py ship
```

The exact argv of the shipped build is in `provenance.steps`; the command list
above is the template. Ship step: `V2DATA=$D $E pipeline/plantid/build_ship.py v3`
(records "v3 ship", runs `provenance.py section` + `ship`, writes the `model`
identity into pipeline.json; see "Final configuration (v3): shipping" below;
the heads come from `head_capacity.py vm`, gs://…/au/hc/runs/).

### Single model (v2): shipping (2026-11-05)

`build_ship.py v2` writes the pack files from run `final-cb50-s1` with every
parameter read from the evaluation outputs (asserted to name the same run):
τ-norm 0.5 baked into the weights, int8 rows × per-row scale + fp32 bias (the
19 merged twins at −1e4), prior = `prior-ship-inatall+ala-noinat.bin` with
log1p counts, σ 10 km, α 64, λ 1.0, T 1.532 (eval.json — NB the README's
v2fix rows used √counts / λ 0.75; the final run's sweep chose log1p / λ 1.0);
inside the Tasmania box tas_gap F5: the Tasmanian bank's kNN, ω 2.0, floor −30,
and the prior re-tuned (√counts, σ 5 km, α 16, λ 1.0); ladder v3 species 0.60 /
0.50 / 0.50 / 0.75 by training-photo bucket of the named class, genus 0.55,
floor 0, congener rule off. No location = K 0 (the country-wide frequency).
Check of the WRITTEN files with the leak-free eval prior (`v2-check.json`):
A-test natural top-1 93.16 main path (eval 93.18) / 94.80 with the box (tas_gap
F5 94.79); int8 vs fp32 head top-1 agreement 99.8 %. Not re-tuned: the ladder
inside the box (stated-wrong natural 3.0 % vs 2.5 % main on A-test).
Pack 0.81 GB (encoder 0.63, bank 85 MB, head 23 MB, prior 25 MB, labels 2.8 MB,
credits 13 MB + 29 MB per-photo list for 3,897,289 photos by 179,651 creators).

### Final configuration (v3): shipping (2026-11-06)

`build_ship.py v3` (eval env, `V2DATA=…/data-final.npz`) ships the final
sweep's choice `mpA01|adaptive|box` with every number read from
`final_sweep/{refine,calib,test}.json` (asserted consistent): the MEAN of the
two multi-prototype heads `hc-mpAc-s0` / `-s1` (head_capacity.py mproto:
K_c = 1 / 2 / 4 / 8 prototypes at 0 / 50 / 150 / 300 training photos,
57,703 rows each; class score T·(logsumexp(z/T) − log K_c), T 4.19 / 4.20
learned; scale-kept τ-norm 0.5 on the per-class mean prototype norm, baked
in; int8 per prototype row, float32 scale), image temperature 0.8, the
adaptive prior (log1p, s0 14 km, γ 0.25, σ 2–20 km in 3 steps per octave,
σ_ρ 5 km, α 32) at λ 1 everywhere — no separate Tasmania-box prior — and
inside the box the Tasmanian bank at ω 3 with a SOFT floor −1.5 (every
non-bank class sits 4.5 nats below a bank class the photo resembles); T 1.91;
ladder species 0.50 / 0.50 / 0.50 / 0.75 by bucket, genus 0.50, no image
floor, congener rule off. No location: K = 0 (the country-wide frequency), no
bank — `V3_NO_LOCATION` / `scoring.no_location` = "tasmania" flips that. The
σ raster (690 × 850 uint8 codes, one per 0.05° cell) is computed from the
SHIPPED counts (ρ0 1.108 rec/km²; the eval counts give the same code on
95.6 % of record cells). v2-labels.json, bank-int8.bin and the credits are
unchanged (same classes, merges and training photos — asserted).

Check of the WRITTEN files (`v3-check.json`; leak-free eval counts with their
own σ raster, as the sweep scored): A-test top-1 per species 89.24 (sweep
89.23), natural 94.82 (94.78), ladder species 85.69 / stated-wrong 8.80
(85.67 / 8.80); AU-test per species 85.68 (85.69), natural 93.16 (93.15),
re-weighted 82.33 (82.35), ladder species 81.24 / wrong 4.97 (81.25 / 4.99);
int8 vs the fp32 heads top-1 agreement 99.85 %, max |Δ logit| 0.09. Note:
the ladder's genus sums use v2-labels' genus names (2,614 genera) as v2 did;
the sweep grouped by bank_analysis' table (2,610: e.g. Callistemon in
Melaleuca) — the genus rates above still match within 0.01 pp. Pack 0.84 GB
(head 119 MB, prior 26 MB; the rest as v2).

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
