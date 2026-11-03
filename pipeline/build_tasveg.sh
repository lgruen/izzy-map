#!/bin/bash
# Build data/tasveg_v2.pmtiles (statewide TASVEG 5.0 vector tiles: mode-raster
# bands z0–10, source polygons z11–14 with stable ids, label points z13–14)
# plus ios/IzzyMap/Resources/Data/tasveg_communities.json. The recipe and its
# tripwires live in build_tasveg.py; this wrapper fetches the zip and supplies
# the uv environment (no brew GDAL needed; tippecanoe/tile-join/pmtiles from brew).
#
# Usage:
#   pipeline/build_tasveg.sh                 # statewide, ~13 min on the M-series Mac
#   pipeline/build_tasveg.sh --clip 8/232/160  # one z8 tile (densest NW), ~2 min
#
# After a statewide run passes its tripwires, swap it in by hand:
#   mv data/tasveg.pmtiles data/tasveg_v1.pmtiles; mv data/tasveg_v2.pmtiles data/tasveg.pmtiles
#
# TASVEG 6.0 someday: bump ZIP_NAME/URL here and in build_tasveg.py
# (ZIP, SHP_IN_ZIP, EXPECTED_FEATURES, OLD_BOUNDS), run, read the report.
set -euo pipefail
cd "$(dirname "$0")"

ZIP_NAME=LIST_TASVEG_50_STATEWIDE.zip
ZIP_URL="https://listdata.thelist.tas.gov.au/opendata/data/$ZIP_NAME"

mkdir -p cache work ../data
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

exec uv run --with rasterio --with pyogrio --with shapely --with pyproj \
  --with numpy --with geopandas --with pyarrow --with mapbox-vector-tile \
  python3 build_tasveg.py "$@"
