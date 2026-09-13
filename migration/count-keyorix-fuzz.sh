#!/usr/bin/env bash
set -uo pipefail
cd /opt/keyorix-fuzz/keyorix || exit 1
echo "=== total unique Fuzz funcs in source ==="
grep -rhoE '^func Fuzz[A-Za-z0-9_]+' --include='*_test.go' . | sort -u | wc -l
echo "=== func|pkgdir ==="
grep -rnE '^func Fuzz[A-Za-z0-9_]+' --include='*_test.go' . \
  | sed -E 's#^\./([^:]*)/[^/:]+:[0-9]+:func (Fuzz[A-Za-z0-9_]+).*#\2|\1#' \
  | sort -u
