# Extra photo sources for the Australia-wide plant ID (2026-11-05)

Investigation only: per-species COUNT queries and ~50 sample images, no bulk
pull. Code `pipeline/plantid/sources_probe.py` (subcommands in its
docstring), cache `pipeline/cache/plantid/sources/` (`sample.json`,
`ala.json`, `ala_lic.json`, `gbif.json`, `wikidata.json`, `commons.json`,
`inat.json`, `snapshot.json`, `thumbs/`).

**Sample:** 200 random labels with NO training photo ("zero", of 6,354) +
200 with 1–19 ("low", of 8,475), seed 20261105. Extrapolations = sample
share × bucket size; 95 % noise at n = 200 is about ±7 pt (e.g. 30 % ± 6.5).
The iNat snapshot numbers are exact (all labels, one local scan). "Field" =
a photo of a living plant (human/machine observation); "specimen" = a
herbarium sheet. iNat's own copies (ALA dr1411, GBIF dataset 50c9509d…) are
always subtracted. "Nothing found" means nothing in the sources probed, not
that no photo exists.

## Summary table (labels gaining ≥ 1 image)

| source | zero: any image | zero: field photo | low (1–19): field photo | licence mix (sampled) | quality | effort to pull |
|---|---|---|---|---|---|---|
| **ALA, non-iNat field photos** (APII, NatureMapr, OzAtlas, QuestaGame, Flickr-EOL, regional projects) | – | **63/200 = 32 % → ~2,000** (≥ 3 photos: 16 % → ~985) | 126/200 = 63 % → ~5,300 (≥ 3: 43 %) | APII CC BY 3.0 AU *per ALA* (see conflict below); OzAtlas CC BY 3.0/4.0 or BY-NC; NatureMapr no per-image licence | APII = expert/vouchered close-ups, excellent; others iNat-like | per species biocache query (0.3 s) + `thumbnail_large` 650 px, 43 KB, **5.6/s at 4 threads (measured)** |
| of which **APII** (Australian Plant Image Index, ANBG, dr413) | – | 58/200 = 29 % → ~1,840 | 113/200 = 56 % → ~4,800 | as above | best single source for the rare tail | ~36k photos for < 20 labels (cap 100) |
| **ALA herbarium images** (AVH: NSW, BRI, MEL, MELU, QVMAG, CGE …) | 114/200 = 57 % → ~3,600 | – | (74 % have specimens) | NSW + BRI CC BY 4.0, MEL/MELU/CGE CC BY-NC-SA 4.0 (600 images sampled) | herbarium sheets: colour bar, labels, pressed brown material | ~240k images (cap 100) ≈ 10 GB at 650 px; ~12 h at the measured 5.6/s |
| **GBIF** non-iNat | **161/200 = 80 % → ~5,100** (specimens) | 8/200 = 4 % → ~250 | 56/200 = 28 % → ~2,400 (NatureMapr, OzAtlas, QuestaGame — same as ALA) | specimens CC BY 4.0 ≫ CC0 > BY-NC-SA; a few "Copyright"/no licence | specimens; adds overseas herbaria (K, L, P, US, E, A, BISH, MO …) with types/historic sheets | 2 API calls/species (2.6 s with facets); media from each institution's server; no media URLs in the AWS/GCS snapshot (`mediatype` only) |
| **Wikimedia Commons** (category or Wikidata P18) | 38/200 = 19 % → ~1,200 | same (nearly all field) | 92/200 = 46 % → ~3,900 | P18 sample (116 files): CC BY 3.0 AU 25, BY 2.0 23, BY-SA 4.0 21, BY 4.0 15, BY-SA 3.0 14, PD/CC0/no restr. 8, other SA 4 | high: many WA studio-black close-ups, Flickr imports; 2 of 116 herbarium | ~20–40k files (median 0, p90 ~5 per label); API batches of 50, standard thumb widths only |
| **iNat snapshot, needs_id** (local, exact) | 1,624 labels (5,910 obs; 1,182 with no research obs at all; 256 with ≥ 5) | same | 5,675 labels (41k obs) | snapshot = CC only (BY-NC ≫ BY > CC0 > SA/ND) | field photos, **unverified IDs** | minutes (S3, 140/s) |
| **iNat snapshot, casual** (cultivated/captive, local, exact) | 247 labels (583 obs) | same | 1,314 labels | CC | garden plants; ID unverified | minutes |
| iNat research-grade not used (val/test observers, SA/ND-only, extra photos per obs) | 785 labels with research obs in the snapshot; `tail_data.json`: 1,116 held-out obs, 293 SA/ND-only | – | 1–9 bucket: +53,893 extra usable photos on used obs, +12,318 held-out obs | SA/ND/NC-SA/NC-ND ARE in the snapshot (2.0M/0.35M/2.2M/1.7M photos) | as training | minutes |
| ANY of the above incl. specimens | 174/200 = **87 % → ~5,500**; field (ALA ∪ GBIF ∪ Commons): 39 % → ~2,500; + iNat needs_id/casual: 56 % → ~3,500 | | low: 183/200 field incl. iNat extras | | | |

Nothing found for 22/200 zero labels (11 % → ~700) in any probed source
(ALA all, GBIF all, Commons, iNat API all grades). For the low bucket,
ALA field + Commons alone would lift 135/200 to ≥ 5 photos (now 93) and
48/200 to ≥ 20 (→ ~2,000 labels; extrapolated).

## Per source

### 1. ALA (biocache-ws + images.ala.org.au)
- Access: `biocache-ws.ala.org.au/ws/occurrences/search?q=lsid:"<APC taxonID>"&fq=multimedia:Image&facets=dataResourceUid,basis_of_record` (no key; `q=lsid:` includes subspecies/varieties); image metadata in batches of 100 via `POST images.ala.org.au/ws/getImageInfoForIdList`; image files at `images.ala.org.au/store/…/{thumbnail,thumbnail_large,original}` (650 px "large" thumbnail ≈ 43 KB). Images-service facets: `images.ala.org.au/ws/facet?q=*:*&facet=recognisedLicence|dataResourceUid`.
- Terms: ALA Terms of Use defer to each provider's licence ("Data Provider Terms prevail"); no published rate limit — keep ≤ 4–8 concurrent, User-Agent set; the bulk occurrence-download API needs an email/account (Leo's call; not needed — per-species queries suffice).
- Whole images service: 35.0M media, 28.6M of them iNaturalist Australia (dr1411 — duplicates of the iNat snapshot, exclude). Next: NatureMapr 1.43M, QuestaGame "Earth Guardians" 1.32M, NSW AVH 735k, MV/AM (zoology) …, BRI AVH 234k, WELT 201k. Plant species with images per resource: NSW AVH 22,866, APII 13,778, MEL 11,454, QuestaGame 5,317, NatureMapr 4,378, BRI 4,094.
- Name system: APC/APNI taxon LSIDs (`https://id.biodiversity.org.au/taxon/apni/…`) — our label set's own APC `taxonID`; 398/400 sample labels have one. No name matching needed.
- Licences (600 non-iNat images sampled): CC BY 4.0 442 (herbaria), CC BY 3.0 AU 85 (APII), CC BY-NC-SA 4.0 46 (MEL, MELU, CGE), none 18 (NatureMapr, QVMAG, QuestaGame), BY 3.0/BY-NC a few. ALA's `recognisedLicence` can disagree with the raw `license` (BRI: raw CC BY 4.0, recognised "CC BY-NC 4.0") — read the raw field and the collectory record.
- **APII licence conflict:** ALA's collectory and every APII image record say CC BY 3.0 AU, but ANBG's own pages say "© contact APII", name the photographer as copyright holder, and allow only non-commercial use of low-resolution images with credit (fees otherwise; `anbg.gov.au/photo/photo-collection-use.html`, `anbg.gov.au/copyright.html`). Many APII photos are of cultivated plants in the ANBG (location "ANBG sect …"), otherwise field shots linked to herbarium vouchers — expert-identified. For training this is acceptable under either reading (private, non-commercial, nothing redistributed); for **reference photos** in a pack, ask the APII photo curator (photo@anbg.gov.au) or treat as not cleared.
- NatureMapr (Canberra-based platform, not iNat): GBIF/ALA dataset licence CC BY 4.0 / 3.0 AU, but no per-image licence → OK for training, not cleared for reference.

### 2. GBIF
- Access: `api.gbif.org/v1/species/match` (strict, kingdom Plantae → usageKey; synonyms → acceptedUsageKey), `occurrence/search?taxonKey=&mediaType=StillImage` (300/page, offset ≤ 100k). No key, no published hard rate limit (measured 2.6 s per faceted query). The monthly AWS/GCS Parquet snapshots carry only `mediatype`, no media URLs or media licence → media URLs need the API or a DwC-A download (needs a GBIF account — Leo's). Media are hotlinked from each institution's server (sizes up to tens of MB; GBIF's thumbnail cache `api.gbif.org/v1/image/cache/…` is an option).
- Name system: GBIF backbone taxonKey; 397/400 EXACT/FUZZY species matches.
- Content for the tail: herbarium sheets — Australian AVH feeds (same records as ALA's; dedup by occurrenceID/catalogue number) plus overseas herbaria (Kew 756 + Naturalis 540 + Paris 175 + Smithsonian 107 + Harvard 106 … images for the 200 zero labels). Field photos for the zero bucket: only 8/200, all NatureMapr/OzAtlas/QuestaGame (also in ALA); Pl@ntNet/Observation.org: essentially nothing for Australian rare natives (one Pl@ntNet record seen, CC BY-SA). Media licences: CC BY 4.0 2,302, CC0 376, BY-NC-SA 197, BY-NC 56, none/"Copyright" ~90, ND 5.

### 3. iNaturalist beyond what we used
- Snapshot licence values (`v2/tail_data.json`, all photos): BY-NC 93.4M, BY 15.1M, CC0 4.5M, **BY-NC-SA 2.2M, BY-SA 2.0M, BY-NC-ND 1.7M, BY-ND 0.35M** — SA/ND photos ARE in the open-data bucket; no API needed. All-rights-reserved photos are not in it (13 % of tail observations per the 50-species API sample in `tail_api.log`; stay out).
- Our pipeline used ONE photo per observation (plan: "first CC0/BY/BY-NC photo"); `tail_data.json` counts +53,893 extra usable photos on already-used observations in the 1–9 bucket, +182k in 10–49.
- Outside Australia: already used (plan fills with rest-of-world after Australia; 85 % Australian).
- Grades (`snapshot.json`, one 226 s scan, exact): zero bucket — research obs for 785 labels (mostly held-out observers or SA/ND-only; a few are synonym duplicates, below), needs_id for 1,624 labels (5,910 obs, 97 % Australian), casual for 247. API cross-check on the sample (photos, all licences): needs_id 61/200, casual 6/200, research 30/200.
- Label reliability: needs_id = the observer's own (or one) ID, unconfirmed — for rare, similar-looking species often wrong; casual = cultivated/captive or missing data, ID also unconfirmed, garden habit. Usable only with a filter, e.g. observer has ≥ N research-grade observations in the same genus (computable from the snapshot), or ≥ 1 agreeing ID via the API. Not for reference photos.
- Rate limits (iNat API docs, from memory — the docs page did not render for the fetcher): ~1 req/s, ≤ 10k requests/day; bulk media must come from the open-data S3 bucket, not the API. Name system: iNat taxon ids (labels' `inat`; 4,621 of 6,354 zero labels have one).

### 4. Wikimedia Commons + Wikidata
- Access: Wikidata by `P225` taxon name (query.wikidata.org answered 429 "1 req / min" during a WDQS outage on 2026-11-05 → used the QLever mirror `qlever.dev/api/wikidata`); Commons API `prop=categoryinfo` / `imageinfo` with `extmetadata` (licence, artist) in batches of 50; thumbnails only in standard widths (`iiurlwidth`), arbitrary `NNNpx-` URLs answer 400. Wikimedia policy: descriptive User-Agent, serial requests.
- Coverage: Wikidata item for 389/400 names (97 %), with APNI ID (P5984) 386, GBIF (P846) 384, iNat (P3151) only 162 — a ready crosswalk QID ↔ APNI ↔ GBIF for the synonym work (only 6 zero labels without our iNat id have one there). P18 image: 24 zero / 81 low labels; Commons category with files: 34 / 77.
- Licences: mostly CC BY (2.0/3.0 AU/4.0) and CC BY-SA; reference photos OK with attribution (SA: our resized AVIF carries the same SA licence). Sources: 31/116 P18 files are Flickr imports, 8/116 iNat copies (dedup), 2 herbarium. Quality high (many WA studio-black close-ups, habit shots).

### 5. Others checked (not measured)
- **VicFlora** (RBG Victoria): text CC BY 4.0, images mostly CC BY-NC-SA 4.0, some third-party "written permission required" (caption says which) — usable for training, reference OK where the caption gives CC BY-NC-SA; Victorian species only (few of the tail).
- **Flora of Australia online** (ABRS, profiles.ala.org.au): "All material CC-BY unless otherwise stated" — illustrations/photos per item; small, not measured.
- **FloraBase (WA Herbarium)**: own restrictive policy (≤ 3 images per project, no cropping, permission otherwise) → skip. **PlantNET (NSW)**, **APII via the ANBG website**: all rights reserved/own terms → skip (APII only via ALA, see conflict).
- **Flickr**: large pool of CC-licensed Australian plant photos (many Commons P18 files come from there), but the API needs a key (Leo's account); not measured.

## Dedup and leakage
- iNat copies: ALA dr1411 and GBIF 50c9509d… excluded; Commons has some iNat/Flickr copies; NatureMapr users sometimes cross-post. Before training, drop near-duplicates of any eval photo (embedding cos ≥ 0.97 against AU-val/AU-test/C/A) — a copied val/test photo would leak.
- ALA AVH = GBIF AVH (same records); take Australian herbaria from ALA, only overseas ones from GBIF.

## Side finding (label set)
Five zero-photo labels have an iNat id that `inat_map.parquet` assigns to
ANOTHER class, i.e. duplicate classes: Bossiaea cinerea and Ozothamnus
cinereus appear twice (one copy with 100 photos, one with 0), Drosera
planchonii → D. macrantha, Oxybasis glauca → Chenopodium glaucum, Plantago
leptostachys → P. tasmanica. The 0-photo twins can never win; merge them
(synonym agent).

## Recommendation
- **Training (rare tail), in order of value per effort:** (1) iNat snapshot
  extras — all photos per observation, SA/ND licences, rest-of-world (already
  local; minutes); (2) ALA non-iNat field photos, APII first (~52k photos for
  the < 20 labels, ~2.2 GB; ~2.6 h at the measured 4-thread rate, ~1 h with
  keep-alive/8 threads); (3) Commons (~20–40k files); (4) iNat needs_id with
  an observer-expertise filter. (5) Herbarium sheets (ALA ~240k / GBIF
  ~420k) only after a quick experiment: the frozen text rows score 0 % today
  (AU-test), so even specimen-only prototypes may help — measure by training
  ~300 classes that HAVE field test photos on specimens only (field photos
  withheld) and compare with text-only.
- **Reference photos (5,797 without one):** Commons (BY/BY-SA/CC0) and ALA
  OzAtlas/QuestaGame (licensed) first, iNat SA (re-encode allowed) / ND
  (shipped byte-for-byte as the 500 px JPEG), APII only once the curator
  confirms; a herbarium sheet (NSW/BRI CC BY 4.0, MEL BY-NC-SA) as a labelled
  last fallback — informative for a botanically literate user. Expected:
  field photo for ~2,500 of the 6,354 photo-less labels, any image for
  ~5,500.

---

# The pulls (approved by Leo 2026-11-05)

Code `pipeline/plantid/sources_pull.py` (subcommands and licence rules in its
docstring). Everything resumable (per-label / per-image cache files), polite
(ALA biocache ≤ 3 concurrent, images.ala.org.au 6 keep-alive workers,
Wikimedia API 3 workers and ONE thumbnail worker ≥ 0.4 s apart).

## 1. ALA occurrence counts for the national prior

`sources_pull.py counts` then `counts-table`: 22,122 labels, one
`point-0.001` facet query each (`species:"<label>"`; 0 records → ALA name
matching, retried under ALA's accepted name: 317 labels "ala-accepted"),
filters = build_records.py's minus the Tasmania limits (kingdom Plantae,
ABSENT out, `dataGeneralizations`/`sensitive` out, fossils out,
coordinateUncertainty > 1 km out but missing kept), bbox = the prior grid
(lat −44…−9, lon 112…154; Macquarie, Lord Howe, Norfolk, Christmas Island
out). Coarse georeferences dropped locally: points whose lat AND lon are both
the 0.001° rounding of a whole arc-minute (the 0.1° grid is a subset).
**Measured 2026-11-05: 22 min** (0.06 s per label wall at 3 workers — much
faster than the 0.8 s/label estimate).

- 19,484 labels with records, 21.33M records at 15.67M distinct
  (label, 0.001° point) pairs; arc-minute points dropped: 747k points /
  1.12M records → **20.21M records kept, 5.61M (0.05° cell, class) pairs**.
- `sources/ala_counts/ala_counts.parquet` (u, cy, cx, n on the 0.05° prior
  grid lat0 −44 / lon0 112; integer cell maths) for `prior_v2.py build
  --counts …/ala_counts.parquet`; `ala_points.parquet` (u, lat, lon, n at
  0.001°) for anything finer; `summary.json` (filters, relations, the 50
  ALA species shared by > 1 label — e.g. Callistemon citrinus / Melaleuca
  citrina, the Bossiaea cinerea twin; class merges in train_v2 handle
  these).
- **2,638 labels have NO record under these filters**: almost all
  threatened natives whose ALA points are generalised to ~10 km
  ("Critically Endangered in WA. Generalised to 10km by WA DEC") or have no
  coordinates at all (checked on 40: 10 lost to the sensitive filter, the
  rest's ungeneralised records carry no coordinates). OPTIONAL supplement
  `counts-generalised` (2 min): their generalised/sensitive records only →
  `ala_counts_generalised.parquet` — **2,498 of the 2,638 have some** (136k
  records, 32k cell × class pairs). 10 km is useless for 100 m TASVEG joins
  (why build_records drops them) but at the scale of a 0.05° prior with a
  10–25 km kernel; add it as a second `--counts` table if the eval agrees.

- **No-iNat variant** (`counts --noinat`, `counts-table --noinat`,
  `counts-generalised --noinat`; 16 min): ALA's iNaturalist Australia copy
  (dr1411) leaks iNat val/test observations into the prior, so the same pull
  with `fq=-data_resource_uid:dr1411` (same query name per label as the
  main pull) → `ala_counts_noinat.parquet` (16.88M records kept, 4.97M cell ×
  class pairs, 19,462 labels with records, 2,660 without),
  `ala_points_noinat.parquet`, `ala_counts_generalised_noinat.parquet`
  (2,504 labels, 122k records), `summary_noinat.json`.

## 2. ALA field photos

`ala-list → ala-info → ala-fetch`: every label (most-needed first: 0, 1–9,
10–19, rest), non-iNat field records with images (basis HUMAN_OBSERVATION /
OBSERVATION / MACHINE_OBSERVATION / LIVING_SPECIMEN; NatureMapr, any
iNaturalist resource and herbarium sheets out), APII first, up to room =
1,000 − existing training photos per label (Leo: ≤ 1,000 training photos per
label over all sources, non-iNat first). Per-image licence from
images.ala.org.au (`getImageInfoForIdList`); an empty image licence falls
back to the occurrence record's (→ training only).

- 295,841 candidate images over 13,870 labels; fetched 209,844 distinct
  (the rest are the same image under several labels) in 2 h at 29/s.
- Gotchas: biocache answers `pageSize=300` with an instant 503 (nginx) —
  page by 100. images.ala.org.au redirects every image to the CloudFront
  host images-assets.ala.org.au; requesting that host first halves the
  latency (~half are cache hits; misses 302 back to images.ala.org.au?nr).
  Latency-bound, no throttling seen: 6 / 12 / 16 workers = 20 / 40 / 52 per s
  with flat p50 0.13 s → 12 workers (ALA publishes no image rate limit).
- **Site photos**: habitat-restoration / koala / flying-fox / nest-box
  projects attach ONE site photo (paddock, tree guards, forest view) to
  every species recorded at the site — eyeballed. Rule in `dedup`: a
  resource whose images sit under > 1 label for > 20 % of its images is
  dropped whole (23 resources), and any image filed under several labels
  is dropped everywhere.

## 3. Wikimedia Commons

`commons-list → commons-fetch` (and `sources_bg.sh`, the resumable
background driver): Wikidata P225 → P18/P373 for all 22,122 names (21,794
have an item; `commons/wikidata.json` doubles as a QID/APNI/GBIF/iNat
crosswalk), species category + every non-specimen subcategory one level
deep + P18; JPEG only; files whose categories/description mention
herbarium/specimen/illustration/map etc. out; iNaturalist mirrors out
(Commons copies of iNat photos: our iNat pipeline owns those); CC/PD only
(GFDL-only and "copyrighted free use" out). All labels, no per-label cap
except the 1,000 total (Commons takes what ALA leaves).

- Wikimedia robot policy (wikitech Robot_policy, read 2026-11-05): total
  concurrency ≤ 2, ≤ 25 Mbps, identifying UA, standard thumbnail sizes.
  UA = "izzymap-plantid-eval/1 (https://github.com/lgruen/izzy-map;
  non-commercial research)". 3 workers with the bare UA drew 429s with
  Retry-After 600. No thumbnail width is pre-cached for these files (50
  GETs over 250/330/500/960/1280 px: all CDN misses, all 200 when serial),
  so ~1 s per render-miss → ~2/s at 2 workers, 0.8–1.6/s with 1 worker
  while an API job runs. No sanctioned bulk path: no media dumps any more;
  CapyWiki-34M (HF) = links only; Zahide4/testdataset (HF, 384 px WebP,
  CC0/BY/BY-SA, SHA-1 per file) is a test set of unknown coverage; the
  Internet Archive WikiTeam grabs are per-day original tarballs. imageinfo
  records `sha1` so a mirror could still be matched later.
- Listing: 293,463 files over 10,806 labels before filters; imageinfo is
  capped at 50 titles per call without a bot flag (~20 files/s, ~4 h).
  The < 20-photo labels' 17,243 candidates (3,980 labels) were fetched
  first; the rest trickles in via `sources_bg.sh` (snapshot of the extras
  list every 25k photos).

## 4. Dedup and the extras list

`sources_pull.py dedup` → `sources/extra_photos_sources.parquet` (columns
as extra/extra_photos.parquet plus image_id, data_resource, dr_name, basis,
licence_source, licence_raw, page_url, src_url, train_ok, ref_ok, ref_note)
+ `dropped_sources.parquet` + `extra_photos_sources-summary.json`. Stage 1
(dedup.py hashes, calibrated pHash ≤ 8 AND dHash ≤ 10): vs the 85k
evaluation photos, vs the 261k iNat extra candidates, within (one copy per
label; reference-eligible copies win, e.g. a CC BY Commons upload of an
APII photo beats the training-only APII row; near-identical photos under
DIFFERENT labels are dropped as a group). Stage 2 (embedding cosine vs the
680k existing training photos — never hashed, not on disk) has to follow
the cloud embedding, as for the iNat extras.

## Status 2026-11-05 17:56 (ALA complete, Commons tail complete)

Snapshot `sources/extra_photos_sources.parquet`: **253,676 photos kept**
(ALA 238,543: APII 113,392, QuestaGame "Earth Guardians" 63,230, OzAtlas
43,423, NatureShare 10,390, …; Commons 15,133). Licences CC BY 167,502,
BY-NC 76,635, BY-SA 9,076, CC0 271, PD 191. Reference-eligible: ALA 45,506
+ Commons 15,101 (APII is training only). Labels gaining training photos:
2,107 of the 0-photo labels (757 with ≥ 5) and 5,649 of the 1–19 labels
(3,180 with ≥ 5); reference photos for 1,029 + 3,717 of them. Dropped:
site-photo resources 24,969, same image under several species 9,810,
near-identical under several species 6,491, within duplicates 11,173, iNat
extra duplicates 1,030, evaluation duplicates 115, 404 upstream 7,139.
Disk 15.2 GB of photos (sources/ 17 GB). Commons for the remaining labels:
265,695 candidates over 9,729 labels, 234,601 still to fetch at ~2/s
(≈ 33 h) via `sources_bg.sh`, snapshots every 25k.
