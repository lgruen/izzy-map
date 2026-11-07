# Herbarium sheets for species without field photos (2026-11-07)

Code `herbarium_test.py` (HB_SRC=gbif). ALA's image server answered sheet
thumbnails with HTTP 504 after 90 s (33 of 8,778 fetched) → GBIF occurrence
search (PRESERVED_SPECIMEN + StillImage, CC/PD media only, iNat datasets out,
round-robin over institutions, one sheet per specimen) + GBIF's image cache
(fit-in/500x; 2–5 s per uncached image, 8 workers ≈ 3–8/s). 9,725 sheets listed
(975 classes; 4 names without a strict GBIF match, 17 classes without sheets),
9,120 embedded with the shipped w8 Core ML encoder.

Classes: Z = 70 classes with no training photo and AU-test photos (92 photos
after the rare-heldout move; the clean check), S = 295 simulated (≥ 20 training
photos; rows replaced; tune 144 / report 151; leak caveat as zeroshot_rows.py),
F = 593 to fit a sheet→row map. Head final-cb50-s1, main prior λ 1, τ-norm 0.5;
α, β, γ, ridge λ chosen on S-tune with a ≤ 0.3 pt guard on the other classes.

| rows for the replaced classes | Z top-1 | Z top-5 | S-report test top-1 / top-5 | other classes (test) |
|---|---|---|---|---|
| text (today) | 13.6 | 46.4 | 78.3 / 93.3 | 84.2 |
| text + genus shift | 15.2 | 51.0 | 76.2 / 94.4 | 84.4 |
| sheets only (prototype × 0.8) | 33.5 | 66.2 | 61.1 / 85.7 | 84.0 |
| ridge [text, sheets, genus] → row | 16.2 | 46.0 | 80.8 / 95.0 | 84.4 |
| **blend: genus row + 25 % sheet prototype** | **36.5** | **66.8** | **88.4 / 97.3** | 83.9 |
| (S with their real trained rows) | – | – | 86.1 / 95.4 | – |

- cos(trained row, sheet prototype) 0.41 vs cos(trained row, text) 0.57 on F:
  sheets alone point less precisely than text, but in a DIFFERENT direction
  (the plant's actual morphology), so the blend wins.
- The blend beats the real trained rows on simulated S (88.4 vs 86.1): read
  as the leak (the other rows were trained with S's photos as negatives), not
  as "sheets beat photos". The clean Z numbers carry the claim: 13.6 → 36.5
  top-1, 46 → 67 top-5 (92 photos / 70 species, ±~10 pt).

## In the shipped configuration (sheet_rows.py, 2026-11-08)

`sheet_rows.py` writes the blend into the multi-prototype heads (photo-less
classes have one prototype, still exactly the text init — asserted), rule as
above with the head's own genus shift. End-to-end check with the SHIPPED v3
configuration (mpA01 | adaptive prior | Tasmania box bank; T/ladder re-chosen
on val, unchanged), old heads + old evaluation sets, 75 classes with sheets:

| | before | with sheet rows |
|---|---|---|
| AU-test, photo-less classes with sheets (70 classes, 92 photos) | 22.9 | **39.0** |
| AU-test, every other class | 86.17 | 86.14 |
| A-test / C-report photo-less (5 / 6 classes) | 26.7 / 33.3 | 33.3 / 50.0 |
| AU-test overall / A-test overall | 85.7 / 89.2 | 85.8 / 89.3 |
