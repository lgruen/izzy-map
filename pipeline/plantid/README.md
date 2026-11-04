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
