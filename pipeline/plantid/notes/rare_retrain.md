# Retrain with the rare species' held-out photos (2026-11-07)

Leo: "retrain with those rare photos or modify the split such that this can
never happen by construction". Rule (`rare_heldout.py`, K = 10): a species with
< 10 training photos takes its held-out observers' observations into training,
whole observers in hash order, until it has ≥ 10; the rest stays for
evaluation. 2,237 observations / 5,255 photos (≤ 3 per observation) over
1,226 species (257 of them photo-less before) by 377 observers; embedded
locally (open_clip BioCLIP 2.5 fp16 on MPS, 7.8/s). Every evaluation set drops
every photo of a moved observation (`moved_photo_ids()`; V2_NO_MOVE=1
reproduces the old sets): AU-val 17,055 → 17,003, A-test 5,684 → 5,644,
AU-test 44,616 → 44,068.

Data: `data-final2.npz` (train_v2 data + rare_heldout/extras.parquet): 3,902,544
photos, 18,618 classes with photos (was 18,361). Caches: bank_analysis2/,
head_capacity2/vm (val pack).

## Bound for the head retrain (written before launch)

`cloud/hc_retrain.sh`: one SPOT g2-standard-8 + L4 (us-central1-a), the two
shipped heads hc-mpAc-s0/s1 with their exact cfgs. Measured on 2026-11-06:
1,133 s per head on the L4 → 38 min; boot + uv env 5–25 min; 8.1 GB data from
GCS ~2 min → **~1.1 h ≈ $0.56** (SPOT $0.511/h) + laptop→GCS upload of 8.1 GB
(free ingress) + 2 heads back (~0.1 GB, $0.01). **Cap enforced by GCP:**
`--max-run-duration=2h` with termination action DELETE (≤ $1.1), and the VM
deletes itself when the startup script ends (fallback: power-off). A
preemption deletes the VM; the finished head is in GCS, a re-create resumes.

## Actual run + result

GCP SPOT L4 us-central1-a, 12:35 → 13:23 UTC (48 min, both heads 1,13x s each;
VM deleted itself) ≈ $0.41. Heads `head_capacity2/runs/hc-mpAc-s{0,1}.npz`
(gs://…/au-r2/hc/runs/). Scored with the shipped configuration
`mpA01|adaptive|box` (fit/refine params unchanged; T and ladder re-chosen on
the new val: T 1.910, species thresholds 0.50/0.75/0.50/0.55 by bucket, genus
0.50), old and new heads on IDENTICAL sets (final_sweep2old / final_sweep2):

| per species top-1 | old heads | retrained |
|---|---|---|
| AU-test (8,856 classes, 44,068 photos) | 86.6 | 86.5 (paired −0.1 [−0.3, +0.1]) |
| A-test | 89.8 | 90.1 (+0.3 [−0.4, +1.0]) |
| A-test, old 10–49-photo classes (97) | 78.3 | 82.6 (+4.4 [+1.1, +8.0]) |
| AU-test, classes that gained photos (60 left with test photos) | 67.3 | 68.1 (+0.8 [−5.0, +6.7]) |
| C-main / C-euc | 86.0 / 66.5 | 85.3 / 66.1 |
| stated-wrong (AU-test, per species) | 6.0 | 6.5 |

By construction the 1–9-photo bucket of AU-test is empty now (every such class
with held-out photos had them moved), so the beneficiaries are mostly not
testable; the evidence for them is the per-count curve (0 photos ≈ 0–14 %,
1–9 ≈ 60–70 %).
