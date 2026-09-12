#!/usr/bin/env python3
"""Build app/src/generated/trees.json — City of Hobart's Significant Tree
Register (points + areas, per-reference facts, data-sheet index).

Source (verified 2026-09-12, CC BY 4.0, attribution "City of Hobart"):
  https://services1.arcgis.com/NHqdsnvwfSTg42I8/arcgis/rest/services/ENVIRON_Significant_Tree_Locations/FeatureServer
  layer 1 "Significant Trees Point" (460 points), layer 4 "Significant Tree
  Areas" (34 polygons); maxRecordCount 1000, paged by OBJECTID. Portal item
  9b31f3f6acb14bb2a5869b5e17707155 carries the licence (licenseInfo HTML
  linking creativecommons.org/licenses/by/4.0/, accessInformation "City of
  Hobart"); the service root's copyrightText is "City of Hobart".

Fields: Planning_Ref_No = register reference — letter+number ("A1"…"Y1")
for the 2012/2020 register, plain numbers ("9"…"133") for the March-2024
draft amendment; several points share a ref when Number_Trees > 1.
Botanical_ID is a coded domain (~354 codes -> botanical name, upstream
typos and curly quotes kept verbatim) on layer 1 but a STRING holding the
code on layer 4, which also has Botanical_Name (preferred when they
differ). Session_Key = positional-accuracy domain (13 codes, dp/os/ft/sk/
tm/pm/fm/tf/un/co/ug/hv/hc). Object_Metadata = free-text note ("Added June
2012, as approved by TPC"), often "". Data_Sheet_URL = one PDF per feature
(282 distinct portal items, ~446 MB in total — NEVER fetched wholesale):
  https://hobartcc.maps.arcgis.com/sharing/rest/content/items/<32 hex>/data
Item metadata (title like "Significant Tree Document - D5 2 Davies Ave" or
"… - REF 90 _ Government House _ vanilla tree", type PDF, access public,
size) comes from arcgis.com/sharing/rest.

Known upstream quirks (2026-09-12): a few refs carry points with MIXED
botanical names — A1's three "Aesculus" points sit at Arthur Circus (A5's
trees, mis-tagged), S1/S2 mix Ulmus/Quercus/Aesculus — so the ref's name is
the candidate the register confirms, falling back to the majority. Some
refs' register text contradicts the service outright (D7 Pinus vs Populus,
H2 Ulmus vs Fraxinus, F11 hawthorn vs Quercus, 111 Cedrus vs Quercus): the
common name is then NOT taken (label falls back to the botanical name) and
the conflict is listed in the run report.

Enrichment (common names + addresses; the service has neither):
  * Register PDF (76.5 MB, 465 pages, "Updated March 2020"):
    https://www.hobartcity.com.au/files/assets/public2/v/2/development-and-business/planning/significant-trees/city-of-hobart-significant-tree-register.pdf
    (hobartcity.com.au answers scripted GETs with 403 — put a browser-saved
    copy at pipeline/cache/trees/register.pdf). `pdftotext -layout` gives a
    two-column form per entry page: "Reference: B7" header, then labels
    (Address / Name of Tree/s / Reasons for significance) in the left
    column with values in the right column — the label sits ON, ABOVE or
    BELOW its value line depending on the era, so parsing is column/
    adjacency based, not regex-on-a-line. Covers 214 of the 277 refs.
  * Data sheets, downloaded ONLY for refs the register did not resolve
    (the 2024 numeric refs + a handful of letters; ~65 sheets, ~35 MB).
    Tripwires: >= 200 register refs must parse and <= 100 sheets may be
    wanted, else the run aborts rather than degrading into a bulk pull.
    2024 sheets (Word-generated) have clean text in the same form layout.
    2012-era sheets embed a subset font WITHOUT a ToUnicode map, so
    pdftotext emits raw glyph codes = ASCII − 29 ("5HIHUHQFH" = "Reference",
    0x03 = space; "(" and ")" land on VT/FF and come out as spaces).
    `unshift()` reverses that as a best-effort fallback; results are
    sanity-checked (Latin binomial, genus vs upstream) before use.
  Only FACTS are taken from the PDFs (address, common name) — no prose.

Output: trees.json = {meta, points, areas (GeoJSON, properties ONLY
{ref, sheet, acc}), refs[ref] = {name, label, common, address, trees,
note, sheets}, accuracy[code] = text, sheets[id] = {bytes, title}}.
`label` is Latin-1-only (the app ships glyphs 0–255).

Run: python3 pipeline/build_trees.py [--skip-enrich] [--fresh]
  --skip-enrich  service data + sheet metadata only (no PDF work)
  --fresh        drop cached JSON/text (PDFs are kept: expensive, immutable)
Everything is cached under pipeline/cache/trees/ (gitignored).
"""
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SERVICE = ("https://services1.arcgis.com/NHqdsnvwfSTg42I8/arcgis/rest/services/"
           "ENVIRON_Significant_Tree_Locations/FeatureServer")
ITEM = "9b31f3f6acb14bb2a5869b5e17707155"
PORTAL = "https://www.arcgis.com/sharing/rest/content/items"
REGISTER_URL = ("https://www.hobartcity.com.au/files/assets/public2/v/2/development-and-business/"
                "planning/significant-trees/city-of-hobart-significant-tree-register.pdf")
LAYERS = {"points": 1, "areas": 4}
COMMON_FIELDS = "OBJECTID,Session_Key,Object_Metadata,Botanical_ID,Planning_Ref_No,Number_Trees,Data_Sheet_URL"
PAGE = 1000  # server maxRecordCount
UA = {"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"}
TIMEOUT = 60

HERE = Path(__file__).parent
CACHE = HERE / "cache" / "trees"
GEN = HERE.parent / "app" / "src" / "generated"
PDFTOTEXT = shutil.which("pdftotext") or "/opt/homebrew/bin/pdftotext"

REF_RE = re.compile(r"^(?:[A-Z]\d{1,2}|\d{1,3})$")
# URL allowlist: the app may only ever link to these portal items
SHEET_RE = re.compile(r"^https://hobartcc\.maps\.arcgis\.com/sharing/rest/content/items/([0-9a-f]{32})/data$")
HEX32 = re.compile(r"^[0-9a-f]{32}$")

downloaded = Counter()  # bytes per kind, for the run report


# ---------------------------------------------------------------- HTTP ---

def http_get(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers=UA)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:  # follows 302 -> S3
                return r.read()
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  {url[:90]}… failed ({e}), retrying")
            time.sleep(5)
    raise AssertionError


def http_json(url):
    body = json.loads(http_get(url))
    if isinstance(body, dict) and "error" in body:  # ArcGIS reports errors in HTTP-200 bodies
        raise RuntimeError(f"server error for {url}: {body['error']}")
    return body


def cached_json(rel, url, kind="json"):
    """Fetch url once; keep the raw body at CACHE/rel (`.part` then rename)."""
    path = CACHE / rel
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    body = http_json(url)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(path.suffix + ".part")
    part.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    os.replace(part, path)
    downloaded[kind] += len(json.dumps(body))
    return body


def download(url, path, kind, timeout=300):
    if path.exists():
        return False
    data = http_get(url, timeout=timeout)
    if not data.startswith(b"%PDF"):  # RuntimeError: enrich() catches it and adds the browser hint
        raise RuntimeError(f"{url}: not a PDF ({data[:40]!r})")
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(path.suffix + ".part")
    part.write_bytes(data)
    os.replace(part, path)
    downloaded[kind] += len(data)
    return True


# ------------------------------------------------------- licence guard ---

def check_licence():
    """Abort unless the live portal item + service still say CC BY 4.0 /
    City of Hobart. Always LIVE (never cached) — like build_raster's guard.
    Stricter than build_raster's flavour regex: it pins the version, because
    a licence change here would silently re-license 460 addresses."""
    item = http_json(f"{PORTAL}/{ITEM}?f=json")
    root = http_json(f"{SERVICE}?f=json")
    lic = item.get("licenseInfo") or ""
    acc = (item.get("accessInformation") or "").strip()
    copy = (root.get("copyrightText") or "").strip()
    has_link = bool(re.search(r"creativecommons\.org/licenses/by/4\.0/", lic, re.I))
    print(f"licence: licenseInfo links CC BY 4.0 = {has_link}, accessInformation={acc!r}, copyrightText={copy!r}")
    if not has_link:
        raise SystemExit("REFUSING: portal item licenseInfo no longer links creativecommons.org/licenses/by/4.0/ "
                         "— re-verify the licence (docs/LICENSING.md) before rebuilding trees.json.")
    if acc != "City of Hobart":
        raise SystemExit(f"REFUSING: accessInformation changed to {acc!r} (expected 'City of Hobart').")
    if copy != "City of Hobart":
        raise SystemExit(f"REFUSING: service copyrightText changed to {copy!r} (expected 'City of Hobart').")
    (CACHE / "item.json").write_text(json.dumps(item, ensure_ascii=False), encoding="utf-8")
    return item


# ---------------------------------------------------------- service data ---

def domains(layer_def):
    out = {}
    for f in layer_def["fields"]:
        d = f.get("domain")
        if d and d.get("codedValues"):
            out[f["name"]] = {cv["code"]: cv["name"] for cv in d["codedValues"]}
    return out


def fetch_layer(layer_id, fields):
    """All features of one layer as GeoJSON (raw pages cached)."""
    features, offset = [], 0
    while True:
        params = urllib.parse.urlencode({
            "where": "1=1", "outFields": fields, "outSR": "4326", "f": "geojson",
            "orderByFields": "OBJECTID", "resultOffset": offset, "resultRecordCount": PAGE,
        })
        page = cached_json(f"pages/layer{layer_id}-{offset}.json", f"{SERVICE}/{layer_id}/query?{params}")
        got = page.get("features", [])
        features.extend(got)
        exceeded = (page.get("properties") or {}).get("exceededTransferLimit") or page.get("exceededTransferLimit")
        if len(got) < PAGE and not exceeded:
            break
        offset += len(got)
    return features


def round_coords(c):
    if isinstance(c[0], (int, float)):
        return [round(c[0], 6), round(c[1], 6)]
    return [round_coords(x) for x in c]


# ------------------------------------------------------------- text utils ---

QUOTES = {"‘": "'", "’": "'", "‚": "'", "“": '"', "”": '"',
          "–": "-", "—": "-", "‐": "-", "‑": "-", "−": "-", "×": "x", " ": " "}


def normalise(s):
    for k, v in QUOTES.items():
        s = s.replace(k, v)
    return " ".join(s.split())


def fold(s):
    """Comparison key: normalised, lower-case, one quote style."""
    return normalise(s).replace('"', "'").lower()


def latin1_label(s):
    """Map label text into the glyph range the app ships (0–255): typographic
    quotes/dashes to ASCII, anything else to its NFKD base letters or dropped."""
    out = []
    for ch in normalise(s):
        if ord(ch) < 256:
            out.append(ch)
        else:
            out.append(unicodedata.normalize("NFKD", ch).encode("ascii", "ignore").decode())
    label = " ".join("".join(out).split())
    assert all(ord(c) < 256 for c in label), label
    return label


def unshift(text):
    """Undo the ASCII−29 glyph-code shift of the 2012-era sheets (see module
    docstring). Only applied when a page has no readable 'Reference'. \\n is
    kept as a line break (it doubles as the code for an apostrophe — lost)."""
    if "Reference" in text:
        return text
    out = []
    for ch in text:
        o = ord(ch)
        if ch in "\n\f\r ":  # pdftotext's own layout chars/padding, not glyphs
            out.append(ch)
        elif 3 <= o <= 0x61:
            out.append(chr(o + 29))
        elif ch == "µ":  # MacRoman-ish quote glyphs seen in addresses
            out.append("‘")
        elif ch == "¶":
            out.append("’")
        else:
            out.append(ch)
    return "".join(out)


# -------------------------------------------------- register/sheet parsing ---

HEADER_RE = re.compile(r"Reference:\s*([A-Z]{1,2}\s?\d{1,3}[A-Za-z]?|\d{1,3})\b")
# form labels sit in the left column (small indent); values start at col ~20+
LABEL_RE = re.compile(r"^\s{0,15}(Address|Name of Tree/?s?|Owners? of the Land|Reasons? for [Ss]ignificance"
                      r"|Nominators?\b|Assessment\b|CATEGORY\b|Photo:)(.*)$")
STOP_LABELS = ("Owner", "Reasons", "Nominators", "Assessment", "CATEGORY", "Photo:")
# strict "Genus species" (lower-case epithet) — tells a tree-name row from a
# wrapped address row ("Sandy Bay"); the line parser uses the looser check
BINOMIAL_RE = re.compile(r"^[A-Z][a-z]+(?:\s+(?:x\s+)?[a-z][a-z-]+|\s+spp?\.)")
LOOSE_BOT_RE = re.compile(r"^[A-Z][a-z]+\s+(?:x\s+)?[A-Za-z][a-z-]+")  # "Ulmus Glabra Lutescens" too


def parse_entry_page(text):
    """One register/sheet page -> (ref, address, name_line) or None.
    Rows are (label|None, right-column content). The value of a label is the
    run of content rows touching the label row (the label may be printed on,
    above or below its value), bounded by blank rows and other labels."""
    lines = text.split("\n")
    hdr = ref = None
    for i, ln in enumerate(lines[:15]):
        m = HEADER_RE.search(ln)
        if m:
            hdr, ref = i, m.group(1).replace(" ", "")
            break
    if hdr is None:
        return None
    rows = []
    for ln in lines[hdr + 1:]:
        m = LABEL_RE.match(ln)
        label, content = (m.group(1), m.group(2)) if m else (None, ln)
        label = re.sub(r"Tree/?s?$", "Tree/s", label) if label else None
        if label and label.startswith(STOP_LABELS):
            break
        rows.append((label, content.strip()))

    def block(idx, exclude=()):
        """Content rows of the field whose label is at rows[idx]."""
        taken = []
        lab, cont = rows[idx]
        if cont:  # 2012 style: label + value on one line, continuation below
            taken.append(idx)
        else:     # 2020 style: value above the label (and maybe wraps below)
            j = idx - 1
            while j >= 0 and j not in exclude and rows[j][0] is None and rows[j][1]:
                taken.insert(0, j)
                j -= 1
        j = idx + 1
        while j < len(rows) and j not in exclude and rows[j][0] is None and rows[j][1]:
            taken.append(j)
            j += 1
        return taken

    name_idx = next((i for i, r in enumerate(rows) if r[0] == "Name of Tree/s"), None)
    addr_idx = next((i for i, r in enumerate(rows) if r[0] == "Address"), None)
    name_rows = block(name_idx) if name_idx is not None else []
    # a wrapped address line ("Sandy Bay") can sit right above the tree name
    # with no blank between: hand leading non-botanical rows back to the address
    while (len(name_rows) > 1 and not BINOMIAL_RE.match(rows[name_rows[0]][1])
           and any(BINOMIAL_RE.match(rows[i][1]) for i in name_rows[1:])):
        name_rows.pop(0)
    addr_rows = block(addr_idx, exclude=set(name_rows)) if addr_idx is not None else []
    name_line = normalise(" ".join(rows[i][1] for i in name_rows)) if name_rows else ""
    return ref, join_address([rows[i][1] for i in addr_rows]), name_line


# Hobart suburbs whose two words the register's narrow Address column wraps
# across lines ("…, Sandy" / "Bay") — joined with a space, not a comma
SUBURB_PAIRS = {tuple(x.lower().split()) for x in (
    "Sandy Bay", "New Town", "Battery Point", "South Hobart", "West Hobart", "North Hobart",
    "Mount Stuart", "Mount Nelson", "Lenah Valley", "Fern Tree", "Tolmans Hill")}
JOIN_CHANGES = {}  # final address -> what a plain comma join would have given (run report)


def join_address(parts):
    """Multi-line address -> one line: '20 Adelaide St' + 'South Hobart' ->
    '20 Adelaide St, South Hobart'; no extra comma before '(' or after ','.
    A line break that merely WRAPS a phrase gets a space instead: inside an
    unclosed '(' ("…South Hobart Primary" / "School), South Hobart"), between
    the halves of a suburb name ("…, Sandy" / "Bay"), or when the next line
    starts lower-case or with ')' ("Domain House Site" / "near Graphics
    Building"). ' )' and doubled commas are collapsed afterwards."""
    out = naive = ""
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if not out:
            out = naive = p
            continue
        plain = out.endswith((",", "(")) or p.startswith(("(", ",", ")"))
        naive += (" " if plain else ", ") + p
        last = re.findall(r"[A-Za-z]+", out)[-1:]
        first = re.findall(r"[A-Za-z]+", p)[:1]
        wrapped = (out.count("(") > out.count(")")
                   or (last and first and (last[0].lower(), first[0].lower()) in SUBURB_PAIRS)
                   or p[0].islower() or p[0] == ")")
        out += (" " if plain or wrapped else ", ") + p
    out = re.sub(r"\s+\)", ")", out)
    out = re.sub(r"\s*,(?:\s*,)+", ",", out)
    out = normalise(out.strip(" ,"))
    if out != normalise(naive.strip(" ,")):
        JOIN_CHANGES[out] = normalise(naive.strip(" ,"))
    return out


COUNT_RE = re.compile(r"\(?\s*\b\d+\s*trees?\b\s*\)?|\bx\s?\d+\b|\bgroup\b|\bhedge\b", re.I)


GENUS_SP_RE = re.compile(r"^[A-Z][a-z]+\s+(?:spp?\.|[a-z]+)$")  # "Crataegus sp." / "Quercus robur"


def parse_name_line(line, upstream):
    """'Botanical – Common (n trees)' / 'Botanical (Common) …' / 'Common
    (Botanical)' / 'Botanical Common, n Trees' -> (botanical, common) or
    None. `upstream` = the service's candidate name(s); the last form needs
    them to know where the botanical part ends (longest candidate first).
    Multi-species lines yield the FIRST species' common name."""
    s = normalise(line)
    if not s:
        return None
    candidates = [upstream] if isinstance(upstream, str) else sorted(upstream, key=len, reverse=True)
    m = re.match(r"^(?P<bot>[^()]+?)\s*-\s+(?P<com>[^(),;]+)", s)  # "babylonica- weeping willow" too
    if m and LOOSE_BOT_RE.match(m.group("bot")):
        return m.group("bot").strip(), clean_common(m.group("com"))
    if "(" in s:
        bot, rest = s.split("(", 1)
        # take the first paren group whose content is not a count/hedge note;
        # tolerate an unclosed nested paren ("Big Tree (Wellingtonia)")
        depth, buf, groups = 1, "", []
        for ch in rest:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    groups.append(buf)
                    buf = ""
                    continue
            buf += ch
        if buf.strip():
            groups.append(buf + (")" if buf.count("(") > buf.count(")") else ""))
        for g in groups:
            c = clean_common(g)
            if c and not re.match(r"^(multiple|hedge|group|including|various|\d)", c, re.I):
                # inverted "Hawthorn hedge (Crataegus sp.)": the PAREN genus is the
                # one the service knows, the outside one is not
                if (GENUS_SP_RE.match(g.strip()) and genus_match(g, candidates)
                        and not genus_match(bot, candidates)):
                    return g.strip(), clean_common(bot)
                if LOOSE_BOT_RE.match(bot.strip()):
                    return bot.strip(), c
    for up in candidates:
        if up and fold(s).startswith(fold(up)):
            c = clean_common(re.sub(r"^\s*'[^']*'\s*", "", s[len(up):]))  # drop a cultivar the domain lacks
            if c:
                return up, c
    return None


def clean_common(s):
    s = COUNT_RE.sub("", normalise(s))
    s = re.sub(r"\s+", " ", s).strip(" ,;-:")
    s = re.sub(r"^(or|and)\s+", "", s)
    if not s or re.fullmatch(r"[\d\W]+", s) or len(s) > 60:
        return ""
    return s[0].upper() + s[1:]


def genus_match(bot, candidates):
    """The upstream candidate whose genus matches the PDF's botanical text,
    tolerating one-sided typos (Platinus/Platanus, Lauris/Laurus, Tilea/
    Tilia …) via a similarity ratio; None when the genera really differ."""
    g = fold(bot).split()[0] if bot.strip() else ""
    best, score = None, (0, 0)
    for c in candidates:
        cg = fold(c).split()[0]
        r = (difflib.SequenceMatcher(None, g, cg).ratio(), difflib.SequenceMatcher(None, fold(bot), fold(c)).ratio())
        if r > score:
            best, score = c, r
    return best if score[0] >= 0.8 else None


def pdf_pages_text(pdf, txt, first_last=None):
    """pdftotext -layout -> list of page strings (cached as txt)."""
    if not txt.exists():
        cmd = [PDFTOTEXT, "-layout"]
        if first_last:
            cmd += ["-f", str(first_last[0]), "-l", str(first_last[1])]
        part = txt.with_suffix(".txt.part")
        subprocess.run(cmd + [str(pdf), str(part)], check=True)
        os.replace(part, txt)
    return txt.read_text(encoding="utf-8", errors="replace").split("\f")


def title_address(title, ref):
    """Fallback address from the item title, e.g. 'Significant Tree Document
    - REF 83 _ Government House _ Chilean pepper tree' -> 'Government House,
    Chilean pepper tree' (used only when no PDF gave an Address)."""
    t = re.sub(r"^Significant\s+Trees?\s+Documents?\s*[-–:]*\s*", "", title, flags=re.I)
    parts = [p.strip(" -–,") for p in re.split(r"_|\s-\s", t)]
    parts = [p for p in parts if p and not re.fullmatch(r"(map|objection)", p, re.I)]
    if parts:
        parts[0] = re.sub(rf"^(?:REF\.?\s*)?{re.escape(ref)}\b[\s,-]*", "", parts[0], flags=re.I).strip()
    return normalise(", ".join(p for p in parts if p))


# ------------------------------------------------------------------- main ---

def ref_key(ref):
    m = re.match(r"^([A-Z]*)(\d+)$", ref)
    return (1 if not m.group(1) else 0, m.group(1), int(m.group(2)))


def main():
    args = sys.argv[1:]
    skip_enrich, fresh = "--skip-enrich" in args, "--fresh" in args
    unknown = [a for a in args if a not in ("--skip-enrich", "--fresh")]
    if unknown:
        raise SystemExit(f"unknown args: {unknown}\n{__doc__.split('Run:')[1]}")
    CACHE.mkdir(parents=True, exist_ok=True)
    if fresh:
        for p in CACHE.rglob("*"):
            if p.is_file() and p.suffix != ".pdf":
                p.unlink()
        print("--fresh: dropped cached JSON/text (PDFs kept)")

    item = check_licence()  # FIRST — before any data is touched

    # 1. layer definitions -> domains ------------------------------------
    defs = {k: cached_json(f"layer{n}.json", f"{SERVICE}/{n}?f=json") for k, n in LAYERS.items()}
    dom = domains(defs["points"])
    botanical, accuracy = dom["Botanical_ID"], dom["Session_Key"]
    assert len(accuracy) == 13, accuracy
    assert len(botanical) > 300, len(botanical)
    assert domains(defs["areas"]).get("Session_Key") == accuracy, "layer 4 Session_Key domain differs"

    # 2. features ----------------------------------------------------------
    raw = {"points": fetch_layer(1, COMMON_FIELDS),
           "areas": fetch_layer(4, COMMON_FIELDS + ",Botanical_Name")}
    print(f"fetched {len(raw['points'])} points, {len(raw['areas'])} areas")
    assert len(raw["points"]) >= 450 and len(raw["areas"]) >= 30, "suspiciously few features"

    problems, warnings = [], []
    collections = {}
    per_ref = defaultdict(lambda: {"names": Counter(), "prefer": "", "trees": [], "notes": Counter(), "sheets": set()})
    sheet_refs = defaultdict(set)
    for kind, feats in raw.items():
        out = []
        for f in feats:
            p = f["properties"]
            oid = p.get("OBJECTID")
            ref = (p.get("Planning_Ref_No") or "").strip()
            if not REF_RE.match(ref):
                problems.append(f"{kind} OBJECTID {oid}: Planning_Ref_No {ref!r} does not match {REF_RE.pattern}")
                continue
            m = SHEET_RE.match((p.get("Data_Sheet_URL") or "").strip())
            if not m:
                problems.append(f"{kind} OBJECTID {oid} ({ref}): Data_Sheet_URL {p.get('Data_Sheet_URL')!r} not allowlisted")
                continue
            sheet = m.group(1)
            acc = p.get("Session_Key")
            if acc not in accuracy:
                problems.append(f"{kind} OBJECTID {oid} ({ref}): Session_Key {acc!r} not in domain")
                continue
            code = p.get("Botanical_ID")
            extra = ""  # a second name candidate when layer 4's two fields disagree
            if kind == "areas":  # string code on layer 4; Botanical_Name alongside
                try:
                    code = int(str(code).strip())
                except (TypeError, ValueError):
                    code = None
                decoded = botanical.get(code)
                bname = (p.get("Botanical_Name") or "").strip()
                if decoded and bname and fold(decoded) != fold(bname):
                    # both become candidates; the register/sheet decides (F11: ID says
                    # Crataegus, Name says Quercus — the register confirms the hawthorn),
                    # Botanical_Name is the fallback when neither is confirmed
                    warnings.append(f"areas {ref}: Botanical_ID {code} -> {decoded!r} but Botanical_Name {bname!r}; both kept as candidates")
                    extra = decoded
                name = bname or decoded
            else:
                name = botanical.get(code)
            if not name:
                problems.append(f"{kind} OBJECTID {oid} ({ref}): Botanical_ID {code!r} has no name")
                continue
            geom = f["geometry"]
            if not geom or not geom.get("coordinates"):
                problems.append(f"{kind} OBJECTID {oid} ({ref}): empty geometry")
                continue
            r = per_ref[ref]
            r["names"][name] += 1
            if extra:
                r["names"][extra] += 1
                r["prefer"] = name
            if p.get("Number_Trees") is not None:
                r["trees"].append(int(p["Number_Trees"]))
            note = (p.get("Object_Metadata") or "").strip()
            if note:
                r["notes"][note] += 1
            r["sheets"].add(sheet)
            sheet_refs[sheet].add(ref)
            out.append({"type": "Feature",
                        "geometry": {"type": geom["type"], "coordinates": round_coords(geom["coordinates"])},
                        "properties": {"ref": ref, "sheet": sheet, "acc": acc}})
        collections[kind] = {"type": "FeatureCollection", "features": out}
    if problems:
        print("\n".join("PROBLEM: " + s for s in problems))
        raise SystemExit(f"{len(problems)} feature(s) violate the data assumptions above — fix the script, not the data")

    # working table; `_names` (all candidates) and `_bot` (what the PDF said)
    # are resolved into `name` after enrichment and never written out
    refs = {}
    for ref, r in per_ref.items():
        refs[ref] = {
            "name": "", "label": "", "common": "", "address": "",
            "trees": max(r["trees"]) if r["trees"] else None,
            "note": r["notes"].most_common(1)[0][0] if r["notes"] else "",
            "sheets": sorted(r["sheets"]),
            "_names": r["names"], "_bot": "", "_prefer": r["prefer"],
        }
    for sheet, rs in sheet_refs.items():
        if len(rs) > 1:
            warnings.append(f"sheet {sheet} is shared by refs {sorted(rs)}")

    # 3. sheet metadata (282 small JSONs, cached individually) --------------
    sheet_ids = sorted(sheet_refs)
    with ThreadPoolExecutor(6) as pool:
        metas = list(pool.map(lambda i: cached_json(f"items/{i}.json", f"{PORTAL}/{i}?f=json", "item-json"), sheet_ids))
    sheets = {}
    for sid, meta in zip(sheet_ids, metas):
        assert meta.get("type") == "PDF", (sid, meta.get("type"))
        assert meta.get("access") == "public", (sid, meta.get("access"))
        sheets[sid] = {"bytes": int(meta["size"]), "title": (meta.get("title") or "").strip()}
    print(f"sheet metadata: {len(sheets)} PDFs, {sum(s['bytes'] for s in sheets.values())/1e6:.0f} MB total upstream")

    # 4. enrichment ------------------------------------------------------------
    conflicts = []
    if not skip_enrich:
        enrich(refs, conflicts)
    else:
        print("--skip-enrich: no common names / register addresses")

    # 5. resolve names, fallbacks, labels ---------------------------------------
    title_only = 0
    for ref, r in refs.items():
        names, bot, prefer = r.pop("_names"), r.pop("_bot"), r.pop("_prefer")
        confirmed = genus_match(bot, names) if bot else None
        if len(names) > 1:
            pick = confirmed or prefer or names.most_common(1)[0][0]
            why = "register/sheet confirms" if confirmed else ("Botanical_Name" if prefer else "majority")
            warnings.append(f"{ref}: several botanical names {dict(names)} -> {pick!r} ({why})")
            r["name"] = pick
        else:
            r["name"] = next(iter(names))
        if not r["address"]:
            title_only += 1
            r["address"] = max((title_address(sheets[s]["title"], ref) for s in r["sheets"]), key=len)
        r["label"] = latin1_label(r["common"] or r["name"])

    # 6. asserts + write --------------------------------------------------------
    for kind, fc in collections.items():
        for f in fc["features"]:
            assert f["properties"]["ref"] in refs and f["properties"]["sheet"] in sheets
    assert all(HEX32.match(s) for s in sheets)
    assert all(r["name"] for r in refs.values())
    assert sum(s["bytes"] for s in sheets.values()) > 300e6
    assert all(all(ord(c) < 256 for c in r["label"]) for r in refs.values())
    assert all(isinstance(r[k], str) for r in refs.values() for k in ("name", "label", "common", "address", "note"))

    out = {
        "meta": {
            "item": ITEM, "source": SERVICE, "licence": "CC BY 4.0", "attribution": "City of Hobart",
            "built": time.strftime("%Y-%m-%d"),
            "itemModified": time.strftime("%Y-%m-%d", time.gmtime(item["modified"] / 1000)),
            "points": len(collections["points"]["features"]), "areas": len(collections["areas"]["features"]),
        },
        "points": collections["points"],
        "areas": collections["areas"],
        "refs": {k: refs[k] for k in sorted(refs, key=ref_key)},
        "accuracy": dict(sorted(accuracy.items())),
        "sheets": dict(sorted(sheets.items())),
    }
    GEN.mkdir(parents=True, exist_ok=True)
    dest = GEN / "trees.json"
    part = dest.with_suffix(".json.part")
    part.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
    os.replace(part, dest)

    if warnings:
        print("\n".join("warning: " + w for w in warnings))
    rejoined = [(k, JOIN_CHANGES[r["address"]], r["address"]) for k, r in refs.items() if r["address"] in JOIN_CHANGES]
    if rejoined:
        print("address joins changed by the wrapped-line rules (plain comma join -> used):")
        for k, before, after in sorted(rejoined, key=lambda t: ref_key(t[0])):
            print(f"  {k}: {before!r}\n  {' ' * len(k)}  -> {after!r}")
    if conflicts:
        print("CONFLICTS (common name NOT taken; label = botanical name):\n" + "\n".join("  " + c for c in conflicts))
    with_common = sum(1 for r in refs.values() if r["common"])
    with_addr = sum(1 for r in refs.values() if r["address"])
    missing = sorted((k for k, r in refs.items() if not r["common"]), key=ref_key)
    print(f"refs: {len(refs)} | common name {with_common}/{len(refs)} | address {with_addr}/{len(refs)}"
          f" ({title_only} from item titles only)")
    print(f"missing common name: {' '.join(missing) or '-'}")
    print("downloaded this run: " + (", ".join(f"{k} {v/1e6:.1f} MB" for k, v in downloaded.items())
                                     if downloaded else "nothing (all cached)"))
    print(f"wrote {dest} ({dest.stat().st_size/1e6:.2f} MB)")


def enrich(refs, conflicts):
    """Common names + addresses: register PDF first, then the data sheets of
    the refs the register left without a parsed tree name."""
    reg_pdf = CACHE / "register.pdf"
    if not reg_pdf.exists():
        try:
            download(REGISTER_URL, reg_pdf, "register-pdf", timeout=600)
        except Exception as e:  # noqa: BLE001
            raise SystemExit(f"register PDF: {e}\nhobartcity.com.au blocks scripted GETs; save it from a browser "
                             f"to {reg_pdf} and rerun.")
    pages = pdf_pages_text(reg_pdf, CACHE / "register.txt")
    print(f"register: {len(pages)} pages")

    parsed = {}
    for pg in pages:
        e = parse_entry_page(pg)
        if e:
            ref, addr, name_line = e
            if ref in parsed:
                print(f"  register: duplicate entry page for {ref}, keeping the first")
                continue
            parsed[ref] = (addr, name_line)
    hits = sum(1 for r in parsed if r in refs)
    print(f"register: {len(parsed)} entry pages, {hits} match a feature ref")
    # a parser regression must not degrade into "download all 282 sheets"
    assert hits >= 200, f"register parse regressed ({hits} refs matched) — refusing to fall back to bulk sheet downloads"
    apply_facts(refs, parsed, "register", conflicts)

    # data sheets ONLY for refs the register gave no botanical line for
    # (bounded: the 2024 numeric refs + a few letters). A ref whose register
    # line CONFLICTS with the service is not retried: its sheet is that page.
    todo = [r for r in sorted(refs, key=ref_key) if not refs[r]["common"] and not refs[r]["_bot"]]
    sheet_of = {r: refs[r]["sheets"][0] for r in todo}
    need = sorted(set(sheet_of.values()))
    print(f"sheets: {len(todo)} refs unresolved by the register -> fetching {len(need)} data sheets")
    assert len(need) <= 100, f"{len(need)} sheets wanted — the docstring promises never to fetch all 282 (446 MB)"

    def get(sid):
        return download(f"{PORTAL}/{sid}/data", CACHE / "sheets" / f"{sid}.pdf", "sheet-pdf")
    with ThreadPoolExecutor(4) as pool:
        list(pool.map(get, need))
    parsed = {}
    for r in todo:
        sid = sheet_of[r]
        text = pdf_pages_text(CACHE / "sheets" / f"{sid}.pdf", CACHE / "sheets" / f"{sid}.txt", (1, 1))[0]
        text = unshift(text)
        e = parse_entry_page(text)
        if not e:
            print(f"  sheet {sid} ({r}): no 'Reference:' header on page 1")
            continue
        ref, addr, name_line = e
        if ref != r:
            print(f"  sheet {sid}: page says {ref!r} but the feature says {r!r}; using the feature's ref")
        parsed[r] = (addr, name_line)
    apply_facts(refs, parsed, "sheet", conflicts)


def apply_facts(refs, parsed, source, conflicts):
    """Merge (address, name_line) per ref into refs: the PDF's Address wins
    over anything title-derived; the common name is taken only when the
    line parses AND its genus matches one of the ref's upstream names."""
    got_common = got_addr = 0
    for ref, (addr, name_line) in parsed.items():
        if ref not in refs:
            continue
        r = refs[ref]
        if addr and not r["address"]:
            r["address"] = addr
            got_addr += 1
        if r["common"] or r["_bot"]:
            continue
        res = parse_name_line(name_line, r["_names"])
        if not res:
            if name_line:
                print(f"  {source} {ref}: unparsed name line {name_line!r}")
            continue
        bot, common = res
        r["_bot"] = bot
        if not genus_match(bot, r["_names"]):
            conflicts.append(f"{ref}: {source} says {bot!r} ({common}); service says {dict(r['_names'])}")
            continue
        r["common"] = common
        got_common += 1
    print(f"{source}: +{got_common} common names, {got_addr} addresses")


if __name__ == "__main__":
    main()
