# APC ↔ iNaturalist name matching for the Australia-wide labels

2026-11-05 · `pipeline/plantid/resolve_names.py` (fetch → resolve → verify) ·
outputs in `pipeline/cache/plantid/names/` (gitignored): `apc_inat_map.json`
(one entry per photo-less label), `summary.json`, `residue.json`
(undecided candidates with evidence), `adjudication.json` (hand
decisions), `verify.json` (live spot check). Evaluation / data prep only —
nothing here ships, no existing file was changed.

## Problem

`ship/au-labels.json` has 22,122 labels; **6,354 have no training photo**
(`train_photos` 0), and **1,733** of those have no iNat taxon at all (the
caller's count was 1,738; the label file on disk today gives 1,733). The eval
(`eval_australia.py labels`) matched APC names to the iNat snapshot by the
accepted name plus APC synonyms of **species rank only, used only when
unambiguous**. Each name mismatch costs a species its photos.

## Method

Deterministic first, judgement only for the residue.

1. **Candidates** (every candidate is an *active* taxon of the local iNat
   snapshot `sets/work.duckdb` — species, subspecies, variety, form or
   hybrid — or a taxon id an API returned):
   - **APC synonyms of all ranks** (taxonomic/nomenclatural synonym,
     basionym, orthographic variant, replaced synonym; misapplied and
     excluded names never). New over the eval: infraspecific synonyms
     ("*Melaleuca micrantha* var. *puberula*" for *Beaufortia puberula*) —
     iNat keeps many APC species as infraspecies. Pro-parte / doubtful
     synonyms are candidates but never decide alone.
   - **iNat taxon swaps**: every *inactive* snapshot taxon named like a label
     or one of its APC synonyms → `/v1/taxa/{ids}` (30 per request) →
     `current_synonymous_taxon_ids`, chains followed.
   - **iNat synonym search** `/v1/taxa?q=<APC name>` (`matched_term` = a
     non-valid name iNat files under another taxon) for labels without an
     iNat taxon and without an APC-synonym / swap candidate.
   - **Orthographic keys** within the genus: gender endings
     (-us/-a/-um, -is/-e, -er/-ra/-rum, -ris/-re), -i/-ii, -ae/-iae, hyphens.
     Two epithets of one genus that share a key are the same name.
   - **GBIF backbone** `species/match` (verbose, kingdom Plantae): the
     accepted name when GBIF calls the APC name a synonym, plus
     `/species/{key}/synonyms`.
   - **Same epithet, same family, other genus** (genus transfers), with a
     *genus-pair support* count: how many other labels already link that
     (APC genus, iNat genus) pair through a mapping or an iNat swap
     (Leptospermum→Gaudium, Corunastylis→Genoplesium, Hibiscus→Sabdariffa…).
2. **Ownership**: a candidate whose species already feeds another label
   (`australia/inat_map.parquet`) is not free. Three cases:
   - the other label is a **shipped Tasmanian extra class** (not an APC
     name, e.g. "*Gaudium laevigatum*", "*Cycnogeton procerus*") → the same
     species sits in U twice → `photo_flow: merge` (photos already flow to
     the extra class; the fix is to merge the two classes);
   - the candidate's name is **another APC accepted species and the APC
     synonym has a different author** → **homonym** (e.g. APC lists
     "*Lobelia stenophylla*" (F.Muell.) as a synonym of *Goodenia
     stenophylla*, but iNat's *Lobelia stenophylla* is Bentham's species) →
     `none`;
   - otherwise iNat lumps two APC species → **lump**, nothing flows.
3. **Deterministic rule**: exactly one distinct strong candidate (APC
   non-pro-parte synonym, iNat swap, iNat synonym search, same-genus
   orthographic key), free, its name not belonging to another APC species,
   and ≥ 50 % of its research-grade observations in Australia (skipped when
   iNat swapped the APC name itself — widespread species are mostly
   observed abroad; ≥ 25 % for infraspecies/hybrids) → mapped. An iNat
   swap into several current taxa → `split` (APC broader), parts with no
   Australian record or < 50 % Australian dropped, an infraspecies of
   another part dropped (already in its roll-up). Two labels newly mapped
   onto one taxon → the one whose name is the taxon's keeps it, the others
   become `lump` (collision).
4. **Adjudication** (`adjudication.json`, written by Claude, every id an API
   or the snapshot returned; evidence recorded per entry) for the residue
   whose candidates carry photos. Rules applied consistently:
   - a GBIF-only synonymy is accepted only if the iNat taxon has Australian
     research-grade observations (iNat users file Australian plants under
     it) and the name is not another APC species; GBIF-only with no
     Australian record → `none` (*Malaccotristicha australis*→*Tristicha
     trifaria*, *Eulalia trispicata*, *Perrottetia arborescens*, *Serjania
     exarata*); when iNat ALSO lists the APC name under that taxon it is
     accepted even without Australian records (*Nervilia crociformis*→*N.
     simplex*, *Najas foveolata*→*N. indica*: photos all extralimital);
   - same-epithet genus transfers need genus-pair support > 0, the same
     family, all-Australian observations and no other claim;
   - iNat swaps of APC synonyms that land on an extralimital taxon with no
     Australian record are homonyms of the APC synonym, → `none`
     (*Pterostylis polyphylla* → NZ *P. micromega*; *Cladium australe* →
     NZ *Lepidosperma australe*; *Poa concinna* → *Poa perconcinna*);
   - two APC species sunk into one iNat/GBIF taxon → `lump`.

Relations in `apc_inat_map.json`: `exact` (existing same-name mapping, still
no photo), `synonym` (iNat accepts another name; `inat_rank` ≠ species means
iNat keeps it as an infraspecies or a hybrid — then `photo_flow: subtree`:
only observations identified to that taxon flow, and they should leave the
parent APC class, which today receives them through the species roll-up),
`orthographic`, `split`, `lump` (no flow), `none`. `method`:
`deterministic` | `adjudicated`. `photos` = research-grade observations
(`rg`, `rg_au`), with a CC0/BY/BY-NC unshared photo (`usable`), and of those
by pool-role observers (`pool`, `pool_au`) — the train-eligible set of
`eval_australia.py plan` (which caps a class at 100).

## Results

All numbers measured on 2026-11-05 (snapshot `sets/work.duckdb`, iNat
open data of 2026-10-28; APC export of 2026-11-04).

**API pass**: 178 iNat id batches (5,316 ids), 1,428 iNat synonym searches
(305 labels skipped: an APC-synonym or swap candidate already existed),
GBIF match + synonyms for the 1,733 labels without an iNat taxon (~3,900
GBIF requests; 1.8 k extra matches from a first run). ~33 min wall clock
in total (iNat ~1 req/s; GBIF answered in 0.9–2 s, 6 threads). Everything is
cached under `names/{inat_ids,inat_q,gbif_match,gbif_syn}/` (30 MB);
`resolve` reruns from cache in < 1 min. `fetch --gbif-all` would add GBIF
keys for the 4,621 photo-less labels that already have an iNat taxon (not
run: ~1 h at GBIF's current latency, and they only fill `gbif_taxon_key`).

**Counts over the 6,354 photo-less labels**

| relation | deterministic | adjudicated | note |
|---|---|---|---|
| exact (existing mapping) | 4,475 | – | same name in iNat; 2,090 of the 4,602 existing mappings have 0 iNat observations of any grade, 2,512 have some but no research-grade pool photo with a CC0/BY/BY-NC licence — not name problems |
| synonym (existing) | 127 | – | existing mapping through an APC synonym |
| **synonym** (new) | 304 | 25 | iNat swap 204 (+12 hybrid, +11 infraspecies), iNat synonym search 46 (+1 infraspecies), APC infraspecific synonyms 21, duplicates 9 |
| **orthographic** (new) | 33 | 8 | gender endings (15 *Psydrax*, 4 *Cycnogeton*), -i/-ii, *Lechenaultia*/*Leschenaultia*, *Trema* |
| **split** (new) | 4 | – | APC species = existing iNat taxon + another (e.g. *Syzygium cryptophlebium* + *S. wilsonii* subsp. *cryptophlebium*) |
| **lump** | 78 | 9 | iNat (or GBIF) sinks the APC species into a taxon that feeds another APC label — nothing flows |
| none | 1,291 | – | 869 no candidate at all (GBIF: 835 ACCEPTED — iNat simply has no such taxon), 414 only weak candidates (same epithet elsewhere in the family, pro-parte synonyms, extralimital), 8 homonyms |

**Duplicates in U** (`photo_flow: merge`, 14): the APC native and a shipped
Tasmanian extra class are one species — *Leptospermum laevigatum* =
*Gaudium laevigatum*, *L. glaucescens*, *Callistemon citrinus* = *Melaleuca
citrina*, *Blechnum cartilagineum* = *Oceaniopteris cartilaginea*, *B.
deltoides*, *Cycnogeton procerum*, *Deyeuxia brachyathera/contracta/
quadriseta/rodwayi*, *Dichelachne crinita*, *Ewartia meredithiae*,
*Androstoma verticillata*, *Pachycladon radicata*. Their photos (6,731 pool)
already train the extra class; the fix is to merge the two classes (the
Tasmanian head keeps its label), not to copy photos.

**Adjudicated: 42** (`adjudication.json`; 25 synonym, 8 orthographic, 9
lump; ~10 more left `none` on purpose, listed above). One deterministic
call was overridden: *Corunastylis tepperi* — iNat's name search files it
under *Genoplesium nigricans* (a lump), but iNat also keeps an active *G.
tepperi* with 107 Australian observations, so the label maps there.

**Verification** (`verify`, 40 random new mappings with a taxon id,
re-queried live with `all_names=true`): 40/40 ids resolve to the recorded
name, active, Plantae; families equal in 35 (the other 5 are APC vs iNat
family circumscriptions: Portulacaceae/Montiaceae, Chenopodiaceae/
Amaranthaceae); the APC name is among iNat's own names for the taxon in
38/40 — the two others are a lump (*Bossiaea cinerea* extra label → *B.
cordifolia* via APC synonymy) and *Dendrobium stuartii* → *D.
macrostachyum* (GBIF/WCVP only, iNat does not list it). My judgement: 40/40
point at the right iNat taxon for the name; 39/40 are concept-equal (*D.
stuartii* imports a broader concept). Precision estimate ≈ 97 % (39/40;
Wilson 95 % interval 87–100 %) — a small sample. One labelling nit found:
*Eriocaulon aloefolium*→*aloifolium* is recorded `synonym`, not
`orthographic` (the ortho keys do not cover -e-/-i- linking vowels).

**Payoff** (research-grade iNat observations in the snapshot, first CC0/BY/
BY-NC photo, not shared, pool-role observer = the plan's train-eligible
set):

- **256 photo-less labels would gain training photos** (253 of them had no
  iNat taxon at all; all 256 are APC natives), **29,973 photos**, 18,701 of
  them Australian; with the plan's cap of 100 per class **7,646**. Tiers:
  50 labels ≥ 100 photos, 36 with 20–99, 83 with 5–19, 87 with 1–4. 9 more
  gain usable photos only from val/test observers.
- By relation: synonym 228 labels (25,143 photos; 24 adjudicated, 1,342),
  orthographic 26 (4,795; 8 adjudicated, 1,960), split 2 (35).
- Biggest: *Leptospermum myrsinoides*→*Gaudium* (2,588), *Trema orientalis*
  (1,902), *Cenchrus purpurascens*→*C. alopecuroides* (1,839), *Trema
  tomentosa* (1,806), *Pneumatopteris pennigera*→*Pakau* (1,541), *Cissus
  antarctica / hypoglauca*→*Apocissus*, *Pueraria lobata*→*P. montana* var.
  *lobata*, *Geodorum densiflorum*→*Eulophia picta*, *Hibiscus*→*Sabdariffa*.
- Eucalypts: only 12 labels gain (55 photos) — mostly APC species iNat
  treats as hybrids (*E.* × *silvestris*, × *carolaniae*, …) or
  infraspecies (*E. leucoxylon* subsp. *petiolaris*); the eucalypt gap is
  rarity, not names.
- 46 mappings flow from an iNat **infraspecies** (`photo_flow: subtree`);
  those observations currently also feed the parent APC class through the
  species roll-up and should be removed from it when the label takes them.

**What this does not cover**: photo-less labels whose iNat taxon exists
but has no research-grade CC photo (4,602) — a data gap, not a naming one;
non-research-grade observations; the 414 weak-candidate labels were not
read one by one (only those whose candidates carry photos — `residue.json`
has them all); the deterministic rules were spot-checked, not exhaustively
reviewed. "No candidate" means none of these six sources found one, not
that iNat has no photos of the plant under some name nobody linked.
