# Reference-photo gap fill (2026-11-07)

Leo, using the app: "many species didn't have reference photos". The
refphotos pack v2 (notes/refphotos_v2.md) has 18,373 photos for 22,103
unmerged labels. 3,730 have none:

- 3,517 have no training photos, so `select` had no candidate (candidates
  come only from the training rows in data-final.npz);
- 213 have training photos, and Opus rejected all 5 candidates for 125 of
  them (the rest had no candidate passing the size gate).

In Tasmania the gap is small: 71 of the 3,003 species with ALA records in
the Tasmania box (0.4 % of the records). Most of what Leo saw was the app
hiding photos it had (fixed in the app, same day): the guide never showed a
reference photo (1,030 of the 1,160 UN profiles without a photo have one), and
the decode lane gave up for the whole session after 3 stuck decodes.

## Sources measured (ALA facets + iNat API, 2026-11-07)

ALA's occurrence-level `license` is the RECORD's licence, not the photo's:
ALA's iNaturalist copy (dr1411) reports CC BY-NC records whose photos are
all-rights-reserved. Only the image service's own licence
(`getImageInfoForIdList`) counts, as in sources_pull.py. With that rule,
all 3,730 (looked up 2026-11-07, 61 min at ~1 iNat request/s) come out as
follows, by the first candidate each species would get:

| first candidate            | all 3,730 | Opus-rejected 125 | Tasmania 71 |
|----------------------------|----------:|------------------:|------------:|
| iNat research grade        | 66        | 22                | 2  |
| ALA field photo            | 177       | 93                | 0  |
| iNat "needs ID" photo      | 536       | 3                 | 12 |
| herbarium specimen only    | 1,494     | 5                 | 42 |
| nothing licensed           | 1,457     | 2                 | 15 |

So 2,273 species get candidates: 779 with a field photo first and 1,494
with specimens only, which Opus is expected to reject so that the
captioned fallback applies. (The Opus-rejected column comes from the
container dry run, whose copy of cands.parquet was stale. On the Mac only 13
of the 125 lead with an ALA field photo and 27 get nothing new: most of those
APII photos had been candidates already, and the gap never re-offers a photo
Opus has seen.) The first-pass facet counts in the thread (22
Tasmanian species with field photos) were inflated by the record-licence
issue and by synonym lumps (Hibbertia mathinnicola → H. calycina,
Acacia centrinervia → A. lineata), which `same_taxon` now refuses.

Specimen images: BRI, MEL, Te Papa (WELT), QVM, and those NSW AVH images that
carry their own CC licence. The NSW feed's UNSPECIFIED images stay out.

## The script

`refphotos_gap.py find → fetch → report` (resumable; v2/gap/). See its
docstring for the rules. Here's how it joins the v2 pipeline:

- `build_refphotos_v2.cand_table()` reads gap/cands.parquet. For a species
  listed there, the gap candidates REPLACE the old set, because Opus already
  judged the old one.
- `submit` re-asks Opus for a gap species whose candidates differ from those
  its stored result was judged on. Every other species keeps its result.
- `build` treats such a stale result as unresolved, never as a pick.
- Kind 4 = iNat outside the training set (source "inat"; the eval-photo
  assert covers it). ALA gap photos are kind 2 with pid 2^62 + hash.
- The build's fallback rule (herbarium sheet or hand-held sprig, captioned)
  is what turns an all-specimen candidate set into a photo. Each species keeps
  up to one specimen slot when field photos exist (≤ 4 field + specimens).
- index.json now carries `un` (plants.json ids) per photo, so the guide
  finds the photo by profile id. Without it the app falls back to name, then
  species. That costs 3 plants (spelling variants), so there's no need to
  re-upload a pack only for this field.

## Running it (Leo's Mac)

```bash
uv run --with duckdb --with pyarrow --with pandas --with numpy --with 'pillow>=11.3' \
    python3 -I pipeline/plantid/refphotos_gap.py find      # ~1.3 iNat req/species at 1/s
uv run … refphotos_gap.py fetch && uv run … refphotos_gap.py report
uv run … --with scikit-learn --with anthropic python3 -I pipeline/plantid/build_refphotos_v2.py submit --approve-spend
uv run … build_refphotos_v2.py collect --wait
uv run … build_refphotos_v2.py build
python3 pipeline/build_packs.py refphotos --verify refphotos
pipeline/upload_packs.sh refphotos@<sha256 prefix>   # Leo approves; every device re-downloads ~0.4 GB
```

## Result (Leo's Mac, 2026-11-07)

7,622 candidates over 2,247 species, all judged by Opus in 2 batches
(0 errors, $6.56). Pack: 18,373 → **20,605 photos** (+2,232), 0.44 GB
(was 0.41), `--verify`'d. 1,769 of them are captioned fallbacks: 1,656
herbarium specimens, 92 hand-held sprigs, 19 collected specimens and 1
labelled specimen. 42 species got no acceptable photo. In Tasmania, 56 of the
71 gaps now have a photo, 15 of them field photos. Spot check:

- good field photos: Brachyscome tasmanica, Oreobolus acutifolius, Hierochloe fraseri,
  Gaimardia fitzgeraldii, Isoetes humilior, Tetrarrhena oreophila and Hovea magnibractea;
- clean sheets: Poa hookeri, Cardamine gunnii and Ozothamnus gunnii;
- caption a little off: Agrostis australiensis is labelled "Hand-held sprig", but the photo shows a hand
  beside the grass.

Fixes made during the run: twin marks now come from v2-labels.json (au-labels.json
lacks them), and NaN text fields from parquet are written as null.
