# Plant-ID evaluation (photo → species, with a location prior)

Question: how well can an open model (BioCLIP / BioCLIP 2) running on the
phone name Tasmanian plants from a photo, and how much do training photos and
a location prior help? Nothing here ships in the app; it produces numbers to
decide on.

## Run order

```bash
pipeline/plantid/fetch_meta.sh                       # ~35 GB, ~35 min
uv run --with duckdb --with pyarrow python3 pipeline/plantid/pick_sets.py \
    --un-plants <plants.json from the Plants branch>
uv run --with duckdb python3 pipeline/plantid/fetch_photos.py --workers 48
E="uv run --with torch --with torchvision --with open_clip_torch --with pyarrow --with pillow --with numpy"
$E python3 pipeline/plantid/embed.py --model bioclip
$E python3 pipeline/plantid/embed.py --model bioclip2
uv run --with torch --with numpy --with scipy --with pyarrow \
    python3 pipeline/plantid/evaluate.py      # → cache/plantid/report/report.md
```

Every step is resumable (DuckDB stages are cached in `sets/work.duckdb`,
photos and embedding shards are skipped when present). Get the UN list with
`git show worktree-understorey:app/src/generated/plants.json > /tmp/plants.json`.

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

`probe/plantid/` (deployed with the app at `/probe/plantid/`) downloads the
image encoder into OPFS, runs it with onnxruntime-web (WebGPU) and compares
its embeddings with the laptop's for three bundled CC0 test photos; the
person running it copies a results text. A memory kill by iOS reloads the
page, which then reports the step it died in.

```bash
uv run --with torch --with torchvision --with open_clip_torch --with onnx \
    --with onnxruntime --with pillow --with numpy --with pyarrow \
    python3 -I pipeline/plantid/export_onnx.py --model bioclip25   # ~20 s
#   (and --model bioclip: the 0.2 GB fallback the page offers)
uv run --with torch --with torchvision --with pillow --with numpy \
    python3 -I pipeline/plantid/check_pilresize.py                # JS resize == Pillow
pipeline/plantid/upload_test.sh                                   # → R2 plantid-test/v1/
```

- Weights: float16, 21 shards ≤ 64 MiB (resumable download, no single 1.3 GB
  buffer during download). Input float32 → cast inside the graph.
- Preprocessing is bit-exact with open_clip (`probe/plantid/pilresize.js`:
  Pillow's bicubic + torchvision's centre crop), and JPEG colour profiles are
  stripped before decoding: Pillow ignores them, Safari would convert Display
  P3 (every iPhone photo) to sRGB — that alone cost 0.02 cosine on a P3 test
  photo and flipped a close call.
- Local run: serve a folder holding `probe/` and `plantid-test/v1/{bioclip25,
  bioclip,ort}` on localhost and open `/probe/plantid/?data=/plantid-test/v1/
  &auto=1`. macOS Safari 27.2 on the M4 (2026-11-02): BioCLIP 2.5 loads in
  1.7 s, 0.45 s per photo, cosine to PyTorch ≥ 0.9992 end to end.

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
