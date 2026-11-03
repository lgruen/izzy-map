#!/usr/bin/env python3
"""Build f2f_index.json: VEGCODE -> {chapter file, 0-based PDF page index},
plus each chapter's byte size ("sizes": file -> bytes; the app's download
status and space preflight).

Downloads the From Forest to Fjaeldmark chapter PDFs from nre.tas.gov.au
into pipeline/cache/f2f/ (gitignored — the PDFs are copyright, all rights
reserved, and must never be committed or re-hosted; see docs/LICENSING.md).
The emitted index contains only facts (file names, page numbers, byte
sizes) and IS committable. Sizes are the cached PDFs' sizes, checked
against nre.tas.gov.au's Content-Length (HEAD) so a stale cache can't ship a
wrong size; a mismatch aborts (delete the cached file and re-run). The file
has no version field and the app decodes `sizes` as optional: additive.

Section headings in the PDFs look like:  "Eucalyptus amygdalina coastal
forest and woodland (DAC)" as the first line of the section's page, so we
scan each page's first lines for "(CODE)".

Run:  uv run --with pypdf --with truststore python3 pipeline/build_f2f_index.py
(truststore: verify TLS against the macOS keychain — uv's Python has no CA
store of its own; optional, the script runs without it where certs work.)
"""
import json
import re
import urllib.request
from pathlib import Path

from pypdf import PdfReader

try:
    import truststore
    truststore.inject_into_ssl()
except ImportError:
    pass

HERE = Path(__file__).parent
CACHE = HERE / "cache" / "f2f"
GEN = HERE.parent / "ios" / "IzzyMap" / "Resources" / "Data"
OUT = GEN / "f2f_index.json"
BASE_URL = "https://nre.tas.gov.au/Documents/"

GROUP_CHAPTER = {
    "Dry eucalypt forest and woodland": "f2f_dry_eucalypt.pdf",
    "Wet eucalypt forest and woodland": "f2f_wet_eucalypt.pdf",
    "Non eucalypt forest and woodland": "f2f_non-eucalypt.pdf",
    "Rainforest and related scrub": "f2f_rainforest.pdf",
    "Scrub, heathland and coastal complexes": "f2f_scrub.pdf",
    "Moorland, sedgeland and rushland": "f2f_moorland_sedgeland.pdf",
    "Native grassland": "f2f_native_grassland.pdf",
    "Highland treeless vegetation": "f2f_highland_treeless.pdf",
    "Saltmarsh and wetland": "f2f_saltmarsh.pdf",
    "Other natural environments": "f2f_other_natural.pdf",
    "Modified land": "f2f_modified_land.pdf",
}


def download(name: str) -> Path:
    p = CACHE / name
    if not p.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print(f"downloading {name}")
        req = urllib.request.Request(
            BASE_URL + name, headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
        with urllib.request.urlopen(req, timeout=120) as r:
            p.write_bytes(r.read())
    return p


def head_size(name: str) -> int | None:
    """Content-Length from a HEAD request, None if the server gives none."""
    req = urllib.request.Request(
        BASE_URL + name, method="HEAD",
        headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        length = r.headers.get("Content-Length")
    return int(length) if length else None


def chapter_size(path: Path) -> int:
    size = path.stat().st_size
    remote = head_size(path.name)
    if remote is not None and remote != size:
        raise SystemExit(f"{path.name}: cached {size} bytes, nre.tas.gov.au says {remote} "
                         f"— delete {path} and re-run")
    return size


def heading_pages(pdf: Path) -> dict:
    """Return {code: page index of the community's section-start page}.

    A section-start page has a leading line ending with "(CODE)" AND contains
    the "General description" heading. The containment check matters: chapter
    intro pages can have wrapped body lines ending with a code (verified
    false positives: GHC, NBA), so first-match-wins is not safe.
    """
    candidates: dict[str, list[int]] = {}
    has_general: dict[int, bool] = {}
    for i, page in enumerate(PdfReader(pdf).pages):
        text = page.extract_text() or ""
        has_general[i] = "General description" in text
        for line in text.splitlines()[:8]:
            m = re.search(r"\(([A-Z]{3})\)\s*$", line.strip())
            # table-of-contents lines end with a page number after the code,
            # so the $ anchor already excludes them
            if m:
                candidates.setdefault(m.group(1), []).append(i)
    found = {}
    for code, pages in candidates.items():
        real = [i for i in pages if has_general[i]]
        found[code] = (real or pages)[0]
    return found


def main():
    communities = json.loads(
        (GEN / "tasveg_communities.json").read_text())

    chapter_pages, sizes = {}, {}
    for chapter in sorted(set(GROUP_CHAPTER.values())):
        pdf = download(chapter)
        chapter_pages[chapter] = heading_pages(pdf)
        sizes[chapter] = chapter_size(pdf)

    index, missing = {}, []
    for code, meta in communities.items():
        chapter = GROUP_CHAPTER.get(meta["group"])
        if chapter is None:
            missing.append((code, "unknown group: " + meta["group"]))
            continue
        page = chapter_pages[chapter].get(code)
        if page is None:
            missing.append((code, f"no heading in {chapter}"))
            index[code] = {"file": chapter, "page": 0}
        else:
            index[code] = {"file": chapter, "page": page}

    OUT.write_text(json.dumps(
        {"baseUrl": BASE_URL, "index": dict(sorted(index.items())),
         "sizes": dict(sorted(sizes.items()))}, indent=1))
    print(f"{len(index)} codes indexed, {len(missing)} without a page anchor; "
          f"{len(sizes)} chapters, {sum(sizes.values()) / 1e6:.1f} MB")
    for code, why in missing:
        print(f"  {code}: {why} (falls back to chapter start)")


if __name__ == "__main__":
    main()
