#!/bin/bash
# Build data/tasveg.pmtiles (statewide TASVEG 5.0 vector tiles) from the
# LISTdata statewide zip, plus the community colour/name table.
#
# Usage:
#   pipeline/build_tasveg.sh [--test]     # --test: clip to Hobart area only
#
# The source zip is downloaded to pipeline/cache/ if not already present
# (also checks ~/Downloads for a manually downloaded copy).
#
# TASVEG 6.0 someday: bump ZIP_NAME/URL below, run, check the report at the
# end (feature count, community count), and re-upload data/tasveg.pmtiles.
set -euo pipefail
cd "$(dirname "$0")"

ZIP_NAME=LIST_TASVEG_50_STATEWIDE.zip
ZIP_URL="https://listdata.thelist.tas.gov.au/opendata/data/$ZIP_NAME"
SHP_IN_ZIP="LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.shp"
QML_IN_ZIP="LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.qml"
EXPECTED_FEATURES=482138
MAXZOOM=14

mkdir -p cache work ../data
TEST_CLIP=()
OUT_BASE=tasveg
if [[ "${1:-}" == "--test" ]]; then
  # Hobart / kunanyi area in EPSG:4326 (clip applied after reprojection)
  TEST_CLIP=(-clipdst 147.1 -43.0 147.5 -42.8)
  OUT_BASE=tasveg_test
fi

ZIP=cache/$ZIP_NAME
if [[ ! -f "$ZIP" ]]; then
  if [[ -f "$HOME/Downloads/$ZIP_NAME" ]]; then
    echo "using existing $HOME/Downloads/$ZIP_NAME"
    ln -s "$HOME/Downloads/$ZIP_NAME" "$ZIP"
  else
    echo "downloading $ZIP_URL (~1.8 GB)"
    curl -fL --retry 3 -o "$ZIP.part" "$ZIP_URL" && mv "$ZIP.part" "$ZIP"
  fi
fi

echo "== extracting style + building community table =="
unzip -o -j -q "$ZIP" "$QML_IN_ZIP" -d work/
ogr2ogr -f CSV work/communities.csv \
  "/vsizip/$ZIP/$SHP_IN_ZIP" \
  -dialect SQLite \
  -sql "SELECT DISTINCT VEGCODE, VEGCODE_D, VEG_GROUP FROM TASVEG_5_0 ORDER BY VEGCODE"
python3 build_style.py

echo "== feature count check =="
COUNT=$(ogrinfo -ro -so "/vsizip/$ZIP/$SHP_IN_ZIP" TASVEG_5_0 | awk '/Feature Count/ {print $3}')
echo "source features: $COUNT (expected $EXPECTED_FEATURES)"
if [[ "$COUNT" != "$EXPECTED_FEATURES" && "$OUT_BASE" == "tasveg" ]]; then
  echo "WARNING: feature count changed — new TASVEG release? Continuing."
fi

echo "== reproject + tile (streaming shapefile -> tippecanoe) =="
# Attributes kept lean: everything the details sheet shows, nothing more.
time ogr2ogr -f GeoJSONSeq /vsistdout/ \
  "/vsizip/$ZIP/$SHP_IN_ZIP" \
  -t_srs EPSG:4326 \
  -select VEGCODE,VEGCODE_D,VEG_GROUP,FOREST_STR,NOTABLE_TD,WEED_TYP_D \
  "${TEST_CLIP[@]+"${TEST_CLIP[@]}"}" \
  -nlt PROMOTE_TO_MULTI \
  | tippecanoe \
      -o "work/$OUT_BASE.mbtiles" --force \
      -l tasveg -n "TASVEG 5.0" \
      -A "TASVEG 5.0 from theLIST (CC BY 3.0 AU) © State of Tasmania" \
      -Z0 -z$MAXZOOM \
      --coalesce-densest-as-needed \
      --detect-shared-borders \
      --hilbert

echo "== convert to PMTiles =="
pmtiles convert "work/$OUT_BASE.mbtiles" "../data/$OUT_BASE.pmtiles"
ls -la "../data/$OUT_BASE.pmtiles"
pmtiles show "../data/$OUT_BASE.pmtiles" | head -25
