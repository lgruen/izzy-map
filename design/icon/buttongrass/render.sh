#!/bin/bash
# render.sh <pkg.icon> <outdir> [size] [renditions...]
set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
pkg=$1; out=$2; size=${3:-1024}; shift 3 || true
rs=${@:-Default}
mkdir -p "$out"
for r in $rs; do
  "$IC" "$pkg" --export-image --output-file "$out/$r.png" --platform iOS --rendition $r \
     --width $size --height $size --scale 1 >/dev/null
done
