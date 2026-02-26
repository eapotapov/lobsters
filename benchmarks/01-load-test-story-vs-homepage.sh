#!/usr/bin/env bash
#
# Step 1: Prove the story page collapses on SQLite while the homepage is fine.
#
# This is the key finding: SQLite matches or beats MySQL on homepage reads,
# but is 24x slower on story page views. The story page is the #1 most-hit
# endpoint on lobste.rs (197k hits in production logs).
#
# Run on the remote server where all three instances are running.
# Requires: wrk (sudo apt install wrk)
#
# Expected results (from our testing with 661 MB SQLite database):
#
#   Homepage (/ endpoint):
#     MySQL before:  ~80 req/s, 134ms avg
#     SQLite:        ~88 req/s, 120ms avg   <-- SQLite is FASTER
#     MySQL revert:  ~85 req/s, 121ms avg
#
#   Story page (/s/xxxxx/story-title endpoint):
#     MySQL before:  ~63 req/s, 171ms avg
#     SQLite:        ~2.6 req/s, 1420ms avg  <-- 24x SLOWER, 73% timeouts
#     MySQL revert:  ~63 req/s, 171ms avg

set -euo pipefail

# Configuration
DURATION=10s
THREADS=2
CONNECTIONS=10

# Pick a story URL that exists in all three databases.
# Replace this with an actual story short_id from your data.
# You can find one with: bin/rails runner "puts Story.last.short_id"
STORY_SHORT_ID="${1:-xxxxxx}"

echo "============================================="
echo "  Lobsters Load Test: Story Page vs Homepage"
echo "  wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}"
echo "  Story short_id: ${STORY_SHORT_ID}"
echo "============================================="
echo ""

run_test() {
  local label="$1"
  local url="$2"
  echo "--- ${label} ---"
  wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "${url}" 2>&1
  echo ""
}

echo "===== HOMEPAGE TESTS ====="
echo ""
run_test "MySQL (before) - Homepage"  "http://localhost:3001/"
run_test "SQLite         - Homepage"  "http://localhost:3002/"
run_test "MySQL (revert) - Homepage"  "http://localhost:3003/"

echo ""
echo "===== STORY PAGE TESTS ====="
echo ""
run_test "MySQL (before) - Story page"  "http://localhost:3001/s/${STORY_SHORT_ID}"
run_test "SQLite         - Story page"  "http://localhost:3002/s/${STORY_SHORT_ID}"
run_test "MySQL (revert) - Story page"  "http://localhost:3003/s/${STORY_SHORT_ID}"

echo ""
echo "===== COLD CACHE TESTS (optional) ====="
echo "To test with cold OS page cache, run as root first:"
echo "  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'"
echo "Then re-run this script. Our results showed cold cache"
echo "made little difference - SQLite was already slow."
