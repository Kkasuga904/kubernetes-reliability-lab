#!/usr/bin/env bash
# Delete the kind cluster (nothing else to clean: no cloud resources).
set -euo pipefail
kind delete cluster --name reliability-lab
