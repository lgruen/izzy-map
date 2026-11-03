#!/usr/bin/env python3
"""Build ios/IzzyMap/Resources/Data/acknowledgements.json — the licence texts
of the third-party components the native app distributes, shown verbatim on
its Acknowledgements screen (Map Credits ▸ Acknowledgements; Identify ▸ Model
& training photos ▸ Acknowledgements).

    python3 pipeline/build_acknowledgements.py [--fresh]

Stdlib only. Every text is read from the real upstream file at a PINNED ref
(cached in pipeline/cache/acknowledgements/, `--fresh` re-fetches), never
retyped, so the screen can't drift from what the licences say:

- MapLibre Native: the version is read from ios/project.yml (`exactVersion`,
  cross-checked against Package.resolved when xcodegen has run). LICENSE.md
  of maplibre-gl-native-distribution at that tag (the file the binary
  package ships) + platform/ios/LICENSE.md of maplibre-native at
  ios-v<version> (the third-party components compiled into the framework:
  Boost, earcut, protozero, RapidJSON, HarfBuzz, FreeType, …).
- BioCLIP 2.5 Huge (the plant-ID image encoder in the `plantid` pack): the
  Hugging Face model card at the revision the pack was converted from
  (asserted "License: MIT"; its BibTeX entries, which the card asks users to
  cite) and the MIT notice of the BioCLIP 2 repository at v2.0.0, which the
  card names as the training code (the model repo has no LICENSE file of its
  own). The LAION CLIP ViT-H/14 base weights' card is asserted MIT too.
- Noto Sans (map label glyph PBFs, Latin-1): the bundled PBFs are checked
  byte-for-byte against maplibre/demotiles' `font/` (which says they were
  generated from openmaptiles/fonts); the OFL 1.1 text is openmaptiles/fonts'
  noto-sans/LICENSE and the copyright line is read from the source TTFs'
  `name` table (nameID 0). demotiles' own BSD 3-Clause notice is included.

Anything else that ships is our own (code, icon) or data credited in the app
(Attribution.swift, the plant-ID training-photo credits) — summarised in the
JSON's `data` list. Add a component here when a dependency is added
(project.yml packages, bundled fonts, pack contents).
"""
import argparse
import hashlib
import json
import re
import struct
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "IzzyMap" / "Resources" / "Data" / "acknowledgements.json"
CACHE = ROOT / "pipeline" / "cache" / "acknowledgements"
PROJECT = ROOT / "ios" / "project.yml"
RESOLVED = ROOT / "ios" / "IzzyMap.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"
GLYPHS = ROOT / "ios" / "IzzyMap" / "Resources" / "glyphs"

# pinned upstream refs (bump deliberately; the build re-verifies everything)
BIOCLIP_HF = "imageomics/bioclip-2.5-vith14"
BIOCLIP_REV = "6e3d04e3d6522012c88181085c5ae666e14c45cd"   # = the local HF snapshot build_ship.py converted
BIOCLIP_CODE = ("Imageomics/bioclip-2", "v2.0.0")
LAION_HF = "laion/CLIP-ViT-H-14-laion2B-s32B-b79K"
LAION_REV = "1c2b8495b28150b8a4922ee1c8edee224c284c0c"
DEMOTILES = ("maplibre/demotiles", "601ae60796ceceda2cbd2ed3d2ea92d17a84be4b")
OMT_FONTS = ("openmaptiles/fonts", "d48c5fce2fc58b55c98d353558d807cac45e7262")
FONTSTACKS = {"Noto Sans Regular": "NotoSans-Regular.ttf", "Noto Sans Bold": "NotoSans-Bold.ttf"}

fetched: dict[str, str] = {}   # url → sha256, recorded in the output


def fetch(url: str, fresh: bool) -> bytes:
    CACHE.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:16]
    path = CACHE / f"{key}-{url.rsplit('/', 1)[-1].replace('%20', '_')}"
    if fresh or not path.exists():
        req = urllib.request.Request(url, headers={"User-Agent": "izzy-map build_acknowledgements"})
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
        path.write_bytes(body)
    body = path.read_bytes()
    fetched[url] = hashlib.sha256(body).hexdigest()
    return body


def github(repo_ref: tuple[str, str], path: str, fresh: bool) -> bytes:
    repo, ref = repo_ref
    quoted = "/".join(urllib.request.quote(p) for p in path.split("/"))
    return fetch(f"https://raw.githubusercontent.com/{repo}/{ref}/{quoted}", fresh)


def text(b: bytes) -> str:
    return b.decode("utf-8").replace("\r\n", "\n").strip("\n")


def maplibre_version() -> str:
    m = re.search(r"maplibre-gl-native-distribution\s*\n\s*exactVersion:\s*(\S+)", PROJECT.read_text())
    if not m:
        sys.exit("project.yml: no exactVersion for maplibre-gl-native-distribution")
    version = m.group(1).strip('"')
    if RESOLVED.exists():
        pins = json.loads(RESOLVED.read_text())["pins"]
        pin = next((p for p in pins if p["identity"] == "maplibre-gl-native-distribution"), None)
        if pin and pin["state"].get("version") != version:
            sys.exit(f"Package.resolved pins MapLibre {pin['state'].get('version')}, project.yml {version}: "
                     "run xcodegen generate + resolve first")
    return version


def ttf_copyright(data: bytes) -> str:
    """nameID 0 (Windows, English) from a TrueType font's `name` table."""
    num_tables = struct.unpack(">H", data[4:6])[0]
    for i in range(num_tables):
        tag, _, offset, _ = struct.unpack(">4sIII", data[12 + 16 * i: 28 + 16 * i])
        if tag != b"name":
            continue
        _, count, strings = struct.unpack(">HHH", data[offset: offset + 6])
        for j in range(count):
            pid, eid, lang, nid, length, off = struct.unpack(
                ">HHHHHH", data[offset + 6 + 12 * j: offset + 18 + 12 * j])
            if pid == 3 and lang == 0x409 and nid == 0:
                start = offset + strings + off
                return data[start: start + length].decode("utf-16-be").strip()
    sys.exit("font has no copyright string (name table nameID 0)")


def bibtex(card: str, key: str) -> str:
    m = re.search(r"```\s*\n(@\w+\{" + re.escape(key) + r",.*?)\n```", card, re.S)
    if not m:
        sys.exit(f"model card: BibTeX entry {key} not found (card changed? re-read it)")
    return m.group(1).strip()


def build(fresh: bool) -> dict:
    components = []

    # ---- MapLibre Native
    v = maplibre_version()
    dist = text(github(("maplibre/maplibre-gl-native-distribution", v), "LICENSE.md", fresh))
    ios = text(github(("maplibre/maplibre-native", f"ios-v{v}"), "platform/ios/LICENSE.md", fresh))
    assert dist.startswith("BSD 2-Clause License") and "MapLibre contributors" in dist, "MapLibre LICENSE.md changed"
    assert "Boost" in ios and "Redistributions in binary form" in ios, "MapLibre iOS LICENSE.md changed"
    components.append({
        "id": "maplibre",
        "name": "MapLibre Native",
        "version": v,
        "role": "Draws the map.",
        "licence": "BSD 2-Clause",
        "url": "https://github.com/maplibre/maplibre-native",
        "notes": [],
        "texts": [
            {"title": f"LICENSE.md (maplibre-gl-native-distribution {v})", "body": dist},
            {"title": f"MapLibre Native iOS and the components built into it (platform/ios/LICENSE.md, ios-v{v})",
             "body": ios},
        ],
        "citations": [],
    })

    # ---- BioCLIP 2.5 Huge
    card = text(fetch(f"https://huggingface.co/{BIOCLIP_HF}/raw/{BIOCLIP_REV}/README.md", fresh))
    if not re.search(r"^license:\s*\n-\s*mit\s*$", card, re.M | re.I) or "**License:** MIT" not in card:
        sys.exit("BioCLIP 2.5 model card no longer says MIT — re-read the licence before shipping")
    mit = text(github(BIOCLIP_CODE, "LICENSE", fresh))
    assert mit.startswith("Copyright (c)") and "Permission is hereby granted, free of charge" in mit, "BioCLIP 2 LICENSE changed"
    laion = text(fetch(f"https://huggingface.co/{LAION_HF}/raw/{LAION_REV}/README.md", fresh))
    if not re.search(r"^license:\s*mit\s*$", laion, re.M | re.I):
        sys.exit("LAION CLIP ViT-H/14 model card no longer says MIT")
    developed = re.search(r"\*\*Developed by:\*\*\s*(.+)", card)
    components.append({
        "id": "bioclip",
        "name": "BioCLIP 2.5 Huge",
        "version": f"Hugging Face {BIOCLIP_HF} @ {BIOCLIP_REV[:7]}",
        "role": "The plant-ID image model (in the plant identification download), converted to Core ML with 8-bit weights; IzzyMap’s Tasmanian classifier is trained on its output.",
        "licence": "MIT",
        "url": f"https://huggingface.co/{BIOCLIP_HF}",
        "notes": [
            f"Developed by {developed.group(1).strip()} (Imageomics Institute)." if developed
            else "Imageomics Institute.",
            "The model card gives the licence as MIT; the notice below is the one in the BioCLIP 2 repository "
            f"({BIOCLIP_CODE[0]} {BIOCLIP_CODE[1]}), which the card names as the training code.",
            f"Fine-tuned from CLIP ViT-H/14 pre-trained on LAION-2B ({LAION_HF}, MIT), trained with OpenCLIP.",
        ],
        "texts": [{"title": f"LICENSE ({BIOCLIP_CODE[0]} {BIOCLIP_CODE[1]})", "body": mit}],
        "citations": [
            {"title": "BioCLIP 2.5 Huge (model)", "text": bibtex(card, "Gu_BioCLIP_2.5_Huge_model")},
            {"title": "BioCLIP 2: Emergent Properties from Scaling Hierarchical Contrastive Learning (NeurIPS 2025)",
             "text": bibtex(card, "NEURIPS2025_94da80cb")},
        ],
    })

    # ---- Noto Sans glyphs
    glyph_sha = {}
    for stack in FONTSTACKS:
        local = (GLYPHS / stack / "0-255.pbf").read_bytes()
        upstream = github(DEMOTILES, f"font/{stack}/0-255.pbf", fresh)
        if local != upstream:
            sys.exit(f"glyphs/{stack}/0-255.pbf differs from {DEMOTILES[0]} font/ — re-identify where the "
                     "glyphs came from and which font licence applies before updating this script")
        glyph_sha[f"{stack}/0-255.pbf"] = hashlib.sha256(local).hexdigest()
    extra = sorted(p.relative_to(GLYPHS).as_posix() for p in GLYPHS.rglob("*.pbf"))
    if extra != sorted(glyph_sha):
        sys.exit(f"unexpected glyph files {extra}: add their font to FONTSTACKS")
    ofl = text(github(OMT_FONTS, "noto-sans/LICENSE", fresh))
    assert "SIL OPEN FONT LICENSE Version 1.1" in ofl, "openmaptiles noto-sans/LICENSE is no longer OFL 1.1"
    rights = sorted({ttf_copyright(github(OMT_FONTS, f"noto-sans/{ttf}", fresh)) for ttf in FONTSTACKS.values()})
    demo = text(github(DEMOTILES, "LICENSE", fresh))
    assert demo.startswith("BSD 3-Clause License"), "demotiles LICENSE changed"
    components.append({
        "id": "noto-sans",
        "name": "Noto Sans",
        "version": "Regular and Bold, Latin-1",
        "role": "The typeface of the map’s labels (TASVEG codes, tree names), as signed-distance-field glyphs.",
        "licence": "SIL Open Font License 1.1",
        "url": "https://notofonts.github.io",
        "notes": [
            f"Glyph files from {DEMOTILES[0]} (font/), generated with {OMT_FONTS[0]} from its Noto Sans fonts.",
        ],
        "texts": [
            {"title": "Copyright", "body": "\n".join(rights)},
            {"title": f"Licence (noto-sans/LICENSE, {OMT_FONTS[0]})", "body": ofl},
            {"title": f"LICENSE ({DEMOTILES[0]})", "body": demo},
        ],
        "citations": [],
    })

    data = [
        "Map data: theLIST © State of Tasmania (CC BY 3.0 AU; aerial photos and Tasmap CC BY-NC-ND 3.0 AU), "
        "Mineral Resources Tasmania © State of Tasmania (CC BY 3.0 AU), NVIS V7.0 © Commonwealth of Australia, "
        "DCCEEW (CC BY 4.0), significant trees: City of Hobart (CC BY 4.0) — the (i) Map Credits list what is on screen.",
        "Place and street names, street addresses from theLIST © State of Tasmania (CC BY 3.0 AU).",
        "Plant profiles & photos: Understorey Network Tasmania (photos © their photographers).",
        "Occurrence records: Atlas of Living Australia (incl. Tasmanian Natural Values Atlas, iNaturalist Australia, "
        "Australasian Virtual Herbarium) — counts only.",
        "Plant ID training photos: iNaturalist Open Dataset, each © its observer (CC0, CC BY or CC BY-NC) — "
        "every observer is listed under Identify ▸ Model & training photos.",
    ]
    return {"version": 1, "components": components, "data": data, "glyphs": glyph_sha,
            "sources": dict(sorted(fetched.items()))}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fresh", action="store_true", help="re-fetch every upstream file")
    args = ap.parse_args()
    doc = build(args.fresh)
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    for c in doc["components"]:
        size = sum(len(t["body"]) for t in c["texts"])
        print(f"  {c['name']} {c['version']} — {c['licence']}, {len(c['texts'])} texts ({size:,} chars), "
              f"{len(c['citations'])} citations")
    print(f"→ {OUT.relative_to(ROOT)} ({OUT.stat().st_size:,} bytes, {len(doc['sources'])} upstream files)")


if __name__ == "__main__":
    main()
