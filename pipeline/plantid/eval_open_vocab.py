#!/usr/bin/env python3
"""Open-vocabulary evaluation (EVALUATION ONLY — nothing here ships): would a
hybrid "Tasmanian specialist + rest-of-world zero-shot" name garden /
non-Tasmanian plants better without hurting wild Tasmanian accuracy?

Motivation: a garden Protea photographed by Leo came back as Telopea truncata
95 % — the shipped scorer (build_ship.Ship) only knows the 2,675 labels.

Subcommands (run in order; each caches its output under
pipeline/cache/plantid/openvocab/, gitignored):

  labels   global label list = TreeOfLife-200M's own taxa list for BioCLIP
           2.5 (HF imageomics/TreeOfLife-200M embeddings/
           txt_emb_bioclip-2.5-vith14.json, 84 MB), Plantae species whose
           binomial has ≥ --min-rg research-grade iNat observations worldwide
           (iNat open-data snapshot already staged in sets/work.duckdb).
           Rows that ARE one of the 2,675 local labels (iNat species id or
           binomial) are marked local and get no global text vector.
  text     BioCLIP 2.5 text tower on MPS fp16, the eval's prompt
           "a photo of <kingdom phylum class order family genus epithet>."
           (embed.py's taxonomic form; ToL's 7 ranks give the same string
           shape). Exact context truncation per batch (causal mask + EOT
           pooling ⇒ tokens after EOT never influence it; checked against
           the full 77-token pass). fp16, L2-normalised, resumable shards.
  fetch    test set B: iNat API, Tasmania (place 6829), Plantae, captive /
           cultivated, species rank, photo licence CC0 / BY / BY-NC.
  testset  B rows: one licensed photo per observation, label quality tiers
           (rg2 = ≥ 2 users' current species IDs agree, no species-level
           disagreement; one_other = the only species ID is one non-observer
           identifier's, no disagreement; the rest dropped), ≤ 8 photos per
           species, B1 = species not among the 2,675 labels, B2 = in them;
           observer-hash split into tune / report halves; photos (500 px
           "medium", like the eval) → openvocab/photos/, credits TSV.
  embed    B embeddings with the SHIPPED encoder (Core ML w8, compute units
           ALL) and build_ship.preprocess (Pillow bicubic, = the app).
  score    v0 / v1 / v2 on A (wild test set; tune on its val split) and B
           (tune on B-tune, report on B-report) → openvocab/results.json +
           results.md.
  points   operating points re-picked from that sweep (default and strict
           A-val guards): paired A-test changes vs v0, B1 by label tier and
           date, the Protea-like photos; OV_TEXT_INT8=1 → int8 global matrix.

Environment (coremltools needs numpy < 2.3; same as build_ship.py):

  uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \\
      --with open_clip_torch --with coremltools --with 'numpy<2.3' \\
      --with scipy --with pyarrow --with pillow --with duckdb \\
      python3 -I pipeline/plantid/eval_open_vocab.py <subcommand>
"""
import argparse
import collections
import glob
import hashlib
import http.client
import json
import os
import sys
import time
import urllib.request

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402  (Ship scorer, preprocess, blob I/O)

CACHE = BS.CACHE
OV = os.path.join(CACHE, "openvocab")
TOL_JSON = os.path.join(OV, "tol", "txt_emb_bioclip-2.5-vith14.json")
TOL_URL = ("https://huggingface.co/datasets/imageomics/TreeOfLife-200M/resolve/main/"
           "embeddings/txt_emb_bioclip-2.5-vith14.json")
UA = {"User-Agent": "izzymap-plantid-eval/1"}
USABLE = {"cc0", "cc-by", "cc-by-nc"}
BANK = "bank-int8.bin"  # the shipped default


def h01(s):
    return int(hashlib.sha256(s.encode()).hexdigest()[:8], 16) / 2 ** 32


# --------------------------------------------------------------- labels

def cmd_labels(a):
    import duckdb
    if not os.path.exists(TOL_JSON):
        os.makedirs(os.path.dirname(TOL_JSON), exist_ok=True)
        urllib.request.urlretrieve(TOL_URL, TOL_JSON)
    tol = json.load(open(TOL_JSON))
    plants = [(r, c) for r, c in tol if r[0] == "Plantae" and all(r)]
    print(f"ToL taxa: {len(tol):,}; Plantae species: {len(plants):,}")
    con = duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)
    rg = dict(con.execute("""
        SELECT s.name, count(*) FROM obs o JOIN species s ON o.species_id = s.species_id
        WHERE s.active GROUP BY 1""").fetchall())
    sid = dict(con.execute("SELECT name, species_id FROM species WHERE active").fetchall())
    L = pq.read_table(os.path.join(CACHE, "sets", "labels.parquet")).to_pydict()
    local_ids = set(L["species_id"])
    local_names = set(L["name"])
    seen, rows = set(), []
    for r, common in plants:
        b = f"{r[5]} {r[6]}"
        if b in seen:
            continue
        seen.add(b)
        n = rg.get(b, 0)
        if n < a.min_rg:
            continue
        i = sid.get(b)
        rows.append({"binomial": b, "taxo": " ".join(r), "common": common or "",
                     "genus": r[5], "family": r[4], "order": r[3], "cls": r[2],
                     "inat_species_id": i, "n_rg": n,
                     "local": bool(b in local_names or (i is not None and i in local_ids))})
    rows.sort(key=lambda x: -x["n_rg"])
    pq.write_table(pa.Table.from_pylist(rows), os.path.join(OV, "global_labels.parquet"))
    nl = sum(r["local"] for r in rows)
    cov = sum(1 for n in local_names if n in seen)
    print(f"kept {len(rows):,} binomials with ≥ {a.min_rg} research-grade iNat obs "
          f"({nl:,} are local labels → {len(rows) - nl:,} global-only); "
          f"{cov:,}/{len(local_names):,} local label names appear in ToL's plant list")


# ----------------------------------------------------------------- text

def encode_trunc(model, tok_ids):
    """model.encode_text with the context cut to the longest prompt (+EOT):
    identical output — the causal mask hides later tokens from the EOT row."""
    import torch
    L = int((tok_ids != 0).sum(1).max())
    t = tok_ids[:, :L]
    cd = model.transformer.get_cast_dtype()
    x = model.token_embedding(t).to(cd) + model.positional_embedding[:L].to(cd)
    x = model.transformer(x, attn_mask=model.attn_mask[:L, :L])
    x = model.ln_final(x)
    x = x[torch.arange(len(t)), t.argmax(-1)]
    return x @ model.text_projection


def cmd_text(a):
    import open_clip
    import torch
    G = pq.read_table(os.path.join(OV, "global_labels.parquet")).to_pydict()
    prompts = [f"a photo of {t}." for t, l in zip(G["taxo"], G["local"]) if not l]
    if a.limit:
        prompts = prompts[:a.limit]
    out = os.path.join(OV, "text-timing" if a.limit else "text")  # timing runs stay apart
    os.makedirs(out, exist_ok=True)
    model, _, _ = open_clip.create_model_and_transforms(BS.HF)
    model.visual = None  # text tower only
    tok = open_clip.get_tokenizer(BS.HF)
    dev = "mps"
    model = model.to(dev).to(torch.float16).eval()
    with torch.no_grad():  # truncation check against the stock 77-token pass
        t = tok(prompts[:64]).to(dev)
        e1 = torch.nn.functional.normalize(model.encode_text(t).float(), dim=-1)
        e2 = torch.nn.functional.normalize(encode_trunc(model, t).float(), dim=-1)
        print(f"truncation check: min cos {float((e1 * e2).sum(1).min()):.5f}")
        # and the eval's own local text vectors (cloud fp16): same pipeline?
        Lb = pq.read_table(os.path.join(CACHE, "sets", "labels.parquet"),
                           columns=["species_id", "taxo"]).to_pydict()
        z = np.load(os.path.join(CACHE, "emb", BS.MODEL, "text.npz"))
        ref = dict(zip(z["species_id"].tolist(), z["emb"].astype(np.float32)))
        e3 = torch.nn.functional.normalize(encode_trunc(model, tok(
            [f"a photo of {x}." for x in Lb["taxo"][:64]]).to(dev)).float(), dim=-1).cpu().numpy()
        c = [float(e3[i] @ ref[Lb["species_id"][i]]) for i in range(64)]
        print(f"local text vectors vs eval's text.npz: min cos {min(c):.5f}")
    B = a.shard
    t0, n = time.time(), 0
    order = None
    for s0 in range(0, len(prompts), B):
        f = os.path.join(out, f"shard-{s0 // B:04d}.npy")
        if os.path.exists(f):
            continue
        chunk = prompts[s0:s0 + B]
        ids = tok(chunk)
        order = np.argsort(-(ids != 0).sum(1).numpy())  # length-sorted batches
        E = np.zeros((len(chunk), 1024), np.float16)
        with torch.no_grad():
            for i in range(0, len(chunk), a.batch):
                sel = order[i:i + a.batch]
                e = encode_trunc(model, ids[sel].to(dev))
                E[sel] = torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()
        np.save(f + ".tmp.npy", E)
        os.replace(f + ".tmp.npy", f)
        n += len(chunk)
        print(f"  {s0 + len(chunk):,}/{len(prompts):,}  {n / (time.time() - t0):.0f} prompts/s",
              flush=True)


def load_text():
    fs = sorted(glob.glob(os.path.join(OV, "text", "shard-*.npy")))
    T = np.concatenate([np.load(f) for f in fs])
    if os.environ.get("OV_TEXT_INT8"):  # what an int8 per-row app matrix would give
        T = T.astype(np.float32)
        sc = np.abs(T).max(1, keepdims=True) / 127.0
        T = (np.clip(np.round(T / sc), -127, 127) * sc).astype(np.float16)
        print("global text matrix: int8 per-row (quantised → dequantised)")
    return T


# ----------------------------------------------------------------- B set

def cmd_fetch(a):
    path = os.path.join(OV, "inat", "captive_tas.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    base = ("https://api.inaturalist.org/v1/observations?place_id=6829&iconic_taxa=Plantae"
            "&photo_license=cc0,cc-by,cc-by-nc&hrank=species&lrank=form&captive=true"
            "&per_page=200&order_by=id&order=asc")
    out, above = [], 0
    while True:
        r = json.load(urllib.request.urlopen(urllib.request.Request(
            base + f"&id_above={above}", headers=UA), timeout=60))
        if not r["results"]:
            break
        out += r["results"]
        above = r["results"][-1]["id"]
        print(f"  {len(out):,}/{r['total_results'] + len(out) - len(r['results']):,}", flush=True)
        time.sleep(1.1)  # iNat API: ≤ 1 request/s
    json.dump(out, open(path, "w"))


def cmd_testset(a):
    obs = json.load(open(os.path.join(OV, "inat", "captive_tas.json")))
    L = pq.read_table(os.path.join(CACHE, "sets", "labels.parquet")).to_pydict()
    local_ids, local_names = set(L["species_id"]), set(L["name"])
    taken = set(pq.read_table(os.path.join(CACHE, "sets", "train.parquet"),
                              columns=["photo_id"]).column(0).to_pylist())
    tiers, rows = collections.Counter(), []
    for o in obs:
        t = o["taxon"]
        s = t.get("min_species_taxon_id")
        ids = [i for i in o["identifications"] if i.get("current") and i["taxon"]["rank_level"] <= 10]
        agree = {i["user"]["id"] for i in ids if i["taxon"].get("min_species_taxon_id") == s}
        dis = any(i["taxon"].get("min_species_taxon_id") != s for i in ids)
        if dis or not agree:
            tiers["dropped: disagreement / no species ID"] += 1
            continue
        tier = "rg2" if len(agree) >= 2 else "one_other" if o["user"]["id"] not in agree else None
        if tier is None:
            tiers["dropped: observer's own ID only"] += 1
            continue
        ph = next((p for p in o["photos"] if (p.get("license_code") or "") in USABLE
                   and "inaturalist-open-data" in p["url"]), None)
        if ph is None or ph["id"] in taken:
            tiers["dropped: no usable photo"] += 1
            continue
        anc = {x.get("rank"): x.get("name") for x in (t.get("ancestors") or [])}
        # species name: the species-rank ancestor for subsp./var. observations
        sp_name = t["name"] if t["rank"] == "species" else next(
            (x["name"] for x in t.get("ancestors") or [] if x.get("id") == s), None)
        if sp_name is None:
            tiers["dropped: no species name"] += 1
            continue
        genus = sp_name.split()[0]
        lon, lat = (o["geojson"] or {}).get("coordinates", [None, None])
        if lat is None:
            tiers["dropped: no location"] += 1
            continue
        tiers[tier] += 1
        rows.append({"obs_id": o["id"], "photo_id": ph["id"],
                     "ext": ph["url"].rsplit(".", 1)[-1], "license": ph["license_code"],
                     "attribution": ph.get("attribution", ""), "observer": o["user"]["login"],
                     "observer_id": o["user"]["id"], "species_id": s, "species": sp_name,
                     "genus": genus, "family": anc.get("family"), "tier": tier,
                     "observed_on": o.get("observed_on"), "lat": float(lat), "lon": float(lon),
                     "in_list": bool(s in local_ids or sp_name in local_names),
                     "half": "tune" if h01(f"{o['user']['id']}izzy-ov") < 0.5 else "report"})
    # ≤ 8 per species, observer diversity first, deterministic
    by = collections.defaultdict(list)
    for r in rows:
        by[r["species_id"]].append(r)
    keep = []
    for s, rs in by.items():
        rs.sort(key=lambda r: h01(str(r["obs_id"])))
        seen, first, rest = set(), [], []
        for r in rs:
            (rest if r["observer_id"] in seen else first).append(r)
            seen.add(r["observer_id"])
        keep += (first + rest)[:8]
    print("tiers:", dict(tiers))
    print(f"{len(rows):,} usable → {len(keep):,} after ≤ 8 per species "
          f"({len(by):,} species)")
    for h in ("tune", "report"):
        k = [r for r in keep if r["half"] == h]
        print(f"  {h}: {len(k):,} photos, B1 {sum(not r['in_list'] for r in k):,} "
              f"({len({r['species_id'] for r in k if not r['in_list']}):,} spp.), "
              f"B2 {sum(r['in_list'] for r in k):,} "
              f"({len({r['species_id'] for r in k if r['in_list']}):,} spp.)")
    pq.write_table(pa.Table.from_pylist(keep), os.path.join(OV, "B.parquet"))
    with open(os.path.join(OV, "B-credits.tsv"), "w") as f:
        f.write("photo_id\tobservation\tlogin\tlicence\tattribution\n")
        for r in keep:
            f.write(f"{r['photo_id']}\t{r['obs_id']}\t{r['observer']}\t{r['license']}\t"
                    f"{r['attribution']}\n")
    # photos: 500 px medium from the open-data bucket, keep-alive
    d = os.path.join(OV, "photos")
    os.makedirs(d, exist_ok=True)
    conn, bad, t0, n = None, 0, time.time(), 0
    for r in keep:
        p = os.path.join(d, f"{r['photo_id']}.{r['ext']}")
        if os.path.exists(p):
            continue
        for attempt in range(3):
            try:
                if conn is None:
                    conn = http.client.HTTPSConnection("inaturalist-open-data.s3.amazonaws.com",
                                                       timeout=30)
                conn.request("GET", f"/photos/{r['photo_id']}/medium.{r['ext']}")
                resp = conn.getresponse()
                body = resp.read()
                if resp.status == 200 and body[:3] in (b"\xff\xd8\xff", b"\x89PN"):
                    open(p, "wb").write(body)
                    n += 1
                else:
                    bad += 1
                break
            except Exception:
                conn = None
                time.sleep(1)
    print(f"photos: {n} fetched in {time.time() - t0:.0f} s, {bad} unavailable")


def b_rows():
    B = pq.read_table(os.path.join(OV, "B.parquet")).to_pylist()
    d = os.path.join(OV, "photos")
    return [r for r in B if os.path.exists(os.path.join(d, f"{r['photo_id']}.{r['ext']}"))]


def cmd_embed(a):
    import coremltools as ct
    from concurrent.futures import ThreadPoolExecutor
    rows = b_rows()
    out = os.path.join(OV, "emb-w8.npz")
    t = time.time()
    m = ct.models.MLModel(os.path.join(BS.SHIP, "encoder", "PlantEncoder-w8.mlpackage"),
                          compute_units=ct.ComputeUnit.ALL)
    print(f"w8 loaded in {time.time() - t:.1f} s; {len(rows):,} photos")
    d = os.path.join(OV, "photos")
    t0, embs = time.time(), []
    with ThreadPoolExecutor(4) as pool:
        for i, x in enumerate(pool.map(lambda r: BS.preprocess(
                os.path.join(d, f"{r['photo_id']}.{r['ext']}")), rows)):
            embs.append(m.predict({"pixel_values": x})["embedding"].reshape(-1))
            if (i + 1) % 250 == 0:
                print(f"  {i + 1:,}  {(time.time() - t0) / (i + 1):.3f} s/photo", flush=True)
    np.savez(out, photo_id=np.array([r["photo_id"] for r in rows]),
             emb=np.stack(embs).astype(np.float32))
    print(f"done: {(time.time() - t0) / len(rows):.3f} s/photo")


# ----------------------------------------------------------------- score

KAPPAS = (25.0, 35.0, 50.0, 70.0, 100.0)  # zero-shot logit scales tried (model's own: 98.9)
TOPG = 64  # global classes kept per photo for the decision (all enter the softmax sum)


class World:
    """Per photo, precomputed once: Ship log p over the 2,675 labels (shipped
    files, int8 bank, location prior), the kNN top-1 similarity, and the
    zero-shot cosines to the local text vectors plus, for the ~90k global
    vectors, the top-TOPG cosines and logsumexp(κ·cos) for every κ (the
    softmax over all of them needs the sum, the decision only the top)."""

    def __init__(self, emb, lat, lon, ship, Tloc, Tglob, centre_t):
        import torch
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        self.n = len(emb)
        q = ship.query(emb)  # centred, normalised (head/bank space)
        sims, idx = BS.knn_neighbours(q, ship.B, ship.bscale, ship.bh["scoring"]["k"])
        self.knn1 = sims[:, 0]
        self.lp = ship.logp(emb, lat, lon, nbrs=(sims, idx))
        raw = BS.unit(np.asarray(emb, np.float32))
        self.zs = {}
        for cen in ("raw", "centred"):
            x = raw if cen == "raw" else BS.unit(raw - ship.mu[None, :])
            tl = Tloc if cen == "raw" else BS.unit(Tloc - centre_t)
            X = torch.from_numpy(x.astype(np.float32)).to(dev)
            ct = torch.from_numpy(centre_t.astype(np.float32)).to(dev)
            top_v = top_i = None
            lse = {k: None for k in KAPPAS}
            for s0 in range(0, len(Tglob), 8192):
                T = torch.from_numpy(Tglob[s0:s0 + 8192].astype(np.float32)).to(dev)
                if cen == "centred":
                    T = torch.nn.functional.normalize(T - ct, dim=-1)
                C = X @ T.T
                v, i = C.topk(TOPG, dim=1)
                i = i + s0
                if top_v is not None:
                    v, i2 = torch.cat([top_v, v], 1), torch.cat([top_i, i], 1)
                    o = v.topk(TOPG, dim=1)
                    v, i = o.values, torch.gather(i2, 1, o.indices)
                top_v, top_i = v, i
                for k in KAPPAS:
                    l = torch.logsumexp(k * C, dim=1)
                    lse[k] = l if lse[k] is None else torch.logaddexp(lse[k], l)
            self.zs[cen] = {"cl": x @ tl.T, "gv": top_v.cpu().numpy(),
                            "gi": top_i.cpu().numpy(),
                            "lse": {k: v.cpu().numpy().astype(np.float64) for k, v in lse.items()}}

    def p_out(self, cen, k, b):
        """Zero-shot P(not one of the 2,675) over the union local ∪ global,
        with the rest-of-world penalty b on every global logit."""
        z = self.zs[cen]
        lse_l = lse_rows(k * z["cl"])
        lse_g = z["lse"][k] - b
        lse_all = np.logaddexp(lse_l, lse_g)
        return np.exp(lse_g - lse_all), lse_all


def lse_rows(Z):
    Z = np.asarray(Z, np.float64)
    m = Z.max(1, keepdims=True)
    return m[:, 0] + np.log(np.exp(Z - m).sum(1))


def ladder(P, genus, top=50):
    """evaluate.score's rule on one probability vector (may sum to < 1):
    species if p ≥ .5, else genus if its summed p ≥ .5, else not sure."""
    i = int(P.argmax())
    if P[i] >= 0.5:
        return "species", i, genus[i], float(P[i])
    gm = collections.defaultdict(float)
    for j in np.argpartition(-P, top)[:top]:
        gm[genus[j]] += P[j]
    g = max(gm, key=gm.get)
    return ("genus", -1, g, gm[g]) if gm[g] >= 0.5 else ("notsure", -1, None, 0.0)


def decide(W, gl_loc, gl_glob, variant, prm):
    """Answers for every photo of World W:
      kind     species / genus / notsure
      local    the named species / genus answer comes from the 2,675 labels
      idx      label index (local) or global index; −1 for genus / not sure
      genus, p
      flag     the app would say "probably not a Tasmanian wild plant / not on
               IzzyMap's list" (v1: a global answer or P_out ≥ .5; v2: OOD)
      switched v1 put a global species on top (argmax)
      top1     argmax label (local index, or −9 when a global is on top)
      top5     local indices among the union top 5 (−9 = a global)"""
    n, p_ship = W.n, np.exp(W.lp)
    kind = np.full(n, "notsure", object)
    local = np.zeros(n, bool)
    idx = np.full(n, -1)
    genus = np.full(n, None, object)
    p = np.zeros(n)
    flag = np.zeros(n, bool)
    switched = np.zeros(n, bool)
    top5 = np.argsort(-W.lp, 1)[:, :5]
    if variant == "v1":
        cen, k, b, m = prm["centring"], prm["kappa"], prm["b"], prm["m"]
        po, lse_all = W.p_out(cen, k, b)
        P_loc = (1 - po)[:, None] * p_ship
        z = W.zs[cen]
        Pg = np.exp(k * z["gv"] - b - lse_all[:, None])  # best globals, union-normalised
        s_best = P_loc.max(1)
        switched = np.log(Pg[:, 0] + 1e-300) - np.log(s_best + 1e-300) > m
        # union top 5: merge the local top 5 and the global top 5
        cand = np.concatenate([np.take_along_axis(P_loc, top5, 1), Pg[:, :5]], 1)
        lab = np.concatenate([top5, np.full((n, 5), -9)], 1)
        o = np.argsort(-cand, 1)[:, :5]
        top5 = np.take_along_axis(lab, o, 1)
    else:
        P_loc, po = p_ship, np.zeros(n)
    for j in range(n):
        if switched[j]:
            flag[j] = True
            if Pg[j, 0] >= 0.5:
                kind[j], idx[j], genus[j], p[j] = "species", z["gi"][j, 0], \
                    gl_glob[z["gi"][j, 0]], Pg[j, 0]
            else:  # genus mass: top globals + local labels
                gm = collections.defaultdict(float)
                for v, i in zip(Pg[j], z["gi"][j]):
                    gm[gl_glob[i]] += v
                for i in np.argpartition(-P_loc[j], 50)[:50]:
                    gm[gl_loc[i]] += P_loc[j, i]
                g = max(gm, key=gm.get)
                if gm[g] >= 0.5:
                    kind[j], genus[j], p[j] = "genus", g, gm[g]
            continue
        kind[j], idx[j], genus[j], p[j] = ladder(P_loc[j], gl_loc)
        local[j] = kind[j] != "notsure"
        if variant == "v1" and po[j] >= 0.5:
            flag[j] = True
    if variant == "v2":
        if prm["score"] == "knn1":
            flag = W.knn1 < prm["theta"]
        else:
            flag = W.p_out(prm["centring"], prm["kappa"], prm["b"])[0] >= prm["theta"]
        # a flagged photo names nothing: "not sure — may not be on IzzyMap's list"
        kind = np.where(flag, "notsure", kind)
        idx = np.where(flag, -1, idx)
        genus = np.where(flag, None, genus)
        local = local & ~flag
    top1 = np.where(switched, -9, W.lp.argmax(1))
    return dict(kind=kind, local=local, idx=idx, genus=genus, p=p, flag=flag,
                switched=switched, top1=top1, top5=top5, p_out=po)


def metrics_A(ans, e, gl_loc):
    """The eval's definitions (evaluate.score): weights w, in-label photos for
    top-1/5, the ladder over ALL photos (a not-in-label photo's species or
    genus answer counts as wrong)."""
    y, w = e["y"], e["w"]
    inl = y >= 0
    yy = np.maximum(y, 0)
    named = ans["kind"] == "species"
    right = named & ans["local"] & (ans["idx"] == y) & inl
    g_ans = ans["kind"] == "genus"
    g_ok = g_ans & inl & (ans["genus"] == gl_loc[yy])
    every = np.ones_like(inl)

    def acc(mask, h):
        return float((h[mask] * w[mask]).sum() / w[mask].sum()) if mask.any() else None
    return {"top1": acc(inl, ans["top1"] == y), "top5": acc(inl, (ans["top5"] == y[:, None]).any(1)),
            "named": acc(every, named), "named_right": acc(named, right),
            "genus": acc(every, g_ans), "genus_right": acc(g_ans, g_ok),
            "wrong_answer": acc(every, (named & ~right) | (g_ans & ~g_ok)),
            "flagged": acc(every, ans["flag"]), "switched": acc(every, ans["switched"]),
            "n": int(len(y))}


def metrics_B(ans, rows, gnames, lnames):
    truth = np.array([r["species"] for r in rows], object)
    tgen = np.array([r["genus"] for r in rows], object)
    inl = np.array([r["in_list"] for r in rows])
    ytrue = np.array([LABEL_OF.get(r["species_id"], LABEL_OF.get(r["species"], -1)) for r in rows])
    named = ans["kind"] == "species"
    name = np.array([(lnames[i] if l else gnames[i]) if k == "species" else None
                     for k, l, i in zip(ans["kind"], ans["local"], ans["idx"])], object)
    sp_right = named & (name == truth)
    gen_right = (ans["kind"] != "notsure") & (ans["genus"] == tgen)
    wrong = (named & ~sp_right) | ((ans["kind"] == "genus") & ~gen_right)
    conf_wrong_native = named & ans["local"] & (ans["p"] >= 0.5) & ~sp_right
    # utility used for tuning: +1 right species, +0.5 right genus only, −1 a wrong answer
    util = sp_right * 1.0 + ((ans["kind"] == "genus") & gen_right) * 0.5 - wrong * 1.0
    out = {"utility": float(util.mean()), "n": len(rows)}
    for part, m in (("B1", ~inl), ("B2", inl)):
        f = lambda h: float(h[m].mean())  # noqa: E731
        out[part] = {"n": int(m.sum()), "species": int(len(set(truth[m]))),
                     "species_right": f(sp_right), "genus_right": f(gen_right),
                     "flagged": f(ans["flag"]), "conf_wrong_native": f(conf_wrong_native),
                     "wrong_answer": f(wrong), "named": f(named),
                     "not_sure": f(ans["kind"] == "notsure"), "utility": f(util)}
        if part == "B2":
            out[part]["top1"] = f(ans["top1"] == ytrue)
    return out


LABEL_OF = {}


def cmd_score(a):
    t0 = time.time()
    ship = BS.Ship(BS.SHIP, BANK)
    labels = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    gl_loc = np.array([l["genus"] for l in labels], object)
    lnames = [l["name"] for l in labels]
    LABEL_OF.update({l["inat"]: i for i, l in enumerate(labels)})
    LABEL_OF.update({l["name"]: i for i, l in enumerate(labels)})
    # local text vectors: the eval's own (cloud fp16) taxonomic prompts
    z = np.load(os.path.join(CACHE, "emb", BS.MODEL, "text.npz"))
    tv = dict(zip(z["species_id"].tolist(), z["emb"].astype(np.float32)))
    Tloc = np.stack([tv[l["inat"]] for l in labels])
    G = pq.read_table(os.path.join(OV, "global_labels.parquet")).to_pydict()
    keep = [i for i, l in enumerate(G["local"]) if not l]
    Tg = load_text()
    assert len(Tg) == len(keep), (len(Tg), len(keep))
    gnames = np.array([G["binomial"][i] for i in keep], object)
    gl_glob = np.array([G["genus"][i] for i in keep], object)
    centre_t = np.concatenate([Tloc, Tg.astype(np.float32)]).mean(0)
    print(f"{len(Tloc):,} local + {len(Tg):,} global text vectors")

    # ---- A: val (cloud fp16 embeddings; tuning) and test (shipped w8 Core ML)
    S = BS.load_sets()
    ev = S["ev"]
    ids_w8, E_w8 = BS.load_parts(os.path.join(BS.SHIP, "eval", "coreml-w8"))
    pos = {int(p): i for i, p in enumerate(ids_w8)}
    A = {"A-val": (ev["val"]["X"].astype(np.float32), ev["val"]),
         "A-test": (E_w8[[pos[int(p)] for p in ev["test"]["photo_id"]]], ev["test"])}
    Wd, Ed = {}, {}
    for s, (X, e) in A.items():
        t = time.time()
        Wd[s], Ed[s] = World(X, e["lat"], e["lon"], ship, Tloc, Tg, centre_t), e
        print(f"{s}: {len(X):,} photos prepared in {time.time() - t:.0f} s", flush=True)
    rows = b_rows()
    zb = np.load(os.path.join(OV, "emb-w8.npz"))
    epos = {int(p): i for i, p in enumerate(zb["photo_id"])}
    for h in ("tune", "report"):
        rr = [r for r in rows if r["half"] == h and r["photo_id"] in epos]
        X = zb["emb"][[epos[r["photo_id"]] for r in rr]]
        Wd["B-" + h] = World(X, np.array([r["lat"] for r in rr]), np.array([r["lon"] for r in rr]),
                             ship, Tloc, Tg, centre_t)
        Ed["B-" + h] = rr
    # how many B1 truths does the global list hold at all (the ceiling)
    gset = set(gnames)
    cov = {h: float(np.mean([r["species"] in gset for r in Ed["B-" + h] if not r["in_list"]]))
           for h in ("tune", "report")}
    print(f"prepared in {time.time() - t0:.0f} s; B1 species in the global list: {cov}", flush=True)

    def ev_(s, v, prm):
        ans = decide(Wd[s], gl_loc, gl_glob, v, prm)
        return metrics_A(ans, Ed[s], gl_loc) if s.startswith("A") else \
            metrics_B(ans, Ed[s], gnames, lnames)

    if a.cmd == "points":
        return points(a, Wd, Ed, gl_loc, gl_glob, gnames, lnames, ev_)

    res = {"sizes": {"global_labels": int(len(Tg)), "local_labels": len(labels)},
           "B1_in_global_list": cov,
           "guard": {"max_top1_drop": a.max_top1_drop, "max_wrong_rise": a.max_wrong_rise,
                     "max_named_drop": a.max_named_drop}}
    splits = ("A-val", "A-test", "B-tune", "B-report")
    res["v0"] = {s: ev_(s, "v0", {}) for s in splits}
    base = res["v0"]["A-val"]
    print("v0 A-test", res["v0"]["A-test"], "\nv0 B-report", res["v0"]["B-report"], flush=True)

    def ok(rA):  # the guard on wild accuracy, A-val only
        return (rA["top1"] >= base["top1"] - a.max_top1_drop and
                rA["wrong_answer"] <= base["wrong_answer"] + a.max_wrong_rise and
                rA["named"] >= base["named"] - a.max_named_drop)

    grid = {"v1": [{"centring": c, "kappa": k, "b": b, "m": m} for c in ("raw", "centred")
                   for k in KAPPAS for b in a.penalties for m in (0.0, 1.0, 2.0)],
            "v2": [{"score": "knn1", "theta": float(t)} for t in
                   np.quantile(Wd["A-val"].knn1, [0.002, 0.005, 0.01, 0.02, 0.05, 0.1])] +
                  [{"score": "p_out", "centring": c, "kappa": k, "b": b, "theta": t}
                   for c in ("raw", "centred") for k in KAPPAS for b in a.penalties
                   for t in (0.5, 0.7, 0.9)]}
    for v, prms in grid.items():
        sw = []
        for prm in prms:
            rA, rB = ev_("A-val", v, prm), ev_("B-tune", v, prm)
            sw.append({"prm": prm, "A-val": rA, "B-tune": rB, "ok": ok(rA)})
        good = [s for s in sw if s["ok"]]
        best = max(good, key=lambda s: s["B-tune"]["utility"]) if good else None
        res[v] = {"chosen": best and best["prm"], "n_ok": len(good), "n": len(sw), "sweep": sw}
        if best:
            res[v].update({s: ev_(s, v, best["prm"]) for s in splits})
        ub = max(sw, key=lambda s: s["B-tune"]["utility"])
        res[v]["unconstrained"] = {"prm": ub["prm"], "A-val": ub["A-val"], "B-tune": ub["B-tune"],
                                   "A-test": ev_("A-test", v, ub["prm"]),
                                   "B-report": ev_("B-report", v, ub["prm"])}
        print(f"{v}: {len(sw)} settings, {len(good)} pass the guard; "
              f"{time.time() - t0:.0f} s", flush=True)
    # what a Protea-like photo looks like: B1 examples under v0 vs v1
    if res["v1"]["chosen"]:
        a0 = decide(Wd["B-report"], gl_loc, gl_glob, "v0", {})
        a1 = decide(Wd["B-report"], gl_loc, gl_glob, "v1", res["v1"]["chosen"])
        ex = []
        for j, r in enumerate(Ed["B-report"]):
            if r["in_list"] or len(ex) >= 40:
                continue
            nm = lambda A_, j: (lnames[A_["idx"][j]] if A_["local"][j] else gnames[A_["idx"][j]]) \
                if A_["kind"][j] == "species" else f"{A_['kind'][j]} {A_['genus'][j] or ''}"  # noqa: E731
            ex.append({"truth": r["species"], "v0": nm(a0, j), "v0_p": round(float(a0["p"][j]), 2),
                       "v1": nm(a1, j), "v1_p": round(float(a1["p"][j]), 2),
                       "p_out": round(float(a1["p_out"][j]), 2), "flag": bool(a1["flag"][j])})
        res["examples_B1"] = ex
    json.dump(res, open(os.path.join(OV, "results.json"), "w"), indent=1, default=str)
    write_md(res, os.path.join(OV, "results.md"))
    print(open(os.path.join(OV, "results.md")).read())
    print(f"total {time.time() - t0:.0f} s")


def points(a, Wd, Ed, gl_loc, gl_glob, gnames, lnames, ev_):
    """Operating points from the finished sweep (results.json), re-picked on
    A-val / B-tune only, then: paired A-test changes vs v0, B1 by label tier
    and by date (pretraining-leakage check), species-averaged B1."""
    res = json.load(open(os.path.join(OV, "results.json")))
    base = res["v0"]["A-val"]

    def pick(v, drop, rise, named):
        good = [s for s in res[v]["sweep"] if s["A-val"]["top1"] >= base["top1"] - drop and
                s["A-val"]["wrong_answer"] <= base["wrong_answer"] + rise and
                s["A-val"]["named"] >= base["named"] - named]
        return max(good, key=lambda s: s["B-tune"]["utility"])["prm"]
    pts = {"v0": ("v0", {}),
           "v1 (guard 0.3/0.3/1.0)": ("v1", res["v1"]["chosen"]),
           "v1 strict (guard 0.1/0.1/0.5)": ("v1", pick("v1", 0.001, 0.001, 0.005)),
           "v2 (guard 0.3/0.3/1.0)": ("v2", res["v2"]["chosen"]),
           "v2 strict (guard 0.1/0.1/0.5)": ("v2", pick("v2", 0.001, 0.001, 0.005))}
    out = {}
    e = Ed["A-test"]
    inl = e["y"] >= 0
    a0 = decide(Wd["A-test"], gl_loc, gl_glob, "v0", {})
    r0 = inl & (a0["top1"] == e["y"])
    for name, (v, prm) in pts.items():
        aA = decide(Wd["A-test"], gl_loc, gl_glob, v, prm)
        rA = inl & (aA["top1"] == e["y"])
        o = {"variant": v, "prm": prm, "A-test": ev_("A-test", v, prm),
             "B-report": ev_("B-report", v, prm),
             "A_paired": {"lost": int((r0 & ~rA).sum()), "gained": int((~r0 & rA).sum()),
                          "photos": int(inl.sum())}}
        rows = Ed["B-report"]
        aB = decide(Wd["B-report"], gl_loc, gl_glob, v, prm)
        sub = {}
        for key, f in (("tier rg2", lambda r: r["tier"] == "rg2"),
                       ("tier one_other", lambda r: r["tier"] == "one_other"),
                       ("before 2024-09-01", lambda r: (r["observed_on"] or "") < "2024-09-01"),
                       ("from 2024-09-01", lambda r: (r["observed_on"] or "") >= "2024-09-01")):
            m = np.array([f(r) and not r["in_list"] for r in rows])
            if m.any():
                sub[key] = metrics_B({k: (x[m] if isinstance(x, np.ndarray) else x)
                                      for k, x in aB.items()},
                                     [r for r, k in zip(rows, m) if k], gnames, lnames)["B1"]
        # species-averaged B1 right-name rate
        b1 = [j for j, r in enumerate(rows) if not r["in_list"]]
        nm = [(lnames[aB["idx"][j]] if aB["local"][j] else gnames[aB["idx"][j]])
              if aB["kind"][j] == "species" else None for j in b1]
        per = collections.defaultdict(list)
        for j, n_ in zip(b1, nm):
            per[rows[j]["species"]].append(n_ == rows[j]["species"])
        o["B1_species_avg_right"] = float(np.mean([np.mean(x) for x in per.values()]))
        o["B1_subgroups"] = sub
        out[name] = o
        P = lambda x: f"{100 * x:.1f}"  # noqa: E731
        A, B1, B2 = o["A-test"], o["B-report"]["B1"], o["B-report"]["B2"]
        print(f"{name}: {prm}\n  A top1 {P(A['top1'])} top5 {P(A['top5'])} named {P(A['named'])}"
              f" right {P(A['named_right'])} wrong {P(A['wrong_answer'])} flagged "
              f"{P(A['flagged'])} paired lost/gained {o['A_paired']}\n  B1 sp {P(B1['species_right'])}"
              f" (species-avg {P(o['B1_species_avg_right'])}) genus {P(B1['genus_right'])} flagged "
              f"{P(B1['flagged'])} cwn {P(B1['conf_wrong_native'])} wrong {P(B1['wrong_answer'])}"
              f" notsure {P(B1['not_sure'])}\n  B2 top1 {P(B2['top1'])} sp {P(B2['species_right'])}"
              f" wrong {P(B2['wrong_answer'])} flagged {P(B2['flagged'])}")
        for k, s in sub.items():
            print(f"    {k}: n {s['n']} sp {P(s['species_right'])} cwn {P(s['conf_wrong_native'])}")
    # any Protea (or other Proteaceae) among the B photos?
    pro = [(r["species"], r["half"]) for h in ("B-tune", "B-report") for r in Ed[h]
           if r["genus"] in ("Protea", "Leucadendron", "Leucospermum")]
    print("Protea-like B photos:", pro)
    for h in ("B-tune", "B-report"):
        ans = {n_: decide(Wd[h], gl_loc, gl_glob, v, prm) for n_, (v, prm) in pts.items()
               if n_ in ("v0", "v1 (guard 0.3/0.3/1.0)", "v2 (guard 0.3/0.3/1.0)")}
        for j, r in enumerate(Ed[h]):
            if r["genus"] not in ("Protea", "Leucadendron", "Leucospermum"):
                continue
            said = []
            for n_, A_ in ans.items():
                k = A_["kind"][j]
                w = ((lnames[A_["idx"][j]] if A_["local"][j] else gnames[A_["idx"][j]])
                     if k == "species" else f"{k} {A_['genus'][j] or ''}".strip())
                said.append(f"{n_.split()[0]}: {w} {A_['p'][j]:.2f}{' [flag]' if A_['flag'][j] else ''}")
            print(f"  {r['species']} ({h}) → " + " | ".join(said))
    json.dump(out, open(os.path.join(OV, "points-int8.json" if os.environ.get("OV_TEXT_INT8")
                                     else "points.json"), "w"), indent=1, default=str)


def write_md(res, path):
    P = lambda x: "–" if x is None else f"{100 * x:.1f}"  # noqa: E731
    out = [f"Global list: {res['sizes']['global_labels']:,} species; B1 truths in it: "
           f"{ {k: P(v) for k, v in res['B1_in_global_list'].items()} } %", "",
           "| variant | setting | A top-1 | A top-5 | A named | A named-right | A wrong ans. |"
           " A flagged | B1 n | B1 sp. right | B1 genus right | B1 flagged | B1 conf. wrong native |"
           " B2 n | B2 top-1 | B2 named-right share | B2 flagged |", "|" + "---|" * 17]

    def row(v, tag, r):
        A, B1, B2 = r["A-test"], r["B-report"]["B1"], r["B-report"]["B2"]
        b2r = B2["species_right"]
        out.append(f"| {v} | {tag} | {P(A['top1'])} | {P(A['top5'])} | {P(A['named'])} | "
                   f"{P(A['named_right'])} | {P(A['wrong_answer'])} | {P(A['flagged'])} | "
                   f"{B1['n']} | {P(B1['species_right'])} | {P(B1['genus_right'])} | "
                   f"{P(B1['flagged'])} | {P(B1['conf_wrong_native'])} | {B2['n']} | "
                   f"{P(B2['top1'])} | {P(b2r)} | {P(B2['flagged'])} |")
    row("v0", "shipping", res["v0"])
    for v in ("v1", "v2"):
        if res[v].get("chosen"):
            row(v, json.dumps(res[v]["chosen"]), res[v])
        else:
            out.append(f"| {v} | no setting passed the A-val guard | |")
        row(v, "unconstrained " + json.dumps(res[v]["unconstrained"]["prm"]), res[v]["unconstrained"])
    out.append("")
    for v in ("v1", "v2"):
        out.append(f"{v}: {res[v]['n_ok']}/{res[v]['n']} settings passed the A-val guard {res['guard']}")
    open(path, "w").write("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("labels")
    p.add_argument("--min-rg", type=int, default=5)
    p = sub.add_parser("text")
    p.add_argument("--batch", type=int, default=256)
    p.add_argument("--shard", type=int, default=8192)
    p.add_argument("--limit", type=int)
    sub.add_parser("fetch")
    sub.add_parser("testset")
    sub.add_parser("embed")
    for name in ("score", "points"):
        p = sub.add_parser(name)
        p.add_argument("--penalties", type=float, nargs="+", default=[0, 2, 4, 6, 8, 10, 12])
        p.add_argument("--max-top1-drop", type=float, default=0.003)
        p.add_argument("--max-wrong-rise", type=float, default=0.003)
        p.add_argument("--max-named-drop", type=float, default=0.01)
    a = ap.parse_args()
    os.makedirs(OV, exist_ok=True)
    {"labels": cmd_labels, "text": cmd_text, "fetch": cmd_fetch, "testset": cmd_testset,
     "embed": cmd_embed, "score": cmd_score, "points": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
