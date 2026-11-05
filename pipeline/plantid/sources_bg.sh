#!/bin/sh
# Background Commons pull for ALL labels at the Wikimedia robot-policy rate
# (notes/photo_sources.md). Resumable: every stage caches per file/batch, so
# after a stop or reboot just run this script again:
#   nohup pipeline/plantid/sources_bg.sh > pipeline/cache/plantid/sources/commons_bg.log 2>&1 &
# 1. commons-list: Wikidata/category/imageinfo caches → candidates (licence
#    filter, iNat mirrors and specimens out)
# 2. commons-fetch: most-needed labels first, the 1,000-per-label total
#    (room minus ALA), ≤ 2 workers (1 while a listing runs)
# 3. a dedup snapshot (sources/extra_photos_sources.parquet) after every
#    25,000 newly fetched Commons photos, and once at the end.
cd "$(dirname "$0")/../.." || exit 1
R="uv run --with pillow --with imagehash --with numpy --with pyarrow --with pandas python3 -I pipeline/plantid/sources_pull.py"
S=pipeline/cache/plantid/sources
while pgrep -f "sources_pull.py commons-list" > /dev/null || pgrep -f "sources_pull.py commons-fetch" > /dev/null; do
  sleep 60
done
$R commons-list || exit 1
$R commons-fetch &
F=$!
last=$(ls $S/photos/commons | wc -l)
while kill -0 $F 2> /dev/null; do
  sleep 600
  n=$(ls $S/photos/commons | wc -l)
  if [ $((n - last)) -ge 25000 ]; then
    echo "$(date '+%H:%M:%S') snapshot at $n Commons photos"
    $R dedup > $S/dedup_snapshot.log 2>&1 && last=$n
  fi
done
wait $F
$R dedup > $S/dedup_snapshot.log 2>&1
echo "$(date '+%H:%M:%S') commons background pull finished"
