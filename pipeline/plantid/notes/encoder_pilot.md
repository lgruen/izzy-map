# Photo-only encoder pilot: DINOv3 / Perception Encoder vs BioCLIP 2.5 (2026-11-07)

Question (Leo: rare species first; photos are the use case, text-only species
may be dropped): does a different image encoder — alone or next to BioCLIP 2.5 —
identify rare Australian species better? Candidates that fit an iPhone 16e
next to (or instead of) BioCLIP: DINOv3 ViT-L/16 (303 M, self-supervised, gated
weights, DINOv3 licence), DINOv3 ViT-H+/16 (841 M, ceiling check — likely too
heavy beside BioCLIP), Perception Encoder core L/14 @ 336 (317 M, image–text,
Apache 2.0, `timm/PE-Core-L-14-336` sha 8eff41b3). Published context: iNat21
linear probe DINOv3-7B 89.8, PE-core-G 87.0 (DINOv3 paper Tab. 8); BioBench
(Nov 2025, no DINOv3): BioCLIP 2 best on Pl@ntNet and Herbarium19.

Code: `finetune/dino_embed.py` (pod), `finetune/dino_pod.py` (server),
`ft_runpod.py launch --kind dino`, `finetune/dino_eval.py` (Mac). Subset and
protocol = the fine-tune pilot (969 classes, 253,784 training photos, held-out
observers, production head recipe + prior); BioCLIP arm reproduces its frozen
row exactly (89.7 / 98.5 / 95.0 nat / euc 79.3 / 1–9 88.9).
Gotcha: DINOv3 in fp16 gives NaN embeddings (activation overflow) → bf16.

## Bound (written before launch)

One RunPod SECURE RTX 4090 ($0.89/h listed). Estimate: pod + uv env ~10 min,
upload 1.1 GB tars + 2.3 GB fp16 weights ~10–15 min, S3 fetch of 236k photos
at 225–480/s (measured in the fine-tune pilot) ~10–18 min, embedding 263k
photos × 4 variants (estimate ~140 photos/s combined on a 4090: H+ ≈ the
BioCLIP ViT-H cost, L@336 and PE@336 ~2.3× L@224) ~30 min, pull ~4.5 GB
~10 min → **~1.3 h ≈ $1.2**; at half speed ~2.2 h ≈ $2. **Hard stop: pulled
and terminated at 3.0 h (≤ $2.7).** One check ~20 min after launch, one at the
estimated end.

## Actual run (2026-11-07)

One RunPod SECURE RTX 4090 (EUR-IS-2). First start failed (RunPod image sets
HF_HUB_ENABLE_HF_TRANSFER=1 without the package → open_clip's PE download
failed; fixed in dino_embed.py, restarted on the same pod; photos kept). Embedded
263,109 photos (3 gone upstream) in 3,157 s = 83/s for all four variants
together; GPU-only rates on the 4090: DINOv3-L@224 724/s, L@336 317/s, H+@224
302/s, PE-L@336 249/s. **Overrun:** the job ended 07:15 UTC but the pod idled
until 11:37 because the driving session restarted and termination depended on
it → 5.75 pod-h ≈ $5.1 (bound $1.2, "hard stop" 3 h was session-side only).
Fix: pods now remove themselves (watchdog in ft_pod/dino_pod/runpod_pod.py).

## Results (dino_eval.py → finetune/dino/eval.md; 969 classes, 3,872 test photos
after the rare-heldout move; production head recipe, prior λ 1; seeds 0/1)

| arm | top-1 sp | top-5 | nat | euc | 1–9 | head only | kNN10 |
|---|---|---|---|---|---|---|---|
| BioCLIP 2.5 (production) | **89.7** | 98.5 | 95.0 | 79.3 | **88.9** | 81.5 | 74.9 |
| DINOv3-L @224 | 81.5 | 94.5 | 89.6 | 69.6 | 72.2 | 67.6 | 59.7 |
| DINOv3-L @336 | 83.0 | 95.3 | 90.9 | 70.7 | 76.6 | 70.3 | 61.6 |
| DINOv3-H+ @224 | 82.1 | 95.6 | 89.9 | 67.7 | 76.1 | 70.4 | 60.1 |
| PE-core-L @336 | 77.3 | 92.7 | 86.9 | 64.0 | 62.9 | 60.5 | 46.2 |
| BioCLIP + DINOv3-L@336 (w 0.5 on val) | **89.7** | 98.9 | 95.9 | 79.9 | 86.0 | 84.6 | 74.3 |
| BioCLIP + DINOv3-L@224 (w 0.5) | 89.5 | 98.8 | 96.0 | 80.9 | 84.2 | 84.2 | 74.5 |
| BioCLIP + DINOv3-H+ (w 0.75) | 88.6 | 98.4 | 95.8 | 80.9 | 82.1 | 83.7 | 73.5 |
| BioCLIP + PE-L (w 0.5) | 89.5 | 98.4 | 95.8 | 80.3 | 85.7 | 82.6 | 73.9 |

Paired class-cluster bootstrap vs BioCLIP (per-species top-1, 95 %): alone,
every other encoder is 7–13 pt worse with the prior (all exclude 0). Combined:
head only +1.8 … +2.5 (exclude 0), but with the prior −0.1 … −1.1 (DINOv3-L
both resolutions and PE include 0; H+ −1.06 excludes 0); the 1–9-photo
classes lose 3–7 pt; natural mix +0.8–1.0.

Reading: BioCLIP 2.5's image features are the better photo features for this
task, not only a text bridge — trained on ~200M organism photos with taxonomic
labels, they carry species-level knowledge the general self-supervised /
web image–text models lack, and the gap is largest exactly for the rare
classes (1–9 photos: 88.9 vs 63–77). A second encoder adds image-only
separability (head-only +2) that the location prior already supplies, as in
the fine-tune pilot. Decision: no second encoder (+0.3 GB, +latency, no
per-species gain). Not explored: DINOv3-7B (not phone-sized), fine-tuned
DINOv3, other fusion than concatenation.
