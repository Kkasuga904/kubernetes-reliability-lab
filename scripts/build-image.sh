#!/usr/bin/env bash
# Build the demo app image (local tag; kind loads it via load-image.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t reliability-lab:dev .
