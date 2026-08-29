#!/usr/bin/env python3
"""Build f2f_index.json: VEGCODE -> {chapter file, PDF page index}.

Downloads the From Forest to Fjaeldmark chapter PDFs from nre.tas.gov.au
into pipeline/cache/f2f/ (gitignored — the PDFs are copyright, all rights
reserved, and must never be committed or re-hosted; see docs/LICENSING.md).
The emitted index contains only facts (file names + page numbers) and IS
committable.

Section headings in the PDFs look like:  "Eucalyptus amygdalina coastal
forest and woodland (DAC)" as the first line of the section's page, so we
scan each page's first lines for "(CODE)".

Run:  uv run --with pypdf python3 pipeline/build_f2f_index.py
"""
import json
import re
import urllib.request
from pathlib import Path

from pypdf import PdfReader

HERE = Path(__file__).parent
CACHE = HERE / "cache" / "f2f"
OUT = HERE.parent / "app" / "src" / "generated" / "f2f_index.json"
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


def heading_pages(pdf: Path) -> dict:
    """Return {code: first page index whose leading lines end with (CODE)}."""
    found = {}
    for i, page in enumerate(PdfReader(pdf).pages):
        text = page.extract_text() or ""
        for line in text.splitlines()[:8]:
            m = re.search(r"\(([A-Z]{3})\)\s*$", line.strip())
            # skip table-of-contents pages: heading lines there end with a
            # page number after the code, so the $ anchor already excludes them
            if m and m.group(1) not in found:
                found[m.group(1)] = i
    return found


def main():
    communities = json.loads(
        (HERE.parent / "app" / "src" / "generated" / "tasveg_communities.json").read_text())

    chapter_pages = {}
    for chapter in sorted(set(GROUP_CHAPTER.values())):
        chapter_pages[chapter] = heading_pages(download(chapter))

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
        {"baseUrl": BASE_URL, "index": dict(sorted(index.items()))}, indent=1))
    print(f"{len(index)} codes indexed, {len(missing)} without a page anchor")
    for code, why in missing:
        print(f"  {code}: {why} (falls back to chapter start)")


if __name__ == "__main__":
    main()
