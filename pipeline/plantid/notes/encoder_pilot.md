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
