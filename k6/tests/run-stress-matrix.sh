#!/usr/bin/env bash
# Run stress tests across multiple VU levels to map the performance curve.
# Runs all combinations of VU levels × versions × endpoints (18 total).
#
# Usage:
#   bash run-stress-matrix.sh                    # default: 1m duration, today's date
#   bash run-stress-matrix.sh --duration 30s     # override duration
#   bash run-stress-matrix.sh --date 20260228    # override date suffix
#   bash run-stress-matrix.sh --vus "1 5 10"     # override VU levels
#
# Reports are written to /srv/k6/reports/ and accessible at
# https://lobsters-k6.eapotapov.dev/reports/

set -euo pipefail

DURATION="1m"
DATE=$(date +%Y%m%d)
VU_LEVELS="10 20 40"
REPORT_DIR="/srv/k6/reports"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse CLI options
while [[ $# -gt 0 ]]; do
  case $1 in
    --duration) DURATION="$2"; shift 2 ;;
    --date)     DATE="$2"; shift 2 ;;
    --vus)      VU_LEVELS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Version definitions: name, URL, hostname
declare -A URLS=(
  [mariadb]="https://lobsters-mariadb.eapotapov.dev"
  [sqlite-broken]="https://lobsters-1871.eapotapov.dev"
  [sqlite-fixed]="https://lobsters-1927.eapotapov.dev"
)

# Endpoint definitions: name, script
declare -A SCRIPTS=(
  [homepage]="homepage-single.js"
  [story]="story-page-single.js"
)

VERSION_ORDER="mariadb sqlite-broken sqlite-fixed"
ENDPOINT_ORDER="homepage story"

total=0
for _ in $VU_LEVELS; do
  for _ in $VERSION_ORDER; do
    for _ in $ENDPOINT_ORDER; do
      total=$((total + 1))
    done
  done
done

echo "============================================"
echo "Stress Test Matrix"
echo "============================================"
echo "VU levels:  $VU_LEVELS"
echo "Versions:   $VERSION_ORDER"
echo "Endpoints:  $ENDPOINT_ORDER"
echo "Duration:   $DURATION"
echo "Report dir: $REPORT_DIR"
echo "Total runs: $total"
echo "============================================"
echo ""

run=0
for vus in $VU_LEVELS; do
  for version in $VERSION_ORDER; do
    for endpoint in $ENDPOINT_ORDER; do
      run=$((run + 1))
      report_name="${endpoint}-${version}-${vus}vu-${DATE}"
      report_path="${REPORT_DIR}/${report_name}.html"
      script="${SCRIPT_DIR}/${SCRIPTS[$endpoint]}"
      url="${URLS[$version]}"

      echo "[$run/$total] ${endpoint} | ${version} | ${vus} VUs | ${DURATION}"

      k6 run \
        --vus "$vus" \
        --duration "$DURATION" \
        --out "web-dashboard=export=${report_path}" \
        -e "TARGET_URL=${url}" \
        --summary-trend-stats="avg,p(95)" \
        --quiet \
        "$script" 2>&1 | tail -20

      echo "  -> ${report_name}.html"
      echo ""
    done
  done
done

echo "============================================"
echo "All $total runs complete."
echo "Reports: https://lobsters-k6.eapotapov.dev/reports/"
echo "============================================"
