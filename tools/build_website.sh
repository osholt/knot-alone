#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$repository_dir/build/website"

mkdir -p "$output_dir"
rsync -a --delete \
  --exclude '.dockerignore' \
  --exclude 'Caddyfile' \
  --exclude 'Dockerfile' \
  --exclude 'README.md' \
  --exclude '*.test.mjs' \
  "$repository_dir/apps/website/" "$output_dir/"
