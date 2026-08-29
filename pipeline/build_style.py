#!/usr/bin/env python3
"""Build the canonical TASVEG community table from official sources.

Inputs (in pipeline/work/, extracted by build_tasveg.sh):
  - TASVEG_5_0.qml        official QGIS symbology (categorized on VEGCODE,
                          all solid fills — the authoritative colour source;
                          the ArcGIS renderer JSON is wrong for the 67
                          hatch-patterned communities)
  - communities.csv       DISTINCT VEGCODE, VEGCODE_D, VEG_GROUP from the data

Output:
  - app/src/generated/tasveg_communities.json
      { "<VEGCODE>": {"name": ..., "group": ..., "color": "#rrggbb",
                      "outline": "#rrggbb", "label": "(CODE) name"} }

Stdlib only.
"""
import csv
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

WORK = Path(__file__).parent / "work"
OUT = Path(__file__).parent.parent / "app" / "src" / "generated"

# Codes present in the data but missing from the shipped QML (which instead
# carries stale codes — e.g. QML has DWF, data has DFP). Colours taken from
# the official ArcGIS renderer (layer 9), verified solid fills there.
OVERRIDES = {
    "DFP": {"color": "#cbfe98", "outline": "#686868",
            "label": "(DFP) Furneaux peppermint forest"},
}


def parse_qml_colors(qml_path: Path):
    """Return {vegcode: {"color": "#...", "outline": "#...", "label": ...}}."""
    tree = ET.parse(qml_path)
    root = tree.getroot()
    renderer = root.find(".//renderer-v2")
    assert renderer is not None and renderer.get("attr") == "VEGCODE", (
        "QML renderer changed — expected categorizedSymbol on VEGCODE"
    )

    # symbol name -> (fill, outline)
    symbols = {}
    for sym in renderer.findall("./symbols/symbol"):
        name = sym.get("name")
        fill = outline = None
        for layer in sym.findall("./layer"):
            if layer.get("class") != "SimpleFill":
                continue
            for opt in layer.iter("Option"):
                if opt.get("name") == "color":
                    fill = rgba_to_hex(opt.get("value"))
                elif opt.get("name") == "outline_color":
                    outline = rgba_to_hex(opt.get("value"))
        symbols[name] = (fill, outline)

    result = {}
    for cat in renderer.findall("./categories/category"):
        code = cat.get("value")
        fill, outline = symbols.get(cat.get("symbol"), (None, None))
        if not code:
            continue  # empty catch-all category, if any
        result[code] = {
            "color": fill,
            "outline": outline or "#686868",
            "label": cat.get("label"),
        }
    return result


def rgba_to_hex(value: str):
    """QGIS colour strings look like '229,182,54,255,rgb:0.89,0.71,...'."""
    if not value:
        return None
    m = re.match(r"^(\d+),(\d+),(\d+),(\d+)", value)
    if not m:
        return None
    r, g, b, _a = (int(x) for x in m.groups())
    return f"#{r:02x}{g:02x}{b:02x}"


def main():
    colors = parse_qml_colors(WORK / "TASVEG_5_0.qml")
    colors.update(OVERRIDES)

    communities = {}
    with open(WORK / "communities.csv", newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            code = row["VEGCODE"].strip()
            if not code:
                continue
            communities[code] = {
                "name": row["VEGCODE_D"].strip(),
                "group": row["VEG_GROUP"].strip(),
            }

    # a code counts as missing if absent from the QML OR parsed without a
    # fill (guards against QML format drift silently greying everything)
    missing_color = sorted(
        c for c in communities
        if c not in colors or not colors[c].get("color")
    )
    unused_color = sorted(set(colors) - set(communities))
    for code, meta in communities.items():
        c = colors.get(code)
        meta["color"] = (c or {}).get("color") or "#c8c8c8"
        meta["outline"] = (c or {}).get("outline") or "#686868"
        meta["label"] = (c or {}).get("label") or f"({code}) {meta['name']}"

    OUT.mkdir(parents=True, exist_ok=True)
    out_path = OUT / "tasveg_communities.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(communities.items())), f, indent=1, ensure_ascii=False)

    print(f"{len(communities)} communities in data, {len(colors)} styled in QML")
    if missing_color:
        print(f"WARNING: no QML colour for: {missing_color} (grey fallback used)")
    if unused_color:
        print(f"note: QML styles with no data features: {unused_color}")
    print(f"wrote {out_path}")
    return 1 if missing_color else 0


if __name__ == "__main__":
    sys.exit(main())
