# More training photos from the iNat snapshot + the de-duplication guard (2026-11-05)

Code: `pipeline/plantid/expand_inat.py` (`scan → select → measure → fetch →
evalhash → calibrate → calibrate-emb → dedup`, `noise`; env in its
docstring) and the reusable guard `pipeline/plantid/dedup.py`. Outputs in
`pipeline/cache/plantid/extra/` (gitignored, `pipeline/cache/`). Data prep
only — nothing embedded, trained or shipped; no existing file was changed.
All numbers MEASURED on the M4 unless marked "estimate".

## What goes into the list

Training today = `australia/plan/train.parquet` ∪ the Tasmanian
`sets/train.parquet` (598,129 observations): pool observers only, one
CC0/PD/BY/BY-NC photo per research-grade observation, ≤ 100 per class.
Licence decision (Leo, 2026-11-05): for TRAINING every CC licence is fine
(CC0, BY, BY-NC, BY-SA, BY-NC-SA, BY-ND, BY-NC-ND); all-rights-reserved never
(those photos are not in the open-data bucket at all).

| source | what |
|---|---|
| `inat-extra-photo` | more photos of observations already in training, any CC licence, ≤ 3 photos per observation in all |
| `inat-sa-nd` | research-grade pool observations not in training whose photos are ONLY BY-SA / BY-NC-SA / BY-ND / BY-NC-ND (≤ 3 photos each) |
| `inat-needs-id` | needs_id observations, only classes with < 20 training photos, only observers with a track record (below) |
| `inat-name-map` | research-grade pool observations of an iNat taxon the APC↔iNat name map (`names/apc_inat_map.json`, `notes/name_matching.md`) newly assigns to a photo-less label |
| `inat-rg-unused` | research-grade pool observations with a usable photo the plan skipped although the class is under the cap (its first usable photo was shared with another observation, or the class lost photos to a name-map move); 69 photos |

**Cap, re-thought:** training + extras ≤ 100 photos per class (the plan's
cap), so the 3,892 classes already at 100 gain nothing and rare classes gain
the most. Inside a class the fill is breadth before depth: (1) first photos
of NEW research-grade observations (SA/ND, name map, unused), (2) every
observation's 2nd photo, (3) 3rd photos, (4–6) the same tiers for needs_id;
ties: ≤ 3 observations per (class, observer) first, Australia box first, a
fixed hash. Read differently — the cap counts observations and every one may
bring 3 photos — the extra-photo source alone would be **623,955 photos**,
mostly in classes that already have 100 observations; not done.

**Name map** (coordinator's addition, applied in `taxon_map()`): labels with
relation exact / synonym / orthographic / split take photos from the mapped
iNat taxon ids (species part = the whole species, infraspecific/hybrid part =
only its subtree); `lump` and `none` take none — also through an existing
`inat_map` entry (14 taxa of 12 labels cut); `merge` (14 duplicate classes)
take none (their photos already train the extra class). 400 taxa → 360
labels; 28 infraspecific taxa leave their parent class: **81 current
training photos belong to another label now →
`extra/reassign_train.parquet`** (observation, photo, u_old, u_new; the
trainer should relabel them — the counts below already treat them as moved).
Column `name_relation` records how the photo's class was reached
(`inat_map` = the eval's map, else the name map's relation; `via_name_map`
= the photo reached its label only through the new map).

**Leakage guards:** observer split hash reproduced on all 1,075,829 `who`
observers (asserted) and recomputed for needs_id-only observers; every
evaluation observer (A val/test, C tune/report, plan AU-val ⊃ AU-tune,
AU-test: 4,864 observers) is val/test-role (asserted); 0 list rows from an
evaluation observer or a val/test-role observer (asserted); photos attached
to more than one observation (`shared` + needs_id photos shared with a
research observation) and every evaluation photo id excluded; then the
near-duplicate guard below.

## Result (`extra/extra_photos.parquet`, 260,501 photos, 12,714 classes)

| training photos of the class (au-labels) | classes | gaining | extra-photo | sa-nd | needs-id | name-map | rg-unused | total |
|---|---|---|---|---|---|---|---|---|
| 0 | 6,354 | 1,143 | 100¹ | 1,412 | 4,661 | 9,623 | – | 15,796 |
| 1–9 | 6,532 | 6,210 | 31,733 | 7,027 | 19,901 | – | 6 | 58,667 |
| 10–19 | 1,943 | 1,943 | 35,333 | 7,442 | 14,588 | – | 7 | 57,370 |
| 20–49 | 2,061 | 2,061 | 74,298 | 14,455 | – | – | 4 | 88,757 |
| 50+ | 5,232 | 1,357 | 29,569 | 10,290 | – | – | 52 | 39,911 |
| **all** | 22,122 | 12,714 | 171,033 | 40,626 | 39,150 | 9,623 | 69 | **260,501** |

¹ observations moved into a photo-less infraspecific label by the name map.

- **Photo-less labels: 1,143 gain ≥ 1 photo, 536 gain ≥ 5, 171 gain ≥ 20**
  (265 of them through the name map — the coordinator's ~256).
- Classes with ≥ 5 photos 11,243 → 14,634; ≥ 20: 7,293 → 10,719.
- Licences: BY-NC 179,710, BY-NC-SA 31,548, BY 32,727, BY-SA 8,724,
  BY-NC-ND 2,932, BY-ND 2,608, CC0 2,252. Attribution column ready
  ("© name, CC BY-NC-SA, via iNaturalist").
- Columns: `u` (= au-labels index), `name`, `source`, `photo_id`, `ext`,
  `observation_uuid`, `observer_id`, `login`, `license`, `attribution`,
  `url` (500 px medium in the open-data bucket), `local_path` (null unless
  stored, below), `shard` (null — the embedding run fills it), `grade`,
  `k` (photo's place in its observation), `rk` (fill rank in the class),
  `ntr` (effective training photos of the class), `lat`, `lon`,
  `observed_on`, `n_rg_genus` (needs_id: the observer's research-grade
  observations in the genus), `name_relation`, `via_name_map`, `phash`,
  `dhash`, `bytes`. Dropped rows with reasons: `extra/dropped.parquet`.

## Download

Measured: 500 photos 114.9/s, 2,000 at 134.2/s (48 threads, alone); the
full pass ran at **176/s with 64 threads: 250,037 photos in 23.7 min**
(+ 10,900 after the name map in 1.1 min), 0 missing, mean 125 KB →
**32.8 GB** in total. The disk had 16–34 GB free (shared with other jobs),
and the embedding VM streams the photos from S3 itself, so only the
photo-less classes' photos are STORED (`--keep-below 1`): 15,434 photos,
1.9 GB in `extra/inat/`; everything else was hashed in memory.
`fetch --keep-below N` stores more (resumable; hashes are not redone).

## De-duplication guard (`dedup.py`)

Stage 1, before embedding: pHash (DCT) + dHash (gradient), 64 bit each,
from a JPEG draft decode (~0.4 ms/photo at 8 threads); duplicate = BOTH
distances within thresholds. Calibrated on known duplicates (300 candidate
photos): iNat's own "small" (240 px) and "large" (1024 px) of the same photo
vs the medium, a JPEG q50 re-encode, a 90 % centre crop; negatives 20,000
pairs of two photos of one observation (burst shots) and 20,000 random pairs.

| pair | pHash p50 / p99 / max | dHash p50 / p99 / max |
|---|---|---|
| small vs medium | 0 / 2 / 4 | 0 / 2 / 3 |
| large vs medium | 0 / 2 / 4 | 0 / 2 / 4 |
| q50 vs medium | 0 / 2 / 2 | 0 / 2 / 3 |
| 90 % crop | 10 / 20 / 22 | 11 / 18 / 21 |
| same observation, other photo | 30 / 40 / 48 | 31 / 41 / 51 |
| random | 32 / 40 / 48 | 32 / 42 / 48 |

**Chosen pHash ≤ 8 and dHash ≤ 10** (2× margin over the largest resize
distance): resizes/re-encodes 100 %, crops 16 % (left to stage 2), random
0 of 20,000, same-observation 0.34 % (those are true near-identical
uploads). Applied: **2 candidates were the same photo as an evaluation photo
(dropped)** — a pool account's photo identical to a val/test observer's
eval photo (checked by eye: same image); **790 within the extras** (414
same observation, 376 another observation) + **42 kept copies of
cross-class duplicates** also dropped (by eye: habitat/landscape shots
attached to observations of different species — wrong for at least one).
Duplicates of the EXISTING 598k training photos are not checked here (no
local copies); stage 2 does it from their embeddings. Cost: vs eval 21–70 s
(261k × 85k), within the list 275–353 s, brute force on numpy's native
`bitwise_count`; multi-index hashing was tried and abandoned (pHash bits
are skewed → huge exact-chunk buckets) — for much bigger lists use a native
binary index (faiss) or a within-class pass.

Evaluation photos hashed: 85,361 of 85,362 (A, C, plan eval; 12,361 from
local copies, 73,000 streamed from S3 in 8.8 min, 1 gone) →
`extra/work/hashes-eval-part*.parquet` — reusable by every later source.

Stage 2, after embedding (BioCLIP 2.5 fp16 on MPS, open_clip eval
transform; 60 photos, 360 embeddings, 445 s incl. downloads — slower than
planned): **cosine does NOT separate duplicates from other photos of the
same plant**: the same photo as "small" vs medium scored 0.77–0.996 (median
0.958), q50 0.85–0.99, crop 0.85–0.99, while another photo of the same
observation reached 0.95 (median 0.80) and random pairs ≤ 0.75. The earlier
idea "cos ≥ 0.97 = duplicate" (photo_sources.md) would have missed ~60 % of
resized copies. Two roles instead (`calibration-emb.json`, small sample):
**confirm** a hash hit at cos ≥ 0.85 (≥ 98 % of every duplicate kind, no
random pair); **standalone** cos ≥ 0.95 (no same-observation or random pair
in the sample; catches 70 % of crops, 54 % of small-vs-medium) — use it
against eval embeddings and the existing training photo of the same
observation once the extras are embedded; expect it to also flag some burst
shots. `dedup.emb_near(Q, R, thr)` is the blocked search.

## needs_id: admission rule and label noise

Rule: class has < 20 training photos; observer is pool-role; the observer has
**≥ 5 research-grade observations in the same iNat genus** (any role of
observation, the snapshot's `o` table). The snapshot has no identifications,
so "research grade" stands in for "the community agreed with them".
Admitted: **19,812 of 61,415 needs_id observations** (40,829 by pool
observers) of 4,395 classes by 1,180 observers → 39,150 photos after caps
and dedup.

Noise, measured with the iNat API (today, ~1–2 weeks after the snapshot;
`extra/work/noise.json` (admission set before the name map, same rule),
1,000 random admitted + 1,000 rejected observations, 200 uuids per request):
- only **3.2 %** of admitted observations have an informative ID by anyone
  else (rejected: 4.4 %); among those, disagreement 1 of 32 (rejected 2 of
  44) — far too few to estimate noise, and biased: an observation someone
  disagrees with usually drops to genus and leaves our species-level scan.
  0.6 % became research grade (same species) since the snapshot.
- the rule's premise: on one research-grade observation for each of 400
  admitted (observer, genus) pairs, the observer's own current ID was the
  community species in **97 %** (384/396; 11 coarser).
- observer error when reviewed: all observations (any grade, ≤ 200 newest)
  of 150 admitted (observer, genus) pairs, 4,457 with someone else's ID:
  community taxon elsewhere **0.1 %**, community backed off to a coarser
  taxon **3.1 %** → **≈ 3 % wrong-or-contested** on reviewed observations.
- Estimate of the admitted labels' noise: **≥ ~3 %**, honestly unknown
  above that: reviewed observations are the easier ones, rare tail species
  are harder, and an observer who changed their own ID to match hides the
  original error. A historical snapshot (an old `observations.csv` with the
  same uuids) would measure "needs_id → research grade, same taxon"
  directly; not tried (another ~35 GB download).

## Embedding (not run; estimate)

260,501 photos at the measured **~101 photos/s** end to end on one SPOT L4
(2026-11-04 run: 100.9–102.6/s incl. the S3 fetch) = **~43 min** + ~0.1 h
boot ≈ 0.85 h × $0.511/h ≈ **$0.45** VM (× 1.5 for preemptions ≈ $0.7),
S3 → GCE free, GCS ~0.5 GB of fp16 embeddings. `train_australia.py
vm-embed` takes a todo parquet (photo_id, ext) cut into 1,000-photo shards
→ 261 shards; the `shard` column is for that run to fill.

## Files

- `extra/extra_photos.parquet` (+ `extra_photos-summary.json`) — the list
- `extra/dropped.parquet` — dropped rows with reason and matching photo
- `extra/reassign_train.parquet` — 81 training photos the name map moves
- `extra/inat/<photo_id>.<ext>` — stored photos (photo-less classes)
- `extra/work/` — `candidates.parquet` (+ summary), needs_id scans
  (`needs_id_{obs,photos,targets,admission}.parquet`, incremental), hash
  parts (`hashes-cand-*`, `hashes-eval-*`), `calibration.json`,
  `calibration-emb.json`, `measure.json`, `noise.json`, API cache
  `noise_api/`, logs.

Later sources (ALA, Wikimedia — they mirror iNat photos): hash with
`dedup.hashes`, then `dedup.near_any` against `hashes-eval-*` AND against
this list's `phash`/`dhash` (cross-source copies), thresholds from
`calibration.json`.

## Embedding run (cloud) — bound written BEFORE launch (2026-11-05)

One SPOT g2-standard-8 + 1× L4, us-central1-a (fallback us-east1-c after a
stockout), the existing scripts unchanged (`cloud/run_au.sh` with
`VM=izzy-plantid-extra BUCKET=gs://leo-superresolution-izzy-plantid/au/extra`,
startup `cloud/vm_au.sh`, mode `embed`, `train_australia.py vm-embed` on
`extra/work/todo-extra.parquet` = the list's 260,501 (photo_id, ext) sorted by
photo id → 261 shards of 1,000 in `…/au/extra/emb/`, resumable per shard).
Model weights re-uploaded from the laptop's HF cache to `…/au/extra/model/`
(3.7 GB; the earlier GCS copy was deleted), deleted again afterwards.

- Bound: 260,501 / 101 photos/s (measured 2026-11-04) = 43 min + ~10 min
  boot/model copy/env ≈ **0.9 h**; `--max-run-duration=1.5h` (≈ 2×).
- Cost: VM $0.511/h × 0.9 h ≈ $0.46 (× 1.5 for preemptions ≈ $0.70; hard
  ceiling per boot 1.5 h × $0.53 ≈ $0.80) + disk 120 GB pd-balanced ≈ $0.02
  + GCS (3.7 GB model + 0.55 GB embeddings, days) < $0.01 + egress of the
  embeddings to the laptop 0.55 GB × $0.12 ≈ $0.07 → **≈ $0.6–0.9, cap $3**
  (coordinator's cap; at most 3 boots).

### Embedding run: actual

SPOT L4 stockout in us-central1-a/b/c → **us-east1-c**; boot 23:21 UTC,
**260,501 photos in 2,546 s = 102.3/s**, 261 shards, 0 missing, 0 failed;
job end 00:04:51 UTC (VM ran ~44 min). Cost ≈ $0.38 VM + ~$0.01 disk +
~$0.04 model read across regions + ~$0.07 egress (0.57 GB) ≈ **$0.5**
(bound $0.6–0.9, cap $3). VM and disk deleted, the GCS model copy deleted;
`gs://leo-superresolution-izzy-plantid/au/extra/` keeps `emb/` (0.54 GB),
`in/`, `code/`, `log/`. Shards locally in `extra/emb/` (574 MB).

### Stage 2 (embeddings) and the final list

`expand_inat.py dedup-emb` (MPS, ~10 min incl. hashing 59,901 training
photos streamed from S3 for the confirm band): each extra vs the existing
training photos (598,115 of 598,125 embedded), vs every evaluation photo
(84,704 cloud embeddings + 657 C photos via their w8 Core ML embeddings),
and within the extras (earlier rank wins).

| dropped | photos |
|---|---|
| cos ≥ 0.95 vs a training photo of the SAME observation (burst / zoom of the same shot) | 6,588 |
| cos ≥ 0.95 vs a training photo of another observation | 502 |
| 0.85 ≤ cos < 0.95 vs a training photo AND hashes agree | 14 |
| cos ≥ 0.95 vs an evaluation photo | 26 (+ 11 that also matched a training photo) |
| 0.85 ≤ cos < 0.95 vs an evaluation photo AND hashes agree | 0 (of 44,268 in the band) |
| cos ≥ 0.95 within the extras | 2,960 |

By eye (15-pair sample from a partial run): cos 1.0 pairs are the same
image under two photo ids (true duplicates); 0.95–0.98 within an observation
are burst shots / zooms of the same flower; but the 4 evaluation hits seen
at 0.950–0.953 were DIFFERENT photos of the same species, i.e. the
standalone 0.95 is precautionary across observers: no true duplicate of an
evaluation photo was found in stage 2 (stage 1 found and removed 2). The
confirm band shows why cosine alone can't decide: 114,706 extras sit at
0.85–0.95 to some training photo, only 14 are the same image by hash.

**Final list: `extra/extra_photos_final.parquet` — 250,411 photos, 12,688
classes** (extra-photo 162,796, sa-nd 39,868, needs-id 38,170, name-map
9,512, rg-unused 65). Photo-less labels: 1,140 gain ≥ 1, 528 ≥ 5; classes
with ≥ 5 photos 11,243 → 14,575, ≥ 20 7,293 → 10,631. Format =
`train_v2.py --extra`: `u`, `photo_id`, `source`, `licence`, `shard` (path
of the local npz), `shard_id`, `lat`, `lon` + all earlier columns and the
nearest-neighbour cosines. **Sorted by shard**: `add_extra` caches one npz
at a time and keeps a row view of it, so the list in class order reloaded a
2 MB shard per row and was OOM-killed at 16 GB; sorted it loads 250,411
rows in 45 s at 2.5 GB RSS (checked with the current `add_extra`: 0
rejected, 0 duplicates, all embeddings found, unit norm). Dropped rows:
`extra/dropped_emb.parquet`. Local photo copies deleted (`url` re-fetches).
