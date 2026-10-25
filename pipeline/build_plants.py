#!/usr/bin/env python3
"""Build app/src/generated/plants.json — plant sheets from the Understorey
Network Tasmania plant database + per-community species lists from From
Forest to Fjaeldmark (F2F).

UN source (verified 2026-10-25): https://database.understorey-network.org.au
(WordPress). Two halves:
  * REST (wp-json/wp/v2, CORS on, 100/page, X-WP-Total/X-WP-TotalPages):
    `plant` (1,884 posts: id, slug, title, term ids), the taxonomies
    `community` / `growth-form` / `plants-status` / `family-index`, and
    `media` (~2,018 attachments: media_details.file + sizes with filesize).
    REST `acf` is EMPTY — the descriptive fields exist only in the HTML.
  * HTML plant pages /plant/<slug> (~93 KB, ~13 KB gzipped). Markup:
      <div class='info'><p><span>Common Name:</span> <span …>value</span></p>
      (Common Name / Family / Form Description / Height (m) / Flowers /
      Fruit), then <div class='info'><h5>Habitat Notes</h5> <p …>value</p>
      (Habitat Notes / General Notes; Site/Soil/Frost Tolerance and the
      propagation blocks are NOT taken), a "Flowering Month" calendar whose
      active months carry class="month assigned", and a glide carousel of
      <li class="glide__slide"> photos: <img src="…/wp-content/webp-express/
      webp-images/doc-root/wp-content/uploads/YYYY/MM/<file>.jpg.webp"
      srcset=…> + "Image Credit:" <a>credit</a>. The page is the authority
      for which photos a plant shows, their order and their credits; REST
      media only resolves the 150x150 thumbnail / medium_large suffixes and
      byte sizes.
Photos are copyright of their photographers — only their PATHS go into
plants.json; the device fetches the files from UN. Propagation prose (seed
collection, germination, sowing, cuttings) is out of scope and never read
into the output.

F2F: for each VEGCODE in app/src/generated/f2f_index.json, the section text
(start page → next section start in the same chapter, ≤ 6 pages) is
scanned for binomials ("Eucalyptus amygdalina", "E. amygdalina" expanded
from the last full genus with that initial) that match a UN species key.
Names still unmatched go through ALA name matching (accepted species must
equal exactly one UN key's accepted species — see "ALA synonyms" below;
~1,900 lookups, ~20 s cold, cached one file per name).
Only the resulting species-name lists are emitted; the PDFs (all rights
reserved, docs/LICENSING.md) stay in the gitignored cache.

Output: plants.json = {version: 1, built, plants: [...], communities:
{CODE: [species keys in order of first mention]}} — see the shape in the
feature contract (photo URL = UN_BASE + "/wp-content/uploads/" + path +
suffix + "." + ext).

Run:  python3 pipeline/build_plants.py [--fresh] [--sample N]
  --fresh     drop the cached REST JSON (HTML pages are kept; delete
              pipeline/cache/plants/html/ to re-pull those too)
  --sample N  fetch/parse only the first N plant pages (for measuring);
              writes no output
Needs pdftotext (poppler, brew). Stdlib only. Cache: pipeline/cache/plants/
(REST pages + gzipped HTML, resumable; names/ = ALA name matches; delete
it to re-resolve after an APC change) and pipeline/cache/f2f/ (the PDFs,
downloaded by build_f2f_index.py's URL scheme if missing).
"""
import datetime
import gzip
import html
import http.client
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOST = "database.understorey-network.org.au"
UN_BASE = "https://" + HOST
REST = "/wp-json/wp/v2"
TAXONOMIES = ("community", "growth-form", "plants-status", "family-index")
UA = "IzzyMap-pipeline/1.0 (personal, non-commercial)"
WORKERS = 3  # be polite: ≤ 3 concurrent requests
TIMEOUT = 60
F2F_BASE = "https://nre.tas.gov.au/Documents/"
MAX_SECTION_PAGES = 6
# tripwires pinned to the 2026-10 pull (1,884 plants; catch truncated pulls, not growth)
MIN_PLANTS, MIN_WITH_PHOTO, MIN_COMMON, MIN_F2F_CODES = 1800, 650, 1000, 140

HERE = Path(__file__).parent
CACHE = HERE / "cache" / "plants"
F2F_CACHE = HERE / "cache" / "f2f"
GEN = HERE.parent / "app" / "src" / "generated"
OUT = GEN / "plants.json"
PDFTOTEXT = shutil.which("pdftotext") or "/opt/homebrew/bin/pdftotext"

downloaded = Counter()


# ---------------------------------------------------------------- HTTP ---

_local = threading.local()


def _conns():
    if not hasattr(_local, "conns"):
        _local.conns = {}
    return _local.conns


def http_get(path, gz=False, host=HOST):
    """GET on one keep-alive connection per thread and host -> (status,
    headers, body). gz=True asks for gzip and returns the body still
    compressed (the HTML cache stores it that way)."""
    headers = {"User-Agent": UA, "Accept-Encoding": "gzip" if gz else "identity"}
    for attempt in range(3):
        try:
            c = _conns().get(host)
            if c is None:
                c = _conns()[host] = http.client.HTTPSConnection(host, timeout=TIMEOUT)
            c.request("GET", path, headers=headers)
            r = c.getresponse()
            body = r.read()
            if r.status >= 500 or r.status == 429:
                raise IOError(f"HTTP {r.status}")
            if gz and r.getheader("Content-Encoding") != "gzip":
                body = gzip.compress(body)
            return r.status, r, body
        except (OSError, http.client.HTTPException) as e:
            c = _conns().pop(host, None)
            try:
                c and c.close()
            except Exception:  # noqa: BLE001
                pass
            if attempt == 2:
                raise
            print(f"  {path[:90]} failed ({e}), retrying")
            time.sleep(3 * (attempt + 1))
    raise AssertionError


def rest_pages(endpoint, query=""):
    """All items of a paged REST collection; raw pages cached."""
    items, page, total_pages = [], 1, None
    while True:
        cp = CACHE / "rest" / f"{endpoint}-{page}.json"
        if cp.exists():
            data = json.loads(cp.read_text(encoding="utf-8"))
            body, tp = data["items"], data["total_pages"]
        else:
            st, r, raw = http_get(f"{REST}/{endpoint}?per_page=100&page={page}{query}")
            if st != 200:
                raise RuntimeError(f"{endpoint} page {page}: HTTP {st} {raw[:200]!r}")
            body, tp = json.loads(raw), int(r.getheader("X-WP-TotalPages"))
            cp.parent.mkdir(parents=True, exist_ok=True)
            cp.write_text(json.dumps({"total_pages": tp, "total": r.getheader("X-WP-Total"), "items": body},
                                     ensure_ascii=False), encoding="utf-8")
            downloaded["rest"] += len(raw)
        assert isinstance(body, list), (endpoint, page, str(body)[:200])
        total_pages = total_pages or tp
        items.extend(body)
        if page >= total_pages:
            return items
        page += 1


SLUG_RE = re.compile(r"^[a-z0-9-]+$")


def fetch_page(slug):
    """Cache /plant/<slug> as gzipped HTML; returns the decoded text."""
    assert SLUG_RE.match(slug), slug
    p = CACHE / "html" / f"{slug}.html.gz"
    if not p.exists():
        st, _, body = http_get(f"/plant/{slug}", gz=True)
        if st != 200:
            raise RuntimeError(f"/plant/{slug}: HTTP {st}")
        text = gzip.decompress(body)
        if b"single-plant" not in text:  # captive portal / error page guard
            raise RuntimeError(f"/plant/{slug}: not a plant page ({text[:80]!r})")
        p.parent.mkdir(parents=True, exist_ok=True)
        part = p.with_suffix(".part")
        part.write_bytes(body)
        os.replace(part, p)
        downloaded["html"] += len(body)
    return gzip.decompress(p.read_bytes()).decode("utf-8")


def fetch_all_pages(slugs):
    todo = [s for s in slugs if not (CACHE / "html" / f"{s}.html.gz").exists()]
    print(f"plant pages: {len(slugs) - len(todo)} cached, {len(todo)} to fetch ({WORKERS} workers)")
    t0, done = time.time(), 0
    with ThreadPoolExecutor(WORKERS) as ex:
        for _ in ex.map(fetch_page, todo):
            done += 1
            if done % 100 == 0:
                rate = done / (time.time() - t0)
                print(f"  {done}/{len(todo)}  {rate:.1f} pages/s  ~{(len(todo) - done) / rate / 60:.1f} min left")
    if todo:
        dt = time.time() - t0
        print(f"  fetched {len(todo)} pages in {dt:.0f} s ({len(todo) / dt:.1f}/s, "
              f"{downloaded['html'] / 1e6:.1f} MB gzipped)")


# ------------------------------------------------------------ HTML parse ---

def text_of(fragment):
    """Inner HTML -> plain text: tags dropped, entities decoded, spaces folded."""
    s = re.sub(r"<br\s*/?>", " ", fragment)
    s = re.sub(r"<[^>]+>", "", s)
    s = " ".join(html.unescape(s).split())
    return s or None


INFO_P_RE = re.compile(r"<p><span>([^<:]+):</span>\s*<span class='has-medium-font-size'>(.*?)</span></p>", re.S)
INFO_H5_RE = re.compile(r"<h5>([^<]+)</h5>\s*<p class='has-medium-font-size'>(.*?)</p>", re.S)
P_FIELDS = {"Common Name": "common", "Family": "family", "Form Description": "form",
            "Height (m)": "height", "Flowers": "flowers", "Fruit": "fruit"}
H5_FIELDS = {"Habitat Notes": "habitat", "General Notes": "notes"}
# seen and deliberately ignored (tolerances; propagation prose is out of scope)
P_IGNORED = {"Family Classification (Clade)", "Threatened Species Status", "Permit"}  # status: REST term
H5_IGNORED = {"Site Tolerance", "Soil Tolerance", "Frost Tolerance", "Seed Collection", "Seed Storage Life",
              "Germination Time", "Seed Treatment", "Sowing Notes", "Cutting Notes", "Propagation Notes",
              "Germination Notes", "Seed Notes", "Propagation Method", "Cutting Material", "Seed Viability",
              "Sowing Method", "Seed Pretreatment", "Seed Treatment Method", "Seed Treatment Notes"}
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
FLOWERING_RE = re.compile(r"<h5>Flowering Month</h5>\s*<div class=\"months-list\">(.*?)</div>", re.S)
MONTH_RE = re.compile(r"<span class=\"month( assigned)?\">(\w{3})</span>")
SLIDE_RE = re.compile(r"<li class=\"glide__slide\">(.*?)</li>", re.S)
WEBP_PREFIX = UN_BASE + "/wp-content/webp-express/webp-images/doc-root/wp-content/uploads/"
UPLOADS = UN_BASE + "/wp-content/uploads/"
IMG_RE = re.compile(r"<img\b[^>]*?\bsrc=\"([^\"]+)\"[^>]*>", re.S)
SRCSET_RE = re.compile(r"\bsrcset=\"([^\"]+)\"")
CREDIT_RE = re.compile(r"Image Credit:</span>(.*?)</span>", re.S)
UPLOAD_PATH_RE = re.compile(r"^(\d{4}/\d{2}/[^/?#]+)\.(jpe?g|jpe|png|webp|gif)$", re.I)
SIZE_SUFFIX_RE = re.compile(r"-(\d+)x(\d+)$")

# Propagation-style sentences that UN also writes into the descriptor fields,
# mostly General Notes ("Propagate from seed, leaf cuttings or gemmae…",
# "Stand pots in a saucer of water", "Responds well to pruning"): propagation
# is the out-of-scope content (module docstring), so only sentences about
# propagating, sowing/germinating, potting, watering, fertilising and pruning
# are removed. General gardening hints ("In cultivation needs a sheltered
# position…") deliberately STAY — they were never out of scope. Tuned on the
# 2026-10 pull so ecology survives: road cuttings, wind-pruned heath,
# self-sowing, "capillary bristles", "grows in brackish water", "relies on
# birds to germinate its seed".
CULTIVATION_RE = re.compile(
    r"propagat\w*|(?<!road )\bcuttings?\b|(?<!self-)\bsow(n|s|ing)?\b|germinat\w*|potting|\bpots?\b|\brepot\w*"
    r"|\bwater(ing|ed)\b|\b(plenty of|ample|abundant|regular|extra|supplementary|summer) water"
    r"|\bwater (regularly|must)|saucer of water|standing in water|capillary (watering|matting|beds?)"
    r"|fertili[sz]\w*|(?<!wind-)(?<!wind )\bprun(e|ed|es|ing)\b|tip-prun\w*|seed raising", re.I)
CULTIVATION_KEEP_RE = re.compile(r"after fire|relies on birds|dispersed by", re.I)
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z(])")
MAX_DESCRIPTOR = 300
descriptor_changes = Counter()


def clean_descriptor(field, s):
    """Drop propagation/cultivation sentences, then cap at ~300 chars on a
    sentence boundary ("…" appended when cut)."""
    if not s:
        return s
    sents = SENTENCE_SPLIT_RE.split(s)
    kept = [x for x in sents if not CULTIVATION_RE.search(x) or CULTIVATION_KEEP_RE.search(x)]
    if len(kept) < len(sents):
        descriptor_changes[f"{field}: cultivation sentences dropped"] += 1
    out = " ".join(kept)
    if len(out) > MAX_DESCRIPTOR:
        descriptor_changes[f"{field}: capped"] += 1
        acc = ""
        for x in kept:
            if len(acc) + len(x) + 1 > MAX_DESCRIPTOR - 2:
                break
            acc = f"{acc} {x}".strip()
        if acc:
            out = acc + " …"
        else:  # one long first sentence: cut at a word boundary
            out = out[: MAX_DESCRIPTOR - 1].rsplit(" ", 1)[0].rstrip(",;:") + "…"
    return out or None


unknown_labels = Counter()
external_photos = Counter()
dropped_photos = []


def upload_path(url):
    """img src (webp-express or plain) -> 'YYYY/MM/file.ext' under uploads/, or None."""
    url = html.unescape(url).split("?")[0]
    if url.startswith(WEBP_PREFIX):
        rel = url[len(WEBP_PREFIX):]
        if rel.endswith(".webp") and UPLOAD_PATH_RE.match(rel[:-5]):
            rel = rel[:-5]  # webp-express appends .webp to the original name
    elif url.startswith(UPLOADS):
        rel = url[len(UPLOADS):]
    else:
        return None
    return rel if UPLOAD_PATH_RE.match(rel) else None


def parse_page(text):
    main = text[text.find('<div class="plant">'):text.find("</main>")]
    assert main, "no plant block"
    out = {k: None for k in list(P_FIELDS.values()) + list(H5_FIELDS.values())}
    for label, val in INFO_P_RE.findall(main):
        label = label.strip()
        if label in P_FIELDS:
            out[P_FIELDS[label]] = text_of(val)
        elif label not in P_IGNORED:
            unknown_labels["p:" + label] += 1
    for label, val in INFO_H5_RE.findall(main):
        label = label.strip()
        if label in H5_FIELDS:
            out[H5_FIELDS[label]] = text_of(val)
        elif label not in H5_IGNORED:
            unknown_labels["h5:" + label] += 1
    m = FLOWERING_RE.search(main)
    flowering = []
    if m:
        months = MONTH_RE.findall(m.group(1))
        assert [mo for _, mo in months] == MONTHS, months
        flowering = [i + 1 for i, (a, _) in enumerate(months) if a]
    out["flowering"] = flowering
    out["has_calendar"] = bool(m)
    sci = re.search(r"Scientific Name:\s*(.*?)\s*</span>", main, re.S)
    out["sci"] = text_of(sci.group(1)) if sci else None
    photos = []
    for slide in SLIDE_RE.findall(main):
        im = IMG_RE.search(slide)
        if not im:
            continue
        rel = upload_path(im.group(1))
        if rel is None:  # a few slides hotlink iNaturalist / AusGrass — not UN files, not relayable
            external_photos[urllib.parse.urlsplit(html.unescape(im.group(1))).netloc] += 1
            continue
        srcset = {}
        ss = SRCSET_RE.search(im.group(0))
        if ss:
            for part in ss.group(1).split(","):
                bits = part.split()
                if len(bits) == 2:
                    r2 = upload_path(bits[0])
                    if r2:
                        srcset[bits[1]] = r2
        cr = CREDIT_RE.search(slide)
        credit = text_of(cr.group(1)) if cr else None
        photos.append({"rel": rel, "srcset": srcset, "credit": credit})
    out["photos"] = photos
    return out


# ----------------------------------------------------------- photos ---

EDIT_SUFFIXES = ("-scaled", "-rotated")  # WP's big-image / EXIF-rotation copies


def strip_edits(stem):
    while stem.endswith(EDIT_SUFFIXES):
        stem = stem[: stem.rindex("-")]
    return stem


def media_index(media):
    """'YYYY/MM/file.ext' (as uploaded AND as WP's -scaled/-rotated full copy) -> media item."""
    idx = {}
    for m in media:
        md = m.get("media_details") or {}
        f = md.get("file")
        if not f or "." not in f:
            continue
        idx.setdefault(f, m)
        stem, ext = f.rsplit(".", 1)
        idx.setdefault(strip_edits(stem) + "." + ext, m)  # the untouched original stays on disk
    return idx


def resolve_photo(ph, midx, stats):
    """Page photo -> contract photo entry.

    path = the stem WordPress derives sizes from: every size is named
    '<stem>-WxH.ext' and the full copy '<stem>[-scaled|-rotated].ext', so
    thumb/large are plain suffixes. Images <= 768 px wide have no
    medium_large: large is then the full copy's suffix ("" or "-rotated")
    and bytes its filesize."""
    rel = ph["rel"]
    stem, ext = rel.rsplit(".", 1)
    m = midx.get(rel)
    if m is None:  # no media record: seen only for files that 404 upstream (hibbertia-sericea-var-sericea)
        stats["dropped-no-media-record"] += 1
        dropped_photos.append(rel)
        return None
    stats["media-matched"] += 1
    md = m["media_details"]
    sizes = md.get("sizes") or {}
    full_stem, ext = md["file"].rsplit(".", 1)
    base = strip_edits(full_stem)
    name = base.rsplit("/", 1)[1]
    derived = [sz["file"] for k, sz in sizes.items() if k != "full" and sz.get("file")]
    if any(not f.startswith(name + "-") for f in derived):
        stats["sizes-other-stem"] += 1  # sizes not named after the stripped stem: keep the full stem
        base, name = full_stem, full_stem.rsplit("/", 1)[1]

    def suffix(sz):
        f = (sz or {}).get("file") or ""
        if "." not in f:
            return None
        fs, fe = f.rsplit(".", 1)
        if fe != ext or not fs.startswith(name) or not SIZE_SUFFIX_RE.fullmatch(fs[len(name):]):
            return None
        return fs[len(name):]
    thumb = suffix(sizes.get("thumbnail"))
    large = suffix(sizes.get("medium_large"))
    if large is not None:
        nbytes = sizes["medium_large"].get("filesize")
    else:
        stats["no-medium-large"] += 1
        large = full_stem[len(base):]
        nbytes = md.get("filesize")
    if thumb is None:
        stats["no-thumb"] += 1
    if stem != full_stem:
        stats["page-shows-original"] += 1
    return {"path": base, "ext": ext, "thumb": thumb, "large": large, "bytes": nbytes, "credit": ph["credit"]}


# ----------------------------------------------------------- species key ---

def species_key(title):
    words = title.split()
    if len(words) < 2:
        return None
    g, e = words[0], words[1]
    if e in ("sp.", "sp", "spp.", "x", "×") or not re.match(r"^[A-Z][a-z]+$", g) \
            or not re.match(r"^[a-z][a-z-]+$", e):
        return None
    return f"{g} {e}"


# ------------------------------------------------------------------ F2F ---

def f2f_pdf(name):
    p = F2F_CACHE / name
    if not p.exists():
        import urllib.request
        F2F_CACHE.mkdir(parents=True, exist_ok=True)
        print(f"downloading {name}")
        req = urllib.request.Request(F2F_BASE + name, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
        assert data.startswith(b"%PDF"), name
        p.write_bytes(data)
    return p


PDF_TEXT_MODE = "reading-order-v1"


def pdf_pages(name):
    """Per-page text of one chapter in READING order (cached, gitignored).

    Not `-layout`: F2F pages are two-column, and -layout interleaves the
    columns line by line, so a binomial wrapped across a line break
    ("Acacia" / <other column> / "dealbata") is lost (~160 species over 83
    codes, 2026-10-25 review). Page breaks (\\f) are kept either way, so
    f2f_index.json's page numbers still delimit sections. The cache is keyed
    on PDF size + mtime + extraction mode."""
    pdf = f2f_pdf(name)
    st = pdf.stat()
    key = f"{PDF_TEXT_MODE}:{st.st_size}:{int(st.st_mtime)}"
    cp = CACHE / "f2f-text" / (name + ".json")
    if cp.exists():
        d = json.loads(cp.read_text(encoding="utf-8"))
        if isinstance(d, dict) and d.get("key") == key:
            return d["pages"]
    txt = subprocess.run([PDFTOTEXT, "-enc", "UTF-8", str(pdf), "-"], check=True,
                         capture_output=True).stdout.decode("utf-8", "replace")
    pages = txt.split("\f")
    cp.parent.mkdir(parents=True, exist_ok=True)
    cp.write_text(json.dumps({"key": key, "pages": pages}, ensure_ascii=False), encoding="utf-8")
    return pages


BINOM_RE = re.compile(r"\b([A-Z][a-z]+|[A-Z]\.)\s+([a-z][a-z-]{2,})\b")
# words that start a sentence and are followed by a lower-case word but are
# obviously not genera — only used to keep the "unmatched" report readable
NOT_GENERA = set("""The This These That Those There Their They It Its In On At Of For From With Within By As An A
And Or But If When Where Which While Most Many Some Such Other Others All Both Each Few Several Very Also Often
Usually Generally Typically Locally Mostly Mainly Rarely Sometimes Occasional Occasionally Scattered Dense Open Tall
Low Small Large Common Commonly See Note Notes Table Figure Plate Photo Map Source Group Mapping Code Codes
Communities Community Vegetation Forest Forests Woodland Woodlands Scrub Heath Heathland Grassland Grasslands
Sedgeland Moorland Rainforest Saltmarsh Wetland Wetlands Site Sites Species Areas Area Distribution Description
General Diagnostic Ecology Ecological Conservation Management Comments Comment Floristic Structure Similar Related
Includes Including Dominant Dominated Patches Patch Stands Stand However Although Because Under Over Between Above
Below Along Near North South East West Northern Southern Eastern Western Central Is Are Was Were Be Not No To
King Flinders Furneaux Bass Hobart Launceston Tasmania Tasmanian Mount Lake River Island Islands Cape Bay Point
Plains Plateau Range Ranges Valley Peninsula Coast Example Examples Alpine Subalpine Depauperate Coastal Inland
Lowland Highland Montane Riparian Native Introduced Exotic Mixed Wet Dry Damp Closed Pure Typical""".split())


# Broad F2F species that UN has split (hand-kept). UN lists only the
# segregates of the old broad species, so the one-to-one ALA synonym rule
# cannot map it (ALA still accepts the broad name; no single UN key resolves
# to it). Such a name appears in communities[code] as the GROUP key itself;
# plants.json "groups" tells the app which UN species it stands for.
SPLITS = {
    "Leptecophylla juniperina": {
        "common": "pinkberry",
        "species": ["Leptecophylla abietina", "Leptecophylla divaricata", "Leptecophylla oxycedrus",
                    "Leptecophylla parvifolia", "Leptecophylla pendulosa", "Leptecophylla pogonocalyx"],
    },
}

GENDER_SWAPS = [("us", "a"), ("a", "us"), ("um", "us"), ("us", "um"), ("um", "a"), ("a", "um"),
                ("is", "e"), ("e", "is"), ("er", "ra"), ("ra", "er")]
# report filters only (what counts as "looks like a plant name" in the unmatched list)
GENUS_LIKE = re.compile(r"(a|us|um|is|ia|on|ax|ix|ea|ra|ys|as|os|e)$")
EPITHET_LIKE = re.compile(r"(a|us|um|is|ii|i|ae|ensis|oides|ans|ens|ax|ix|ex|or|ata|ica|ina|ella|ula)$")
NOT_EPITHETS = {"area", "areas", "data", "via", "plus", "thus", "minus", "versus", "genus", "status", "basis",
                "analysis", "taxa", "flora", "fauna", "biota", "media", "criteria", "formula", "extra", "ultra",
                "era", "idea", "ideas", "agenda", "vista", "mesa", "sera", "this", "his", "is", "was", "has",
                "its", "its", "also", "into", "onto", "upon", "within", "elsewhere", "tasmania", "australia",
                "peninsula", "i", "ii", "and", "or", "a"}


INFRA_RE = re.compile(r"\s+(?:subsp|ssp|var)\.\s+([a-z][a-z-]{2,})\b")
# a species named only to say it is missing/different is not "in" the community
NEGATION_RE = re.compile(r"\b(lacks|lacking|absence of|absent|instead of|rather than|rarely if ever|unlike)\b", re.I)
# sentence end: . ! ? not part of an abbreviated genus ("E. ovata"), then a capital
SENTENCE_END_RE = re.compile(r"(?<![A-Z])[.!?]\s+(?=[A-Z])")
NEGATION_WINDOW = 60


# a new clause between the cue and the name ends the cue's scope: "rather than
# the canopy, as is Acacia melanoxylon"; "rather than swampy flats, is
# codominated by …"; "effectively absent, with very uncommon Epacris impressa"
CLAUSE_BREAK_RE = re.compile(r",\s+(is|are|was|were|with|but|which|while|whereas)\b|\bas (is|are)\b", re.I)


# what may sit between two names of one list (an infraspecific rank included)
LIST_GAP_RE = re.compile(r"(?:\s|,|\(|\band\b|\bor\b|\be\.g\.|(?:subsp|ssp|var)\.\s+[a-z][a-z-]+)*")
# cue AFTER the name: "dominated by Helichrysum pumilum, which rarely if ever occurs in AAP"
NEGATION_AFTER_RE = re.compile(r"[\s,]*(which|that)\s+(rarely if ever|never|does not|is absent)\b", re.I)


def negated_mention(text, start, end):
    if NEGATION_AFTER_RE.match(text, end):
        return True
    before = text[max(0, start - NEGATION_WINDOW):start]
    for rx in (SENTENCE_END_RE, CLAUSE_BREAK_RE):
        ends = list(rx.finditer(before))
        if ends:
            before = before[ends[-1].end():]
    return bool(NEGATION_RE.search(before))


def section_text(pages, start, end):
    t = "\n".join(pages[start:end])
    t = re.sub(r"(\w)-\n\s*(\w)", r"\1\2", t)  # re-join hyphenated line breaks
    return t


def f2f_lists(species_set, genera, synonyms=None):
    """synonyms: F2F binomial -> UN key, from ALA name matching (second pass)."""
    synonyms = synonyms or {}
    idx = json.loads((GEN / "f2f_index.json").read_text())["index"]
    by_file = defaultdict(list)
    for code, v in idx.items():
        by_file[v["file"]].append((v["page"], code))
    by_initial = defaultdict(set)
    for g in genera:
        by_initial[g[0]].add(g)
    stats = Counter()
    unmatched, unmatched_codes, variants = Counter(), defaultdict(set), Counter()
    ala_queue, negated_only = set(), []

    def lookup(g, e):
        """UN key for genus+epithet: exact, else a gender-agreement variant of
        the epithet in the same genus ("Orites revoluta" -> UN's "Orites
        revolutus": the epithet must agree with the genus's gender, and the
        two spellings float between floras), else an ALA-accepted-name
        synonym (`synonyms`)."""
        k = f"{g} {e}"
        if k in species_set:
            return k
        for a, b in GENDER_SWAPS:
            if e.endswith(a):
                k2 = f"{g} {e[: len(e) - len(a)]}{b}"
                if k2 in species_set:
                    variants[f"{k} -> {k2}"] += 1
                    return k2
        if k in SPLITS:
            stats["group:" + k] += 1
            return k
        if k in synonyms:
            stats["syn:" + k] += 1
            return synonyms[k]
        return None

    out = {}
    for name, entries in sorted(by_file.items()):
        pages = pdf_pages(name)
        starts = sorted(set(p for p, _ in entries))
        for page, code in sorted(entries):
            later = [s for s in starts if s > page]
            end = min(later[0] if later else len(pages), page + MAX_SECTION_PAGES)
            text = section_text(pages, page, end)
            seen, lst, last_full, negated = set(), [], {}, {}
            carry, prev_end = False, 0
            for m in BINOM_RE.finditer(text):
                g, e = m.group(1), m.group(2)
                # negation, carried along a list: "lacks several species common to
                # SCL (e.g. Acrotriche cordata and Eutaxia microphylla)" — once a
                # name is negated, names joined to it by , / and / or (e.g. and
                # an opening parenthesis allowed) are too, until anything else
                # (a sentence end, a closing ")", a clause, ordinary words)
                neg = negated_mention(text, m.start(), m.end()) or \
                    (carry and bool(LIST_GAP_RE.fullmatch(text, prev_end, m.start())))
                carry, prev_end = neg, m.end()
                if g.endswith("."):  # "E. amygdalina": expand the abbreviated genus
                    ini, last = g[0], last_full.get(g[0])
                    if last and lookup(last, e):  # the genus just named wins ("Ehrharta tasmanica, E. acuminata")
                        g = last
                    else:
                        if last:  # pass 2 may resolve it through ALA (Ehrharta acuminata = Tetrarrhena acuminata)
                            ala_queue.add(f"{last} {e}")
                        exact = [x for x in by_initial[ini]
                                 if f"{x} {e}" in species_set or f"{x} {e}" in synonyms or f"{x} {e}" in SPLITS]
                        if len(exact) == 1:  # the only UN genus with this initial that has the epithet
                            g = exact[0]
                            stats["abbrev-by-epithet"] += 1
                        elif last:
                            g = last  # unmatched: report under the nearest genus
                        else:
                            continue
                elif g in genera or (g not in NOT_GENERA and GENUS_LIKE.search(g) and EPITHET_LIKE.search(e)):
                    last_full[g[0]] = g  # a genus, not a sentence-initial word ("Eastern ...")
                key = lookup(g, e)
                if key in SPLITS:  # "Leptecophylla juniperina subsp. parvifolia" -> UN's segregate
                    sub = INFRA_RE.match(text, m.end())
                    if sub and f"{g} {sub.group(1)}" in species_set:
                        key = f"{g} {sub.group(1)}"
                        stats["split-by-subsp"] += 1
                if key and neg:
                    negated.setdefault(key, text[max(0, m.start() - 60):m.end() + 30].replace("\n", " "))
                    continue
                if key:
                    if key not in seen:
                        seen.add(key)
                        lst.append(key)
                elif (g in genera or (g not in NOT_GENERA and GENUS_LIKE.search(g))) and EPITHET_LIKE.search(e) \
                        and e not in NOT_EPITHETS:
                    unmatched[f"{g} {e}"] += 1
                    unmatched_codes[f"{g} {e}"].add(code)
            out[code] = lst
            for k, ctx in negated.items():
                if k not in seen:  # named ONLY as absent/contrast in this section
                    negated_only.append((code, k, ctx))
    return out, unmatched, unmatched_codes, variants, stats, ala_queue, negated_only


# ------------------------------------------------------- ALA synonyms ---
# F2F (2005/2017) uses names that have since moved (Leucopogon/Astroloma ->
# Styphelia, Callistemon -> Melaleuca, E. delegatensis subsp. -> species
# rank). ALA's name-matching service (same as build_records.py) maps any
# name, synonym or not, to its accepted name in the Australian Plant Census;
# its `species` field is the species-rank parent of that accepted name. An
# unmatched F2F binomial is mapped to a UN key only when both resolve to the
# SAME accepted species and exactly one UN key does — so weeds (not in UN)
# stay unmatched, and lumped taxa shared by two UN keys are not guessed.

ALA_NM_HOST = "namematching-ws.ala.org.au"
ALA_NM_PATH = "/api/search?q="
NM_FIELDS = ("success", "scientificName", "rank", "species", "matchType", "kingdom", "issues")


def namematch(name):
    """ALA name-matching result for one binomial (cached, one file per name)."""
    p = CACHE / "names" / (re.sub(r"[^A-Za-z0-9-]+", "_", name) + ".json")
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    st, _, body = http_get(ALA_NM_PATH + urllib.parse.quote(name), host=ALA_NM_HOST)
    if st != 200:
        raise RuntimeError(f"namematch {name!r}: HTTP {st} {body[:120]!r}")
    r = json.loads(body)
    d = {"q": name, **{f: r.get(f) for f in NM_FIELDS}}
    p.parent.mkdir(parents=True, exist_ok=True)
    part = p.with_suffix(".part")
    part.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
    os.replace(part, p)
    downloaded["names"] += 1
    return d


def accepted_species(d):
    if d.get("success") and d.get("kingdom") == "Plantae" and d.get("species"):
        return d["species"]
    return None


def spelling_variant(a, b):
    ga, ea = a.split()[:2]
    gb, eb = b.split()[:2]
    return ga == gb and ea.replace("-", "")[:5] == eb.replace("-", "")[:5]


def ala_synonyms(unmatched_names, species_set):
    names = sorted(set(unmatched_names) | species_set)
    todo = [n for n in names if not (CACHE / "names" / (re.sub(r"[^A-Za-z0-9-]+", "_", n) + ".json")).exists()]
    if todo:
        print(f"ALA name matching: {len(names) - len(todo)} cached, {len(todo)} to look up ({WORKERS} workers)")
        t0 = time.time()
        with ThreadPoolExecutor(WORKERS) as ex:
            list(ex.map(namematch, todo))
        print(f"  {len(todo)} lookups in {time.time() - t0:.0f} s")
    res = {n: namematch(n) for n in names}
    by_acc = defaultdict(list)
    for k in sorted(species_set):
        acc = accepted_species(res[k])
        if acc:
            by_acc[acc].append(k)
    un_resolved = sum(len(v) for v in by_acc.values())
    synonyms, ambiguous = {}, []
    fuzzy_dropped = []
    for n in sorted(set(unmatched_names)):
        acc = accepted_species(res[n])
        if not acc:
            continue
        if res[n].get("matchType") not in ("exactMatch", "canonicalMatch") and not spelling_variant(n, acc):
            # a fuzzy match is trusted only as a pure spelling fix (same genus,
            # same epithet stem: "Callistemon pallida", "Acaena novaezelandiae");
            # fuzzy-onto-a-synonym chains two guesses ("Eucalyptus glandulosus"
            # ~ E. glandulosa = E. amygdalina). ALA's scientificName is already
            # the ACCEPTED name, so the matched spelling itself is not available.
            fuzzy_dropped.append(f"{n} ~> {acc} ({res[n].get('matchType')})")
            continue
        ks = by_acc.get(acc, [])
        if len(ks) == 1:
            synonyms[n] = ks[0]
        elif len(ks) > 1:
            ambiguous.append(f"{n} -> {acc} = {' / '.join(ks)}")
    print(f"  {un_resolved}/{len(species_set)} UN keys have an ALA accepted species; "
          f"{len(synonyms)} F2F names map via accepted names, {len(ambiguous)} ambiguous (skipped)")
    for a in ambiguous:
        print("    ambiguous: " + a)
    for a in fuzzy_dropped:
        print("    fuzzy match onto a synonym, not used: " + a)
    return synonyms, res


# ------------------------------------------------------------------ main ---

def main():
    args = sys.argv[1:]
    fresh = "--fresh" in args
    sample = None
    if "--sample" in args:
        sample = int(args[args.index("--sample") + 1])
    t_start = time.time()
    CACHE.mkdir(parents=True, exist_ok=True)
    if fresh and (CACHE / "rest").exists():
        shutil.rmtree(CACHE / "rest")
        print("--fresh: dropped cached REST pages (HTML kept)")

    # 1. REST ---------------------------------------------------------------
    fields = "&_fields=id,slug,title,community,growth-form,plants-status,family-index"
    plants = rest_pages("plant", fields)
    terms = {t: {x["id"]: html.unescape(x["name"]) for x in rest_pages(t, "&_fields=id,name,slug,count")}
             for t in TAXONOMIES}
    media = rest_pages("media", "&_fields=id,post,media_details,source_url")
    print(f"REST: {len(plants)} plants, terms " + ", ".join(f"{k} {len(v)}" for k, v in terms.items())
          + f", {len(media)} media")
    assert len(plants) >= MIN_PLANTS, len(plants)
    assert len(media) >= 1900, len(media)
    assert len(terms["family-index"]) >= 120, len(terms["family-index"])
    ids = Counter(p["id"] for p in plants)
    assert max(ids.values()) == 1, "duplicate plant ids across pages (list shifted during the pull?)"
    print("  statuses: " + ", ".join(sorted(terms["plants-status"].values())))
    print("  communities: " + ", ".join(sorted(terms["community"].values())))
    print("  growth forms: " + ", ".join(sorted(terms["growth-form"].values())))

    # 2. HTML ----------------------------------------------------------------
    plants.sort(key=lambda p: html.unescape(p["title"]["rendered"]).lower())
    todo = plants if sample is None else plants[:: max(1, len(plants) // sample)][:sample]
    t0 = time.time()
    fetch_all_pages([p["slug"] for p in todo])
    if sample is not None:
        print(f"sample: {len(todo)} pages in {time.time() - t0:.1f} s")

    # 3. parse ----------------------------------------------------------------
    midx = media_index(media)
    pstats = Counter()
    out_plants, problems = [], []
    status_map = {}
    for tid, nm in terms["plants-status"].items():
        status_map[tid] = nm
    for p in todo:
        title = html.unescape(p["title"]["rendered"]).strip()
        page = parse_page(fetch_page(p["slug"]))
        if page["sci"] and " ".join(page["sci"].split()) != " ".join(title.split()):
            problems.append(f"{p['slug']}: page name {page['sci']!r} != REST title {title!r}")
        statuses = [status_map[t] for t in p.get("plants-status", []) if t in status_map]
        status = None
        for s in ("Endangered", "Vulnerable", "Rare"):
            if any(s.lower() in x.lower() for x in statuses):
                status = s
                break
        if statuses and status is None:
            pstats["status-other:" + "|".join(statuses)] += 1
        photos = [r for r in (resolve_photo(ph, midx, pstats) for ph in page["photos"]) if r]
        seen_paths = set()
        uniq = []
        for ph in photos:
            if ph["path"] in seen_paths:
                pstats["photo-dup-on-page"] += 1
                continue
            seen_paths.add(ph["path"])
            uniq.append(ph)
        fam = page["family"]
        if not fam:
            fams = [terms["family-index"][t] for t in p.get("family-index", []) if t in terms["family-index"]]
            if len(fams) == 1:
                fam = fams[0]
                pstats["family-from-rest"] += 1
        out_plants.append({
            "id": p["id"], "slug": p["slug"], "name": title, "species": species_key(title),
            "common": page["common"], "family": fam,
            "forms": sorted(terms["growth-form"][t] for t in p.get("growth-form", []) if t in terms["growth-form"]),
            "height": page["height"], **{f: clean_descriptor(f, page[f])
                                         for f in ("form", "flowers", "fruit", "habitat", "notes")},
            "status": status,
            "flowering": page["flowering"],
            "habitats": sorted(terms["community"][t] for t in p.get("community", []) if t in terms["community"]),
            "photos": uniq,
        })
        if not page["has_calendar"]:
            pstats["no-calendar"] += 1

    n = len(out_plants)

    def cnt(k):
        return sum(1 for x in out_plants if x[k])
    with_photo = cnt("photos")
    nphotos = sum(len(x["photos"]) for x in out_plants)
    print(f"parsed {n} pages: common {cnt('common')}, family {cnt('family')}, height {cnt('height')}, "
          f"form {cnt('form')}, flowers {cnt('flowers')}, fruit {cnt('fruit')}, habitat {cnt('habitat')}, "
          f"notes {cnt('notes')}, flowering {cnt('flowering')}, status {cnt('status')}, species key {cnt('species')}")
    print(f"  photos: {nphotos} on {with_photo} plants; "
          f"credit missing {sum(1 for x in out_plants for ph in x['photos'] if not ph['credit'])}; "
          + ", ".join(f"{k} {v}" for k, v in sorted(pstats.items())))
    print("  descriptors changed: " + ", ".join(f"{k} {v}" for k, v in sorted(descriptor_changes.items())))
    if dropped_photos:
        print(f"  dropped {len(dropped_photos)} page photos without a REST media record: " + ", ".join(dropped_photos))
    if external_photos:
        print("  skipped non-UN photos: " + ", ".join(f"{k} ×{v}" for k, v in external_photos.most_common()))
    if unknown_labels:
        print("  unknown labels: " + ", ".join(f"{k} ×{v}" for k, v in unknown_labels.most_common(20)))
    for pr in problems[:15]:
        print("  ! " + pr)
    if len(problems) > 15:
        print(f"  ! … {len(problems) - 15} more name mismatches")

    # 4. F2F (species keys from the REST titles: needs no HTML) -------------
    all_keys = [species_key(html.unescape(p["title"]["rendered"]).strip()) for p in plants]
    species_set = {k for k in all_keys if k}
    print(f"species keys: {len(species_set)} from {len(plants)} titles ({all_keys.count(None)} without one)")
    genera = {s.split()[0] for s in species_set}
    comms0, unmatched0, _, _, _, queue0, _ = f2f_lists(species_set, genera)
    synonyms, nm = ala_synonyms(list(unmatched0) + sorted(queue0), species_set)
    comms, unmatched, ucodes, variants, fstats, _, negated_only = f2f_lists(species_set, genera, synonyms)
    print("  synonym mappings applied (F2F name -> UN key [ALA accepted species, match type]):")
    for k, v in sorted(((k[4:], v) for k, v in fstats.items() if k.startswith("syn:")), key=lambda x: -x[1]):
        d = nm[k]
        print(f"    {v:4d}  {k} -> {synonyms[k]}  [{accepted_species(d)}, {d.get('matchType')}]")
    added = {(c, s) for c in comms for s in comms[c]} - {(c, s) for c in comms0 for s in comms0[c]}
    removed = {(c, s) for c in comms0 for s in comms0[c]} - {(c, s) for c in comms for s in comms[c]}
    print(f"  synonym pass: +{len(added)} / -{len(removed)} list entries across "
          f"{len({c for c, _ in added | removed})} codes; removed (abbreviation re-resolved): "
          + ", ".join(f"{c}:{s}" for c, s in sorted(removed)[:10]))
    print(f"  split groups narrowed by 'subsp. X': {fstats['split-by-subsp']} mentions")
    print(f"  named only as absent/contrast (dropped): {len(negated_only)} entries in "
          f"{len({c for c, _, _ in negated_only})} codes")
    for c, k, ctx in negated_only:
        print(f"    {c} {k}: …{' '.join(ctx.split())}")
    sizes = [len(v) for v in comms.values()]
    nonempty = [s for s in sizes if s]
    distinct = {s for v in comms.values() for s in v}
    print(f"F2F: {len(comms)} codes, {len(nonempty)} with species; median {statistics.median(nonempty):.0f} "
          f"(max {max(sizes)}), {len(distinct)} distinct species")
    print("  empty: " + " ".join(sorted(c for c, v in comms.items() if not v)))
    print(f"  abbreviations resolved by epithet: {fstats['abbrev-by-epithet']}; gender-agreement matches: "
          + ", ".join(f"{k} ×{v}" for k, v in variants.most_common()))
    for g in SPLITS:
        codes = sorted(c for c, v in comms.items() if g in v)
        print(f"  group {g!r}: {fstats['group:' + g]} mentions, in {len(codes)} codes: {' '.join(codes)}")
    photo_species = {x["species"] for x in out_plants if x["species"] and x["photos"]}
    photo_species |= {g for g, d in SPLITS.items() if set(d["species"]) & photo_species}
    mentions = [s for v in comms.values() for s in v]
    print(f"  {sum(1 for s in mentions if s in photo_species) / len(mentions):.0%} of listed entries have a UN photo"
          + (" (sample: photos known for parsed pages only)" if sample else ""))
    print(f"  still unmatched plant-like binomials: {len(unmatched)} distinct, {sum(unmatched.values())} mentions; "
          "top 15 [ALA accepted species]:")
    for k, v in unmatched.most_common(15):
        acc = accepted_species(nm[k]) if k in nm else None
        print(f"    {v:4d}  {k}  ({len(ucodes[k])} codes) [{acc or 'no species match'}]")
    if sample is not None:
        for x in out_plants[:2]:
            print(json.dumps(x, ensure_ascii=False)[:900])
        print("--sample: no output written")
        return

    # 5. checks + output ----------------------------------------------------
    assert n >= MIN_PLANTS, n
    assert with_photo >= MIN_WITH_PHOTO, with_photo
    assert len(nonempty) >= MIN_F2F_CODES, len(nonempty)
    assert cnt("common") >= MIN_COMMON, cnt("common")
    assert len({x["id"] for x in out_plants}) == n and len({x["slug"] for x in out_plants}) == n
    plant_keys = {x["species"] for x in out_plants if x["species"]}
    for g, d in SPLITS.items():
        assert g not in plant_keys, f"group {g} is now a UN species key — drop it from SPLITS"
        missing = [s for s in d["species"] if s not in plant_keys]
        assert not missing, f"group {g}: members without a UN plant: {missing}"
    stray = distinct - plant_keys - set(SPLITS)
    assert not stray, f"communities entries that are neither a plant species nor a group: {sorted(stray)[:10]}"
    exts = Counter(ph["ext"].lower() for x in out_plants for ph in x["photos"])
    print("  photo extensions: " + ", ".join(f"{k} {v}" for k, v in exts.most_common()))
    doc = {"version": 1, "built": datetime.date.today().isoformat(), "plants": out_plants,
           "groups": SPLITS,
           "communities": {k: v for k, v in sorted(comms.items()) if v}}  # codes without species omitted
    GEN.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".part")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, OUT)
    raw = OUT.read_bytes()
    print(f"wrote {os.path.relpath(OUT, HERE.parent)}:{len(raw) / 1e3:.0f} KB raw, "
          f"{len(gzip.compress(raw)) / 1e3:.0f} KB gzip; {time.time() - t_start:.0f} s total")


if __name__ == "__main__":
    main()
