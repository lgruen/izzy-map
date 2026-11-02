#!/usr/bin/env bash
# Plant-ID evaluation, step 0: the iNaturalist Open Dataset metadata tables
# (monthly snapshot, public S3 bucket, no AWS account needed).
# ~35 GB in total (photos 21 GB, observations 13.7 GB, taxa 40 MB as of
# 2026-10-27); ~35 min at the ~18 MB/s measured from here with aws-cli's
# parallel ranged GETs. Re-running skips files whose size already matches.
set -euo pipefail
# AWS: the aws-cli command; the cloud runner passes "uvx --from awscli aws".
AWS=${AWS:-aws}
dir="$(cd "$(dirname "$0")/.." && pwd)/cache/plantid/meta"
mkdir -p "$dir"
for f in taxa observations photos; do
  want=$($AWS s3api head-object --no-sign-request --bucket inaturalist-open-data \
           --key "$f.csv.gz" --query ContentLength --output text)
  have=$(wc -c < "$dir/$f.csv.gz" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "$want" = "$have" ]; then echo "$f.csv.gz: up to date"; continue; fi
  echo "$f.csv.gz: $((want / 1000000)) MB"
  $AWS s3 cp --no-sign-request --only-show-errors \
    "s3://inaturalist-open-data/$f.csv.gz" "$dir/$f.csv.gz"
done
ls -l "$dir"
