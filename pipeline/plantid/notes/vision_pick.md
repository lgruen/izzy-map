# Vision pick: Claude chooses the reference photo (pilot, 2026-11-05)

`pipeline/plantid/vision_pick.py` shows Claude the candidates that
`build_refphotos.py` ranks for a label and asks for the best **reference**
photo, meaning the one that best helps a botanist recognise the species in the
field. For training classes the candidates are the ≤ 5 photos nearest the
BioCLIP class mean, in nearness order. For text-only classes they are the
first 5 snapshot candidates by build_refphotos rank. Claude can also answer
"none acceptable". The criteria are in `SYSTEM` in the script: sharp and well
exposed, whole plant or a diagnostic feature, plant as the clear subject, and
no hands, people, labels, specimens, screenshots or not-plant photos. The
output is a structured JSON (`output_config.format`) with a 1–5 score and
flags per photo, then `none_acceptable`, `chosen` (number or null) and a short
reason. Images go in as base64: the 500 px iNat "medium", about 260 tokens
each. Thinking stays adaptive with effort `low`. There is no
temperature/top_p. Requests run through the Message Batches API at 50 % price.
Results are keyed by `custom_id` = `u<label index>`, and stop_reason is
checked before the content is read.

Cache (gitignored, `pipeline/cache/`): `refphotos/vision/pilot.json`,
`vision/pilot/<model>/{batch.json,results.jsonl}`, `vision/pilot/compare.json`,
`vision/pilot/sheets/*.jpg`. Candidate photos that are not already in
`refphotos/src/` go to `refphotos/candidates/` (137 photos, 20 MB, 7 s).

```
uv run --with anthropic --with pyarrow --with numpy --with 'pillow>=11.3' \
    python3 -I pipeline/plantid/vision_pick.py \
    {select|fetch|submit|collect|compare|sheets} --pilot [--model opus|sonnet]
```

## Pilot set (50 labels, seed 20261105)

- 20 random labels with a pick.
- 8 eucalypts (Eucalyptus/Corymbia/Angophora) and 7 acacias.
- 15 suspect labels:
  - 8 training classes with the lowest BioCLIP margin on the current pick. The
    margin is cos("a photo of a plant in its natural habitat.") −
    cos("a photo of a hand holding a plant."), using the text vectors in
    `refine/qtext.npz`. The selected margins run from −0.033 to −0.014. Across
    all classes, p1 = 0.018 and the median is 0.106.
  - 7 random text-only (snapshot) classes.

Candidates per label in the pilot: 33 had 5, 1 had 4, 2 had 3, 10 had 2 and 4
had 1. Over all 16,325 labels: 11,498 have 5, 684 have 4, 923 have 3, 1,300
have 2 and 1,920 have 1.

## Results: claude-opus-5-5 vs claude-sonnet-5-5 (effort low, batch)

| | Opus 5.5 | Sonnet 5.5 |
|---|---|---|
| succeeded / refusals / errors | 50 / 0 / 0 | 50 / 0 / 0 |
| mean input / output tokens | 2,169 / 165 | 2,169 / 180 |
| measured cost per label (batch) | **$0.00598** | **$0.00307** |
| pilot cost | $0.299 | $0.154 |
| full run, 16,325 labels (batch) | **≈ $98–99** | **≈ $50–51** |
| "none acceptable" | 2 (Acacia calantha, Bossiaea dasycarpa) | 1 (Acacia calantha) |
| chose the current pick | 17 / 50 | 17 / 50 |
| batch turnaround | 2.5 min | 17.5 min |

The full-run figure fits the measured tokens as input ≈ 1,129 + 261·n and
output ≈ 100 + 17–20·n, where n is the number of candidates, and applies that
to the full candidate-count distribution. The simple mean × 16,325 gives the
same answer ($97.7 / $50.1). Each label is one request, and 50 requests are
38.5 MB, so the full run is about 12.6 GB of base64. That is about 55 batches
at the 256 MB limit, or the photos go through the Files API.

The models agree on the chosen photo for **40 / 50** labels (80 %). They
agree on 27 / 36 (75 %) of the labels with ≥ 3 candidates, where a choice
actually exists. They agree on "none acceptable" for 49 / 50 (98 %). By group,
the agreement is 7/7 acacias, 6/8 eucalypts, 16/20 random, 5/8 low-margin and
6/7 text-only.

**The current pick has a disqualifying flag in 12 / 50 labels**: hand, person,
label, specimen or not-plant, mostly hands. Both models flag the same 12. That
is 3 / 20 of the random labels, which suggests ~15 % of all picks. In every
such case both models moved away from it, or declared none. Both models
flagged 29 hands across the 199 candidates.

### Disagreements (10), judged by eye on the contact sheets

| label | Opus | Sonnet | verdict |
|---|---|---|---|
| Bossiaea dasycarpa | none (fingers in both) | #2 (fingertip at the bottom edge, clear flower) | tie: Opus follows the rule as written; Sonnet's photo is still a useful reference |
| Denhamia celastroides | #2 leaves, flash, dark background | #4 leaf arrangement | tie |
| Eremophila decipiens | #3 one flower + leaves | #2 several flowers + habit | Sonnet slightly better |
| Eucalyptus amplifolia | #1 adult leaves + bark | #2 bark + juvenile foliage | tie |
| Eucalyptus annulata | #1 crisp horn-shaped bud cluster | #5 buds, smaller and busier | Opus better |
| Eucalyptus pterocarpa | #2 winged buds/fruit (diagnostic) | #1 flowers + buds (the current pick) | tie (both excellent) |
| Eucalyptus pyrocarpa | #1 trunk with smooth bark and rough stocking | #3 foliage against the sky on a rock, little to recognise | Opus better |
| Maclura cochinchinensis | #2 isolated spiny branch | #4 busy leafy tangle | Opus better |
| Maireana cheelii | #4 whole-plant habit | #5 close-up of the winged fruiting perianths | tie |
| Eragrostis minor | #1 habit with panicles | #4 panicle close-up (the current pick) | tie |

**Opus better 3, Sonnet better 1, tie 6.** Most disagreements are between two
good photos. Opus's three wins are real (pyrocarpa especially), but the
sample is small. Both models' reasons are sensible and botanically literate,
for example "winged fruiting perianths" and "rough basal stocking". The 12
random agreements on `agree-*.jpg` all look right to me.

## Takeaways

- Both models reliably catch the failure that motivated this: hands. Every
  hand-held current pick in the pilot was replaced. "None acceptable" is rare
  (1–2 / 50), and only fires when every candidate is hand-held.
- Sonnet 5.5 costs half as much (~$50 vs ~$99 for the full run at batch price)
  and agrees with Opus 80 % of the time. When they differ, Opus is a little
  better more often than not.
- Possible savings: skip the 1,920 single-candidate labels unless we want
  their "none" verdict, or send only labels whose current pick BioCLIP flags.
  Either needs a decision before spending.
- Not run: the full job. That needs Leo's approval of the cost (`submit`
  without `--pilot` requires `--approve-spend`).

Pilot spend: $0.299 (Opus batch) + $0.154 (Sonnet batch) + ~$0.007 (one
synchronous Sonnet smoke request at standard price) = **≈ $0.46**.
