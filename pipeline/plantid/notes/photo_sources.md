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
