#!/bin/bash
set -e

DURATION=10  # seconds per test
RESULTS_DIR=~/lobsters/benchmark_results
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTFILE="$RESULTS_DIR/bench_${TIMESTAMP}.txt"

# Story URLs for each version (different short_ids because different fake data)
STORY_BEFORE="/s/qhipqf/dolorem_sit_et_consequatur"
STORY_SQLITE="/s/szogql/vel_ullam_tempora"
STORY_REVERT="/s/qhipqf/dolorem_sit_et_consequatur"

log() {
  echo "$@" | tee -a "$OUTFILE"
}

run_wrk() {
  local label="$1"
  local url="$2"
  local conc="$3"
  local threads=$((conc > 4 ? 4 : conc))

  log ""
  log "--- $label (concurrency=$conc, duration=${DURATION}s) ---"
  wrk -t$threads -c$conc -d${DURATION}s --latency "$url" 2>&1 | tee -a "$OUTFILE"
}

log "=========================================="
log "Lobsters Benchmark - $(date)"
log "=========================================="
log ""

# Warm up each server
log "Warming up servers..."
for port in 3001 3002 3003; do
  curl -s -o /dev/null "http://127.0.0.1:$port/"
  curl -s -o /dev/null "http://127.0.0.1:$port/"
  curl -s -o /dev/null "http://127.0.0.1:$port/"
done
sleep 2

log ""
log "=========================================="
log "TEST 1: Homepage reads (/) at increasing concurrency"
log "=========================================="

for conc in 1 2 5 10 20 50; do
  run_wrk "BEFORE-SQLITE (MySQL) - Homepage" "http://127.0.0.1:3001/" $conc
  run_wrk "AFTER-SQLITE (SQLite) - Homepage" "http://127.0.0.1:3002/" $conc
  run_wrk "AFTER-REVERT (MySQL)  - Homepage" "http://127.0.0.1:3003/" $conc
  log ""
  log "-------------------------------------------"
done

log ""
log "=========================================="
log "TEST 2: Story page reads at increasing concurrency"
log "=========================================="

for conc in 1 2 5 10 20 50; do
  run_wrk "BEFORE-SQLITE (MySQL) - Story" "http://127.0.0.1:3001${STORY_BEFORE}" $conc
  run_wrk "AFTER-SQLITE (SQLite) - Story" "http://127.0.0.1:3002${STORY_SQLITE}" $conc
  run_wrk "AFTER-REVERT (MySQL)  - Story" "http://127.0.0.1:3003${STORY_REVERT}" $conc
  log ""
  log "-------------------------------------------"
done

log ""
log "=========================================="
log "DONE - Results saved to $OUTFILE"
log "=========================================="
