#!/usr/bin/env bash
# Packages src/icspackage into an OIC integration archive (.iar is a JAR/zip).
set -euo pipefail
cd "$(dirname "$0")/src"
OUT=../SUPPLIER_ONBOARDING_01.00.0000.iar
rm -f "$OUT"
zip -X -r -q "$OUT" icspackage
echo "Built $(cd .. && pwd)/SUPPLIER_ONBOARDING_01.00.0000.iar"
