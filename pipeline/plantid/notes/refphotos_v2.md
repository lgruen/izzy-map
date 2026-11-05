# Reference photos v2: all sources, Claude Opus picks (2026-11-05)

Script `build_refphotos_v2.py` (stages `select → fetch → warm → submit
--pilot → collect → stats → submit --approve-spend → collect → build → sheet`;
env line in its docstring + `--with anthropic`). Work dir
`cache/plantid/refphotos/v2/` (cands.parquet, thumb/, vision/{batches.json,
results.jsonl}, spend.jsonl, warm.json, build.json, no_photo.json). Rebuild from
the cached picks: `build` only (no API calls).

## Candidates (`select`, ~3 min incl. a 125 s sizes scan)
- Species = the 18,361 classes with training photos in `australia/v2/data-final.npz`
  (`Xtr/ytr/pid/src`: plan + Tasmanian + k1000 iNat extras + ALA/Commons sources,
  merged classes already applied). Class mean = mean of ALL its training embeddings.
- Ref-eligible: not an evaluation photo (`eval_photo_ids()`), sources need
  `ref_ok` (APII credit format as in LICENSING §1e); the 2,598 source rows now in
  `dropped_sources.parquet` are not eligible. One photo per observation. Original
  ≥ 500 px (≥ 400 for ALA/Commons files) and not a panorama (> 2.5:1).
- Nearest 12 by cosine to the mean get the refine probe (`LOGIT_FLAG` 3, refitted
  from `refphotos_quality_labels.json`); order = unverified-ID tier (needs-id /
  name-map last), probe-flagged last, cosine. Flagged 1.9 %. Top 5 → Opus.
- Species with no v2 candidate keep their v1 snapshot pick as a lone candidate (239;
  228 accepted). Result: 18,498 species with candidates (14,162 with 5, 665 with 4,
  897 with 3, 1,043 with 2, 1,731 with 1).
- iNat 500 px mediums fetched to `refphotos/src/` (56,000 new, 7.2 GB, 400 s at 140/s);
  384 px q82 JPEG thumbnails of every candidate (80k, 51 s).

## Opus (claude-opus-5-5, Batches API, effort low, structured output)
- One identical `system` (1-hour `cache_control` on the instruction block, 1,501
  tokens), `thinking adaptive`, `effort low`, one static JSON schema for all n.
  Single-candidate species use the same request (n = 1; shorter output).
- Warm: one non-batch request (Eucalyptus luculenta): `cache_creation_input_tokens`
  1,501 (1h), $0.0188. Pilot (50 species, 30 with 5 candidates incl. 8 eucalypts):
  49/50 `cache_read_input_tokens` = 1,501 (the other wrote it again). Measured
  $0.00348/species (cost ≈ $0.00101 + $0.00056·n); projection $63.5 for all.
- Full run: 18,448 more species in 19 batches (≤ 180 MB each), submitted in 15 min,
  all finished within ~20 min. 18,497 of 18,498 requests read the cache
  (27.8 M cached tokens); 0 errors/refusals. Actual batch cost $61.09; total API
  spend $61.11 (warm + pilot + full).
- Chosen position: #1 6,358, #2 3,904, #3 3,289, #4 2,617, #5 1,994 (so the
  nearest-to-mean photo is only the winner 35 % of the time). Scores of chosen
  photos: 5 × 10,843, 4 × 6,654, 3 × 618, 2 × 47. "None acceptable": 336 (221 were
  single-candidate species) → no photo (listed in `v2/no_photo.json`).

## Pack (`build`)
- 18,162 photos (of 22,122 labels): inat 14,727, ALA 2,820 (APII mostly), Commons
  615. Licences: CC BY-NC 11,475, CC BY 4,731 (incl. APII CC BY 3.0 AU), CC BY-SA 844,
  CC BY-NC-SA 788, CC0 162, PD 5, CC BY-NC-ND 113 + CC BY-ND 44 (the 157 ND photos are
  the unmodified iNat 500 px JPEG, `original_bytes: true`; all others AVIF 512 px q55
  speed 6). 3,667 distinct credited authors.
- Staging (gitignored) `cache/plantid/refphotos/pack-v2/refphotos/`: `<slug>.avif|jpg`,
  `index.json` (key = au-labels name: u, file, w, h, bytes, licence, licence_label,
  attribution, source, by, photo, obs, page_url, original_bytes, score) 7.5 MB,
  `credits.json` 0.28 MB → 408 MB. `build_packs.py refphotos --data
  cache/plantid/refphotos/pack-v2 --out …/pack-v2-aar` packs the folder (0.404 GB .aar).
- The `refphotos` entry in `asset_packs.json` (prefetch) was already added with the
  app wiring.
- SA photos (CC BY-SA / BY-NC-SA, 1,632) are re-encoded (an adaptation, allowed with
  attribution + same licence; the app's attribution line must show the licence).
  APII: private/non-commercial use only (LICENSING §1e).
- Review sheet: `cache/plantid/refphotos/pack-v2/contact-sheet.jpg` (24 random + 12
  eucalypts). A hand/sleeve at the frame edge is accepted by design.
