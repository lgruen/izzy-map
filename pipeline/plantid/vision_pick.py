#!/usr/bin/env python3
"""Let Claude choose the offline reference photo per plant-ID label
(notes/vision_pick.md): show it the candidates build_refphotos.py ranks (the
5 training photos nearest the class's BioCLIP 2.5 mean; text-only classes:
the first 5 snapshot candidates) and ask for the best REFERENCE photo — one
that helps a botanist recognise the species in the field — or none.

Subcommands (in order):

  select   the class set. --pilot: 50 classes (20 random, 15 eucalypts/
           acacias, 15 suspect = lowest BioCLIP margin "plant in its natural
           habitat" − "hand holding a plant" on the current pick (8, training
           classes, text vectors from refine/qtext.npz) + 7 text-only
           classes) → vision/pilot.json. Without --pilot: every class with a
           pick.
  fetch    the 500 px "medium" of every candidate not on disk yet (photos
           already in refphotos/src/ are used in place) →
           refphotos/candidates/<photo_id>.<ext>.
  submit   one Message Batch (Batches API, 50 % price) per --model with one
           request per class: structured output (score 1–5 + flags per
           photo, chosen photo or null, reason). Batch id →
           vision/<run>/<model>/batch.json; refuses to resubmit. A full run
           (no --pilot) needs --approve-spend (Leo's go-ahead).
  collect  fetch the results once (or --wait: re-check every --every s, at
           most --max-wait s) → vision/<run>/<model>/results.jsonl (keyed by
           custom_id = "u<label index>"), with usage and cost.
  compare  agreement between models (and with the current pick), "none
           acceptable" rates, measured cost per class, extrapolation to
           every class at batch price → vision/<run>/compare.json.
  sheets   Pillow contact sheets: disagreements + 12 random agreements →
           vision/<run>/sheets/*.jpg.

The API key is read from ~/.config/izzymap/anthropic.env (ANTHROPIC_API_KEY=…)
into this process only; it is never printed or written anywhere.

Environment:
  uv run --with anthropic --with pyarrow --with numpy --with 'pillow>=11.3' \\
      python3 -I pipeline/plantid/vision_pick.py <subcommand> [--pilot] [--model opus|sonnet]
"""
import argparse
import base64
import collections
import json
import os
import random
import sys
import time

import numpy as np
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_refphotos as BR  # noqa: E402

VIS = os.path.join(BR.OUT, "vision")
CAND = os.path.join(BR.OUT, "candidates")
KEYFILE = os.path.expanduser("~/.config/izzymap/anthropic.env")
MODELS = {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"}
# USD per million tokens at BATCH price (50 % of standard): input, output, cache write (5 min), cache read
PRICE = {"claude-opus-5-5": (2.00, 10.00, 2.50, 0.10),
         "claude-sonnet-5-5": (1.00, 5.00, 1.25, 0.10),
         "claude-haiku-5-5": (0.05, 0.25, 0.0625, 0.005)}
K = 5
FLAGS = ["hand", "person", "specimen", "label", "blurry", "not_plant", "other"]

SYSTEM = """You choose reference photos for an offline plant field guide used by a botanist in Australia.
For each species you see up to five candidate photos (iNaturalist observations identified as that species).
Choose the single best REFERENCE photo: the one that best helps someone recognise this species in the field.

A good reference photo:
- is sharp and well exposed;
- shows the whole plant or a diagnostic feature (flowers, fruit or capsules, buds, leaves, bark), ideally the plant's typical look;
- has the plant as the clear subject.

Not acceptable as a reference photo: a hand or fingers holding or touching the plant, people, labels/signs/rulers with text, pressed or herbarium specimens, screenshots or photos of book pages or screens, photos where the plant is not the clear subject, badly blurred or very dark photos, photos that do not show a plant.

Score every photo 1-5 (5 = excellent reference, 3 = usable but mediocre, 1 = unusable) and flag problems:
hand, person, specimen (pressed/herbarium), label (sign, label, text), blurry (or very dark/overexposed), not_plant (no plant visible or plant not the subject), other (anything else that makes it a poor reference; explain in the reason).
Then choose the best photo by its number. If NONE of the photos is acceptable as a reference (every one has a disqualifying problem), set chosen to null and none_acceptable to true.
Do not try to verify the identification; judge photo quality and usefulness only. Keep the reason to one or two short sentences."""


def load_key():
    """ANTHROPIC_API_KEY into this process's environment (never printed)."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        return
    with open(KEYFILE) as f:
        for line in f:
            line = line.strip()
            if line.startswith("ANTHROPIC_API_KEY="):
                os.environ["ANTHROPIC_API_KEY"] = line.split("=", 1)[1].strip().strip('"').strip("'")
                return
    sys.exit(f"no ANTHROPIC_API_KEY line in {KEYFILE}")


def client():
    import anthropic
    load_key()
    return anthropic.Anthropic()


def run_dir(a):
    return os.path.join(VIS, "pilot" if a.pilot else "full")


def model_id(a):
    return MODELS.get(a.model, a.model)


# ------------------------------------------------------------------ candidates

def candidate_pool():
    """label index → ordered candidate rows (≤ K): training classes by nearness
    to the class mean (the pool build_refphotos ranks), text-only classes by
    build_refphotos' rank. Photos gone upstream are left out."""
    gone = BR.unavailable()
    t = pq.read_table(os.path.join(BR.OUT, "candidates.parquet")).to_pylist()
    by = collections.defaultdict(list)
    for r in t:
        if r["photo_id"] not in gone:
            by[r["u"]].append(r)
    out = {}
    for u, rs in by.items():
        if rs[0]["via"] == "train":
            rs.sort(key=lambda r: r["near"])
        else:
            rs.sort(key=lambda r: r["rank"])
        out[u] = rs[:K]
    return out


def photo_path(r):
    for d in (BR.SRC, CAND):
        p = os.path.join(d, f"{r['photo_id']}.{r['ext']}")
        if os.path.exists(p):
            return p
    return None


def class_set(a):
    if a.pilot:
        return json.load(open(os.path.join(VIS, "pilot.json")))["classes"]
    return sorted(candidate_pool())


def cmd_select(a):
    os.makedirs(VIS, exist_ok=True)
    pool = candidate_pool()
    P = BR.picks()
    names = {u: rs[0]["name"] for u, rs in pool.items()}
    if not a.pilot:
        print(f"{len(pool):,} classes with candidates (full run: no selection file needed)")
        return
    rng = random.Random(20261105)
    train = sorted(u for u, rs in pool.items() if rs[0]["via"] == "train" and len(rs) >= 2)
    snap = sorted(u for u, rs in pool.items() if rs[0]["via"] == "snapshot")
    # suspect: BioCLIP margin on the current pick (training classes; embeddings exist for them)
    q = np.load(os.path.join(BR.OUT, "refine", "qtext.npz"))
    prompts = list(q["prompt"])
    tg = q["emb"][prompts.index("a photo of a plant in its natural habitat.")]
    th = q["emb"][prompts.index("a photo of a hand holding a plant.")]
    ids, E = BR.all_embeddings()
    pick_ids = np.array([P[u]["photo_id"] for u in train], np.int64)
    i = np.searchsorted(ids, pick_ids).clip(0, len(ids) - 1)
    assert (ids[i] == pick_ids).all()
    X = E[i].astype(np.float32)
    X /= np.linalg.norm(X, axis=1, keepdims=True)
    margin = X @ tg - X @ th
    order = np.argsort(margin)
    chosen, groups = [], {}

    def take(us, n, g):
        k = 0
        for u in us:
            if k == n:
                break
            if u not in chosen:
                chosen.append(u)
                groups[u] = g
                k += 1

    take([train[j] for j in order], 8, "suspect-margin")
    take(rng.sample(snap, len(snap)), 7, "suspect-textonly")
    euc = [u for u in train if names[u].split()[0] in ("Eucalyptus", "Corymbia", "Angophora")]
    aca = [u for u in train if names[u].split()[0] == "Acacia"]
    take(rng.sample(euc, len(euc)), 8, "eucalypt")
    take(rng.sample(aca, len(aca)), 7, "acacia")
    allu = sorted(pool)
    take(rng.sample(allu, len(allu)), 20, "random")
    mg = dict(zip(train, margin.tolist()))
    out = {"classes": chosen, "groups": {str(u): groups[u] for u in chosen},
           "names": {str(u): names[u] for u in chosen},
           "margin": {str(u): round(mg[u], 4) for u in chosen if u in mg},
           "margin_quantiles": {p: round(float(np.quantile(margin, p / 100)), 4) for p in (1, 5, 50, 95)}}
    json.dump(out, open(os.path.join(VIS, "pilot.json"), "w"), indent=1)
    print(f"{len(chosen)} classes: {dict(collections.Counter(groups.values()))}; "
          f"margin quantiles {out['margin_quantiles']}")
    for u in chosen[:8]:
        print(f"  {names[u]}: margin {mg[u]:.4f}")


def cmd_fetch(a):
    pool = candidate_pool()
    us = class_set(a)
    todo = sorted({(r["photo_id"], r["ext"]) for u in us for r in pool[u] if photo_path(r) is None})
    print(f"{len(us):,} classes, {sum(len(pool[u]) for u in us):,} candidates, {len(todo):,} to fetch", flush=True)
    if not todo:
        return
    os.makedirs(CAND, exist_ok=True)
    src, BR.SRC = BR.SRC, CAND  # fetch_many writes into BR.SRC; point it at our cache for this call
    try:
        t0 = time.time()
        s = BR.fetch_many(todo, a.workers)
    finally:
        BR.SRC = src
    print(f"  {s['ok']:,} ok ({s['bytes'] / 1e6:.1f} MB) in {time.time() - t0:.1f} s; "
          f"{s['missing']} gone upstream {s['gone'][:10]}, {s['failed']} failed", flush=True)
    if s["gone"]:
        print("  (gone photos are skipped from the request; not written to unavailable.json)")


# ------------------------------------------------------------------ requests

def media_type(b):
    if b.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if b.startswith(b"\x89PNG"):
        return "image/png"
    if b.startswith(b"GIF8"):
        return "image/gif"
    if b.startswith(b"RIFF") and b[8:12] == b"WEBP":
        return "image/webp"
    raise ValueError("unknown image type")


def schema(n):
    nums = list(range(1, n + 1))
    return {
        "type": "object",
        "properties": {
            "photos": {"type": "array", "items": {
                "type": "object",
                "properties": {"photo": {"type": "integer", "enum": nums},
                               "score": {"type": "integer", "enum": [1, 2, 3, 4, 5]},
                               "flags": {"type": "array", "items": {"type": "string", "enum": FLAGS}}},
                "required": ["photo", "score", "flags"], "additionalProperties": False}},
            "none_acceptable": {"type": "boolean"},
            "chosen": {"anyOf": [{"type": "integer", "enum": nums}, {"type": "null"}]},
            "reason": {"type": "string"}},
        "required": ["photos", "none_acceptable", "chosen", "reason"],
        "additionalProperties": False}


def request_params(model, name, rows):
    content = [{"type": "text", "text": f"Species: {name}. {len(rows)} candidate photos follow."}]
    for k, r in enumerate(rows, 1):
        b = open(photo_path(r), "rb").read()
        content.append({"type": "text", "text": f"Photo {k}:"})
        content.append({"type": "image", "source": {"type": "base64", "media_type": media_type(b),
                                                    "data": base64.standard_b64encode(b).decode()}})
    content.append({"type": "text", "text": "Score every photo, then choose the best reference photo "
                                            "for this species (or null if none is acceptable)."})
    return {"model": model, "max_tokens": 4096, "system": SYSTEM,
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": schema(len(rows))}},
            "messages": [{"role": "user", "content": content}]}


def requests_for(a):
    pool = candidate_pool()
    us = class_set(a)
    reqs, shown = [], {}
    for u in us:
        rows = [r for r in pool[u] if photo_path(r)]
        if not rows:
            continue
        shown[f"u{u}"] = [r["photo_id"] for r in rows]
        reqs.append({"custom_id": f"u{u}", "params": request_params(model_id(a), rows[0]["name"], rows)})
    return reqs, shown


def cmd_submit(a):
    d = os.path.join(run_dir(a), a.model)
    os.makedirs(d, exist_ok=True)
    bj = os.path.join(d, "batch.json")
    if os.path.exists(bj):
        sys.exit(f"already submitted: {json.load(open(bj))['id']} (delete {bj} to resubmit)")
    if not a.pilot and not a.approve_spend:
        sys.exit("a full run needs --approve-spend (measure with --pilot first; Leo approves the cost)")
    reqs, shown = requests_for(a)
    mb = sum(len(json.dumps(r)) for r in reqs) / 1e6
    print(f"{len(reqs)} requests, {mb:.1f} MB, model {model_id(a)}", flush=True)
    if a.smoke:  # one synchronous request (standard price) to validate the request shape
        c = client()
        m = c.messages.create(**reqs[0]["params"])
        print(m.stop_reason, m.usage.to_dict())
        print(next((b.text for b in m.content if b.type == "text"), "")[:600])
        return
    c = client()
    b = c.messages.batches.create(requests=reqs)
    json.dump({"id": b.id, "model": model_id(a), "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
               "requests": len(reqs), "shown": shown}, open(bj, "w"), indent=1)
    print(f"batch {b.id}: {b.processing_status}")


def cost(model, u):
    pi, po, pw, pr = PRICE[model]
    return (u.get("input_tokens", 0) * pi + u.get("output_tokens", 0) * po
            + (u.get("cache_creation_input_tokens") or 0) * pw + (u.get("cache_read_input_tokens") or 0) * pr) / 1e6


def cmd_collect(a):
    d = os.path.join(run_dir(a), a.model)
    meta = json.load(open(os.path.join(d, "batch.json")))
    c = client()
    t0 = time.time()
    while True:
        b = c.messages.batches.retrieve(meta["id"])
        rc = b.request_counts
        print(f"{time.strftime('%H:%M:%S')} {b.processing_status}: processing {rc.processing}, "
              f"succeeded {rc.succeeded}, errored {rc.errored}", flush=True)
        if b.processing_status == "ended" or not a.wait or time.time() - t0 > a.max_wait:
            break
        time.sleep(a.every)
    if b.processing_status != "ended":
        print("not ended yet; run collect again later")
        return
    out, tot = [], 0.0
    for res in c.messages.batches.results(meta["id"]):
        rec = {"custom_id": res.custom_id, "type": res.result.type}
        if res.result.type == "succeeded":
            m = res.result.message
            u = m.usage.to_dict()
            rec.update(model=m.model, stop_reason=m.stop_reason, usage=u, cost=cost(meta["model"], u))
            tot += rec["cost"]
            if m.stop_reason == "refusal":
                rec["refusal"] = m.stop_details.to_dict() if getattr(m, "stop_details", None) else None
            elif m.stop_reason == "end_turn":
                txt = next((x.text for x in m.content if x.type == "text"), "")
                try:
                    rec["out"] = json.loads(txt)
                except ValueError:
                    rec["raw"] = txt
        else:
            err = getattr(res.result, "error", None)
            rec["error"] = err.to_dict() if err is not None and hasattr(err, "to_dict") else str(err)
        out.append(rec)
    out.sort(key=lambda r: int(r["custom_id"][1:]))
    with open(os.path.join(d, "results.jsonl"), "w") as f:
        for r in out:
            f.write(json.dumps(r) + "\n")
    print(f"{len(out)} results, {collections.Counter(r['type'] for r in out)}, "
          f"stop {collections.Counter(r.get('stop_reason') for r in out)}; cost ${tot:.4f} "
          f"(${tot / max(len(out), 1):.5f} per class)")


# ------------------------------------------------------------------ compare

def load_results(a, model):
    d = os.path.join(run_dir(a), model)
    meta = json.load(open(os.path.join(d, "batch.json")))
    res = {}
    for line in open(os.path.join(d, "results.jsonl")):
        r = json.loads(line)
        o = r.get("out")
        shown = meta["shown"][r["custom_id"]]
        if o is not None:
            ch = o["chosen"]
            r["chosen_id"] = shown[ch - 1] if isinstance(ch, int) and 1 <= ch <= len(shown) else None
            r["none"] = ch is None
            r["consistent"] = (ch is None) == bool(o["none_acceptable"])
        res[r["custom_id"]] = r
    return meta, res


def cmd_compare(a):
    rd = run_dir(a)
    models = [m for m in a.models.split(",") if os.path.exists(os.path.join(rd, m, "results.jsonl"))]
    P = BR.picks()
    pilot = json.load(open(os.path.join(VIS, "pilot.json"))) if a.pilot else None
    n_full = len(candidate_pool())
    R, s = {}, {"models": {}, "full_classes": n_full}
    for m in models:
        meta, res = load_results(a, m)
        R[m] = res
        ok = [r for r in res.values() if "out" in r]
        us = [r["usage"] for r in res.values() if "usage" in r]
        cs = [r["cost"] for r in res.values() if "cost" in r]
        per = float(np.mean(cs)) if cs else 0.0
        s["models"][m] = {
            "model": meta["model"], "results": len(res), "parsed": len(ok),
            "refusals": sum(r.get("stop_reason") == "refusal" for r in res.values()),
            "errors": sum(r["type"] != "succeeded" for r in res.values()),
            "none_acceptable": sum(r["none"] for r in ok),
            "inconsistent_none_flag": sum(not r["consistent"] for r in ok),
            "same_as_current_pick": sum(r["chosen_id"] == P[int(k[1:])]["photo_id"] for k, r in res.items()
                                        if "out" in r and r["chosen_id"]),
            "mean_input_tokens": round(float(np.mean([u["input_tokens"] for u in us])), 1),
            "mean_output_tokens": round(float(np.mean([u["output_tokens"] for u in us])), 1),
            "total_cost_usd": round(sum(cs), 4), "cost_per_class_usd": round(per, 5),
            "full_run_usd_batch": round(per * n_full, 2)}
    if len(models) == 2:
        A, B = (R[m] for m in models)
        keys = sorted(set(A) & set(B), key=lambda k: int(k[1:]))
        both = [k for k in keys if "out" in A[k] and "out" in B[k]]
        same = [k for k in both if A[k]["chosen_id"] == B[k]["chosen_id"]]
        s["pair"] = {"models": models, "both_parsed": len(both), "same_choice": len(same),
                     "same_choice_rate": round(len(same) / max(len(both), 1), 3),
                     "both_none": sum(A[k]["none"] and B[k]["none"] for k in both),
                     "none_only_" + models[0]: sum(A[k]["none"] and not B[k]["none"] for k in both),
                     "none_only_" + models[1]: sum(B[k]["none"] and not A[k]["none"] for k in both),
                     "none_agreement_rate": round(sum(A[k]["none"] == B[k]["none"] for k in both)
                                                  / max(len(both), 1), 3),
                     "disagreements": [k for k in both if k not in same]}
        if pilot:
            g = collections.defaultdict(lambda: [0, 0])
            for k in both:
                gg = pilot["groups"][k[1:]]
                g[gg][1] += 1
                g[gg][0] += k in same
            s["pair"]["same_by_group"] = {k: f"{v[0]}/{v[1]}" for k, v in g.items()}
    json.dump(s, open(os.path.join(rd, "compare.json"), "w"), indent=1)
    print(json.dumps(s, indent=1))


# ------------------------------------------------------------------ sheets

def cmd_sheets(a):
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    rd = run_dir(a)
    models = a.models.split(",")
    R = {m: load_results(a, m)[1] for m in models}
    meta = json.load(open(os.path.join(rd, models[0], "batch.json")))
    P = BR.picks()
    pool = candidate_pool()
    cmp_ = json.load(open(os.path.join(rd, "compare.json")))
    dis = cmp_["pair"]["disagreements"]
    agree = [k for k in meta["shown"] if k not in dis and all("out" in R[m].get(k, {}) for m in models)]
    rng = random.Random(7)
    agree = rng.sample(agree, min(12, len(agree)))
    os.makedirs(os.path.join(rd, "sheets"), exist_ok=True)
    TH, PAD, W = 260, 8, 5
    font = ImageFont.load_default(size=15)
    big = ImageFont.load_default(size=19)
    COL = {models[0]: (220, 40, 40), models[1]: (30, 110, 230)}
    names = {f"u{u}": rs[0]["name"] for u, rs in pool.items()}

    def row(k):
        shown = meta["shown"][k]
        cur = P[int(k[1:])]["photo_id"]
        rows = {r["photo_id"]: r for r in pool[int(k[1:])]}
        cw = TH + PAD
        im = Image.new("RGB", (PAD + W * cw, TH + 150), "white")
        d = ImageDraw.Draw(im)
        hdr = f"{names[k]}  ({k})"
        d.text((PAD, 4), hdr, fill="black", font=big)
        y0 = 30
        for j, pid in enumerate(shown):
            x = PAD + j * cw
            t = ImageOps.contain(Image.open(photo_path(rows[pid])).convert("RGB"), (TH, TH))
            im.paste(t, (x + (TH - t.width) // 2, y0 + (TH - t.height) // 2))
            marks = []
            for m in models:
                r = R[m].get(k, {})
                if r.get("chosen_id") == pid:
                    d.rectangle([x - 3 + 4 * models.index(m), y0 - 3 + 4 * models.index(m),
                                 x + TH + 2 - 4 * models.index(m), y0 + TH + 2 - 4 * models.index(m)],
                                outline=COL[m], width=4)
                    marks.append(m)
            lab = f"#{j + 1}" + ("  CURRENT" if pid == cur else "")
            d.text((x, y0 + TH + 4), lab, fill=(0, 140, 0) if pid == cur else "black", font=font)
            yy = y0 + TH + 22
            for m in models:
                o = R[m].get(k, {}).get("out")
                if not o:
                    continue
                ph = next((p for p in o["photos"] if p["photo"] == j + 1), None)
                if ph:
                    txt = f"{m[0].upper()}{ph['score']} {','.join(ph['flags'])}" + ("  <PICK" if m in marks else "")
                    d.text((x, yy), txt, fill=COL[m], font=font)
                yy += 18
        yy = y0 + TH + 62
        for m in models:
            o = R[m].get(k, {}).get("out")
            if o:
                txt = f"{m}: " + ("NONE ACCEPTABLE. " if o["chosen"] is None else f"#{o['chosen']}. ") + o["reason"]
                d.text((PAD, yy), txt[:200], fill=COL[m], font=font)
                if len(txt) > 200:
                    d.text((PAD, yy + 17), txt[200:400], fill=COL[m], font=font)
            yy += 36
        return im

    def write(keys, stem, per=6):
        paths = []
        for p in range(0, len(keys), per):
            ims = [row(k) for k in keys[p:p + per]]
            sh = Image.new("RGB", (ims[0].width, sum(i.height for i in ims) + 4 * len(ims)), (90, 90, 90))
            y = 0
            for i in ims:
                sh.paste(i, (0, y))
                y += i.height + 4
            path = os.path.join(rd, "sheets", f"{stem}-{p // per + 1}.jpg")
            sh.save(path, quality=85)
            paths.append(path)
        return paths

    for p in write(dis, "disagree") + write(agree, "agree"):
        print(p)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["select", "fetch", "submit", "collect", "compare", "sheets"])
    ap.add_argument("--pilot", action="store_true", help="the 50-class pilot (vision/pilot.json)")
    ap.add_argument("--model", default="opus", help="opus | sonnet | haiku | a model id")
    ap.add_argument("--models", default="opus,sonnet", help="compare/sheets: two model keys")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--smoke", action="store_true", help="submit: one synchronous request only")
    ap.add_argument("--approve-spend", action="store_true")
    ap.add_argument("--wait", action="store_true")
    ap.add_argument("--every", type=int, default=150)
    ap.add_argument("--max-wait", type=int, default=1800)
    a = ap.parse_args()
    {"select": cmd_select, "fetch": cmd_fetch, "submit": cmd_submit, "collect": cmd_collect,
     "compare": cmd_compare, "sheets": cmd_sheets}[a.cmd](a)


if __name__ == "__main__":
    main()
