#!/usr/bin/env bash
# Load the local image into the kind cluster (no registry needed).
set -euo pipefail
cd "$(dirname "$0")/.."
kind load docker-image reliability-lab:dev --name reliability-lab
