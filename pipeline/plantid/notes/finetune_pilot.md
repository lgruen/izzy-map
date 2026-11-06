# Encoder fine-tuning pilot (2026-11-06)

Question: does fine-tuning the BioCLIP 2.5 image encoder (instead of keeping
it frozen) improve Australia-wide identification enough to justify a full
run? Head-capacity experiments (`australia/v2/head_capacity/report.md`) buy
only ~0.5 pt on frozen embeddings, so the embedding is the suspected limit.

Code: `pipeline/plantid/finetune/` — `ft_plan.py` (subset + todo, Mac),
`ft_train.py` (pod: fetch, train, embed), `ft_pod.py` (token-guarded pod
server, the `cloud/runpod_pod.py` pattern), `ft_runpod.py` (Mac driver),
`ft_eval.py` (Mac: same production head on every arm's embeddings).
Outputs: `pipeline/cache/plantid/finetune/` (gitignored).

## Subset (ft_plan.py, seed 0)

969 classes over 206 genera, every one with a congener in the subset: 150
eucalypts (Eucalyptus 130, Corymbia 16, …), 185 Tasmanian-shipped labels,
training-count buckets 1–9: 159, 10–49: 231, 50–199: 288, 200+: 291.
ALL their data-final training photos: 253,784 (17,496 ALA/Commons, uploaded
to the pods as tars; the rest from the iNat open-data bucket); per epoch ≤ 200
per class → 97,002 photo draws. Val = AU-val 1,056 + A-val 207, test =
AU-test 3,670 + A-test 395 (the main protocol's held-out observers; training
observers asserted disjoint from every evaluation observer, no photo in both).
Probe = 4,000 outside-subset AU-test/A-test photos (22,122-way zero-shot).

## Bound (written BEFORE launch)

RunPod SECURE RTX 4090, $0.89/h listed (balance $68.32 at launch; cap $30,
$45 incl. the contrastive arm). One pod per arm: lora, partial,
supcon-lora, supcon-partial (+ one short H100 SXM throughput bench, $3.99/h).

- Per 4090 pod (estimate; inference 175–193 photos/s measured fetch-bound on
  these pods in the K = 1,000 run): image + uv env + 3.9 GB model ~10 min,
  upload 1.1 GB of tars ~3 min, S3 fetch of 246k photos at ~170/s ~25 min,
  training 3 × 97k draws at an assumed ~200 photos/s (fwd over 32 blocks,
  bwd over 8 ≈ 1.5× inference FLOPs) ~25 min, final embedding of 263k rows
  at ~400/s ~11 min, pull ~5 min → **~1.3 h ≈ $1.2**; at half the assumed
  speeds ~2 h ≈ $1.8.
- 4 arm pods ≈ $5–7; H100 bench (≤ 0.3 h) ≈ $1.2; stalled-pod replacements
  (the K = 1,000 run lost 4 × 0.28 h) ≈ $1–2 → **expected ≈ $7–10**.
- **Hard stop:** any pod still alive at 3.0 h is pulled and terminated
  (4 × 3 h × $0.89 + 0.5 h H100 ≈ $13 worst case, ≪ the $30 cap; ≥ $5
  headroom on the balance kept throughout). One check ~20 min after launch,
  then one at the estimated end; results pulled (sha256-verified) before
  each pod is terminated.

## Actual run (2026-11-06)

4 × RTX 4090 SECURE (EUR-IS-1/2, US-TX-3; $0.89/h listed): pod-hours 1.09 /
1.08 / 1.63 / 1.64 (two waited for a driver restart: concurrent state
writes were made merge-safe before their start) + H100 SXM bench 0.10 h
($3.99/h) → **≈ $5.2** (bound $7–10, cap $30). All pods terminated after
sha256-verified pulls; `GET /v2/pods` = 0.

Measured: S3 fetch 245,613 photos at 225–480/s (64 threads); training
(fwd 32 blocks, bwd last 8, bf16, micro-batch 64, 16 loader workers) **184–195
photos/s on a 4090** for every arm (8.7 GB LoRA / 10.6 GB partial peak), H100
**≥ 450/s** (still loader-bound at 16 workers); embedding 300–308/s (4090),
531/s (H100, loader-bound). Frozen pod embeddings vs data-final: cos median
0.99991, min 0.9957 (bf16 vs fp16).

Recipe: 3 epochs × 97k draws (≤ 200/class/epoch), bs 128; LoRA r16 α32 lr
2e-4 (blocks 24–31: in/out proj, fc, proj); partial = blocks 24–31 + ln_post
+ proj, lr 2e-5 × 0.8^depth, wd 0.05; supcon: 75 % genus batches (4 × ≤ 8
species × 4 photos), SupCon t 0.1 (+ text rows as anchors), image–text CE
λ 0.5. Val (joint head) still rising at epoch 3 for every arm.

Results (`ft_eval.py` → `finetune/eval.md`; same production head recipe on
every arm's embeddings, head seeds 0/1; 969-way, 4,063 test photos):

| arm | +prior top-1 sp | top-5 | nat | euc | 1–9 | head-only | kNN10 | kNN10 euc | zs probe 22k |
|---|---|---|---|---|---|---|---|---|---|
| frozen | 89.7 | 98.5 | 95.0 | 79.3 | 88.9 | 81.6 | 74.9 | 48.4 | 68.0 |
| lora | 89.8 | 98.2 | 95.5 | 81.0 | 87.8 | 83.8 | 76.7 | 52.0 | 68.3 |
| partial | 90.2 | 98.3 | 95.8 | 82.4 | 88.2 | 84.3 | 77.3 | 53.0 | 67.2 |
| supcon-lora | 89.8 | 98.5 | 95.5 | 78.8 | 87.2 | 83.5 | 77.7 | 53.3 | 59.3 |
| supcon-partial | 89.8 | 98.7 | 95.7 | 79.3 | 85.7 | 83.3 | 77.9 | 54.9 | 60.2 |

Paired class-cluster bootstrap vs frozen (per-species top-1, 95 %): with the
prior lora +0.06 [−0.55, +0.65], partial +0.33 [−0.39, +1.06], supcon-lora
+0.07 [−0.77, +0.91], supcon-partial +0.01 [−0.92, +0.85]; head only +1.4 …
+2.2 (all exclude 0); kNN10 +1.7 … +2.9 (all exclude 0). Errors that are a
congener: 77 % frozen → 79–82 %.

Reading: the tuned encoders separate species better from the image alone
(head-only +2, kNN +2–3, eucalypt kNN +5–6), but with the location prior —
the shipped configuration — the gain shrinks to ≤ 0.3 pt (the prior already
resolves most of what the encoder learned); the 1–9 bucket loses 0.7–3 pt;
the supcon arms lose ~8 pt of 22,122-way zero-shot on OUTSIDE classes (text
alignment eroded — photo-less classes would suffer), LoRA/partial keep it.
Not explored: more epochs (val still rising), LR sweeps, 22,122-way
evaluation of a tuned encoder (needs the full re-embedding).

On-device export check (`ft_coreml.py partial`, M4): tuned blocks applied to
the pinned BioCLIP 2.5, traced + converted as export_coreml.py, w8 as
build_ship.py → on 100 subset test photos Core ML w8 (ALL units) vs PyTorch
fp32 of the same encoder cos min 0.9983 / median 0.99983, joint-head top-1
agreement 100 %, 0.14 s/photo; PyTorch fp32 vs the pod's bf16 embeddings cos
min 0.9993. (LoRA merge path checked the same way on a smoke run.) Trace
12 min (CPU fp32), convert + w8 3.4 min.

## Full-run estimate (not run)

Best arm = partial (last 8 blocks, LLRD). Data 3,897,289 photos / 18,361
classes; ≤ 200 per class per epoch = 1,555,531 draws → 3 epochs 4.67M, 5
epochs 7.8M (val was still rising at 3).
- Training on ONE 4090 at the measured 187/s: 3 epochs 6.9 h ≈ $6, 5 epochs
  11.6 h ≈ $10 (photos streamed from S3 — the measured 225+/s fetch keeps up
  with one GPU; ≤ ~2.6M distinct photos ≈ 340 GB if cached). 8 × 4090 DDP
  would take ~1–1.5 h for similar $ but needs DDP code (not written) and
  ~1,500 photos/s of S3 + decode on one machine (not measured).
- Re-embedding every training + evaluation + bank photo (~3.98M) with the
  tuned encoder: 8 × 4090 pods, fetch-bound ~225–300/s each → ~0.6 h + setup
  ≈ 6–7 pod-h ≈ $6.
- Head retrain + eval_v2/ladder (L4 or local, ≈ $0.5), w8 export ~16 min on
  the Mac (measured), new `plantid` pack (~0.7 GB every device re-downloads).
- **≈ $13–17 and ~12–14 h wall per full run** (single-GPU training); a
  2-seed decision ≈ $30.
