# Head capacity: undertrained linear head? better heads vs the Tasmania bank (2026-11-06)

Code `pipeline/plantid/head_capacity.py` (design in its docstring). Protocol = bank_analysis.py:
selection on val J = ½(AU-val per species re-weighted to the all-AU-species mix + A-val natural),
main prior (log1p σ10 α64 λ1), scale-kept τ-norm 0.5, a global image-term temperature t tuned on
val per head ({0.8 … 3}; t = 1 for the reference); tests read for every run (exploration table;
the choice is by val). "+bank" = the shipped Tasmania-box bank & box prior inside the box.
Reference reproduced exactly (final-cb50-s1: AU 84.5/92.6, A 87.4/93.2, +bank 88.8/94.8).

## Coverage (final sampler: 50 draws/class/epoch × 12 epochs = 600 per class, with replacement)
60.6 % of the 3.9M photos are ever drawn. By class size: 1–199 photos ≥ 99 %; 200–499 83 %;
500–999 53 %; 1000–2999 (41 % of all photos) 43 %. But the bank's gain does NOT track coverage:
Tasmania bank on A-val+test +1.9 / +2.1 / +1.7 / +2.1 pt for classes with 30–50 / 50–70 / 70–90 /
90–99 % drawn, −2.7 pt for fully covered (rare) classes; national kNN on AU-val +0.6 … +0.9 flat.
So unseen photos are not what the bank exploits (it is local neighbours — cf. bank_analysis).

## Results (per species / natural; mean over seeds where n = 2; ref = final-cb50 s0+s1 + reruns)
| head | n | val J | AU | A | A strict | C-main | C-euc | 1–9 | A +bank | A strict +bank | MB extra | MMAC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ad2048-e12 | 1 | 87.37 | 84.6/92.5 | 87.7/93.7 | 87.3/92.4 | 84.9/93.2 | 65.7/72.3 | 64.4/66.5 | 89.0/95.0 | 88.4/93.6 | 8.4 | 26.8 |
| ad2048-e50 | 1 | 85.53 | 81.4/92.8 | 87.9/94.0 | 87.3/93.0 | 80.9/91.5 | 52.0/70.8 | 58.0/59.1 | 88.9/95.0 | 88.3/93.9 | 8.4 | 26.8 |
| ad2048-e50-last | 1 | 85.19 | 81.2/93.4 | 87.5/94.5 | 87.2/93.4 | 80.4/93.2 | 54.3/73.4 | 57.1/57.6 | 88.2/95.2 | 87.4/93.8 | 8.4 | 26.8 |
| ad4096-e50 | 1 | 85.34 | 81.2/93.2 | 86.5/94.3 | 85.8/93.1 | 80.9/93.5 | 53.3/71.1 | 53.9/53.9 | 88.6/95.1 | 87.8/93.8 | 16.8 | 31.0 |
| ad4096-e50-last | 1 | 85.27 | 81.1/93.3 | 86.5/94.4 | 85.7/93.2 | 80.2/92.9 | 51.9/70.3 | 54.5/55.0 | 88.6/95.2 | 87.8/93.9 | 16.8 | 31.0 |
| dense4 | 1 | 86.16 | 83.9/92.1 | 86.7/93.0 | 86.1/91.9 | 82.8/91.6 | 66.9/73.7 | 67.9/68.8 | 88.6/94.6 | 87.9/93.3 | 54.6 | 49.9 |
| lin-e100 | 1 | 85.93 | 81.0/90.9 | 84.9/92.0 | 84.5/90.6 | 79.7/90.4 | 58.0/70.5 | 66.0/67.1 | 87.7/93.9 | 86.9/92.5 | 0.0 | 22.7 |
| lin-e100-last | 1 | 84.49 | 79.1/93.2 | 86.2/93.7 | 85.5/92.3 | 78.2/92.0 | 50.4/70.9 | 57.5/58.7 | 87.6/94.8 | 86.8/93.6 | 0.0 | 22.7 |
| lin-e12(ref) | 4 | 88.06 | 84.3/92.6 | 87.0/93.1 | 86.6/91.8 | 83.6/92.9 | 65.1/76.6 | 71.5/72.6 | 88.7/94.8 | 88.0/93.5 | 0.0 | 22.7 |
| lin-e25 | 1 | 87.48 | 83.2/93.1 | 87.7/94.1 | 87.1/92.8 | 82.2/92.9 | 60.0/72.2 | 69.0/69.6 | 88.7/94.8 | 87.9/93.6 | 0.0 | 22.7 |
| lin-e25-last | 1 | 87.34 | 83.4/93.3 | 87.5/94.0 | 87.1/92.8 | 82.0/92.5 | 61.3/73.0 | 68.9/69.4 | 88.8/94.9 | 87.9/93.5 | 0.0 | 22.7 |
| lin-e50 | 1 | 86.12 | 81.8/91.0 | 84.9/91.4 | 84.3/90.1 | 80.9/89.9 | 58.9/68.6 | 70.4/71.7 | 88.1/93.8 | 87.4/92.6 | 0.0 | 22.7 |
| lin-e50-last | 1 | 85.45 | 81.1/93.5 | 86.8/94.1 | 86.1/92.7 | 79.7/92.8 | 56.7/73.5 | 63.1/63.5 | 88.5/95.3 | 87.6/94.1 | 0.0 | 22.7 |
| mix-e50 | 1 | 86.17 | 81.9/91.5 | 84.9/92.5 | 84.4/91.2 | 79.8/88.8 | 65.2/74.6 | 70.1/71.8 | 88.4/94.2 | 87.6/93.0 | 0.0 | 22.7 |
| mix-e50-last | 1 | 84.70 | 79.6/92.9 | 86.0/93.8 | 85.5/92.5 | 79.8/91.7 | 50.7/72.4 | 60.6/61.2 | 88.0/95.0 | 87.4/93.9 | 0.0 | 22.7 |
| mpA | 1 | 87.13 | 84.0/92.7 | 87.0/93.4 | 86.8/92.3 | 83.1/92.8 | 63.9/78.0 | 63.0/64.2 | 88.9/94.9 | 88.2/93.5 | 36.4 | 59.1 |
| mpAc | 2 | 88.37 | 84.8/92.6 | 87.4/93.2 | 86.9/92.0 | 84.4/93.1 | 64.3/75.9 | 71.3/72.9 | 89.0/94.6 | 88.2/93.4 | 36.4 | 59.1 |
| mpAc-div0.1 | 1 | 88.25 | 83.7/92.8 | 86.9/93.8 | 86.4/92.5 | 84.0/93.8 | 64.6/79.4 | 71.0/72.5 | 88.6/94.9 | 87.7/93.5 | 36.4 | 59.1 |
| mpAc-g0.3 | 2 | 88.42 | 84.8/92.8 | 87.3/93.2 | 86.8/91.8 | 84.2/93.4 | 65.6/76.2 | 71.3/72.6 | 88.9/94.7 | 88.0/93.4 | 36.4 | 59.1 |
| mpBc | 1 | 88.15 | 84.7/92.8 | 87.3/93.5 | 86.9/92.3 | 84.3/92.6 | 64.1/75.7 | 72.9/73.8 | 88.8/94.6 | 88.1/93.5 | 12.9 | 35.6 |
| mpCc | 1 | 88.35 | 84.4/92.8 | 87.6/93.6 | 87.3/92.4 | 83.8/92.8 | 65.6/79.3 | 71.0/72.7 | 88.6/94.8 | 87.7/93.5 | 17.3 | 40.0 |
| mpDc | 1 | 88.37 | 84.8/92.8 | 87.4/93.6 | 86.9/92.3 | 84.6/93.9 | 64.3/78.1 | 71.8/73.3 | 88.9/94.7 | 88.0/93.6 | 53.2 | 75.8 |
| res2 | 1 | 86.37 | 83.6/92.2 | 86.6/92.8 | 85.8/91.2 | 83.7/92.8 | 66.5/75.4 | 64.6/65.8 | 88.6/94.5 | 87.8/93.4 | 16.8 | 31.0 |
| res4 | 1 | 87.05 | 83.7/91.7 | 87.0/92.8 | 86.6/91.8 | 83.9/91.8 | 64.1/74.8 | 67.4/68.0 | 88.7/94.4 | 88.1/93.1 | 33.6 | 39.4 |
| res4-awd0.1 | 1 | 86.89 | 83.8/92.1 | 87.0/93.2 | 86.3/92.1 | 83.9/90.5 | 64.1/73.6 | 64.4/65.9 | 88.9/94.7 | 88.1/93.5 | 33.6 | 39.4 |
| res4-drop0.3 | 1 | 86.57 | 84.3/92.2 | 87.3/93.4 | 87.0/92.1 | 83.1/91.6 | 66.1/69.0 | 64.9/66.8 | 88.8/94.6 | 88.0/93.2 | 33.6 | 39.4 |
| res4-e25 | 1 | 86.31 | 82.4/93.0 | 86.3/94.0 | 86.0/92.6 | 81.9/93.5 | 59.1/67.7 | 59.5/61.2 | 88.3/94.9 | 87.6/93.6 | 33.6 | 39.4 |
| res4-e25-last | 1 | 86.21 | 82.8/92.8 | 86.9/93.9 | 86.5/92.4 | 82.6/93.5 | 59.1/70.1 | 60.0/61.5 | 88.8/94.8 | 88.2/93.6 | 33.6 | 39.4 |
| tip-e10 | 1 | 87.97 | 84.5/92.6 | 87.5/93.2 | 87.2/91.9 | 83.4/92.4 | 66.1/76.7 | 72.0/73.5 | 88.8/94.8 | 88.0/93.5 | 90.0 | 112.3 |
| tip-e10-a1 | 1 | 87.80 | 84.8/92.3 | 87.1/93.2 | 86.8/92.2 | 84.7/93.1 | 67.8/72.5 | 70.8/72.7 | 88.7/94.8 | 88.0/93.5 | 90.0 | 112.3 |

(-last = the end-of-schedule head instead of the best-J epoch. lin-e200-s1 was cancelled at epoch
136/200 when the final config was chosen: val J 0.839, AU-val rw 0.740, A-val nat 0.938 — same trend.
Not run: mix-e100 (dropped, trend clear), seed 0 of tip / res4 / lin-e50.)

## Findings
- Longer training is NOT the fix: J falls monotonically 12 → 25 → 50 → 100 → 200 epochs (88.0 →
  87.5 → 86.1 → 85.9 → ~83.9); natural-mix accuracy rises (A 93.1 → 94.1, last epoch) while per
  species and the tail fall (1–9 bucket 71.5 → 63; C-euc 65 → 57). Temperature refits don't
  recover it (ranking, not calibration). The mixed sampler (½ uniform) is worse still for the tail.
  The 12-epoch head is at the right point of the bias/variance trade-off for a per-species goal.
- Adapters / residual / dense stacks: all below the linear head on val J (−0.7 … −2.7) — the
  extra capacity memorises common classes and costs the tail (1–9: 64–68 vs 71.5).
- Tip-Adapter-F (85k farthest-point keys, self-match masked): val picks α' = 0 (= no cache);
  at its trained α the cache helps C (+1.1 / +2.7) but hurts A, 1–9 — no substitute for the bank.
- Multi-prototype, done right (cold start from the text init, mean-preserving k-means offsets,
  adaptive K_c = 1/2/4/8 at 50/150/300 photos, soft pooling T·(lse(z/T) − log K_c), learned T,
  12 epochs balanced): the only variant that beats the reference on val in both seeds
  (+0.3 J): AU +0.5 / 0, A +0.4 / +0.1, C-main +0.8 / +0.2, C-euc −0.8, 1–9 −0.2; with the bank
  A 89.0 / 94.6. Warm-started from the trained head it overfits (J 87.1). γ 0.3, other K
  schedules and the diversity penalty tie within noise. Cost +36 MB int8 (Σ K_c = 57.7k rows),
  59 MMAC per photo (negligible next to the encoder).
- None of the heads closes the Tasmania gap (A 87.4 vs 88.8 with the bank); the bank still adds
  +1.4–1.6 pt per species on A on top of every head.

GPU: one SPOT L4 (us-east1-c), ≈ 7.5 VM-hours over 5 boots, ≈ $4.5 incl. disk/egress; VM and
disk deleted. Heads: gs://leo-superresolution-izzy-plantid/au/hc/runs/ (31 files).
