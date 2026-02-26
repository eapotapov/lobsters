#!/usr/bin/env bash
#
# Supporting evidence: PRAGMA tuning does NOT fix the story page issue.
#
# This script tests SQLite with tuned PRAGMAs to prove the bottleneck is
# the query planner, not cache/IO configuration.
#
# Run on the remote server:
#   bash ~/lobsters/benchmarks/07-pragma-tuning.sh <story_short_id>
#
# Expected results:
#
#   | Page         | SQLite default | SQLite tuned | MySQL |
#   |--------------|---------------|--------------|-------|
#   | Homepage c=10 | 88 req/s     | 81 req/s     | 80    |
#   | Story c=10    | 2.6 req/s    | 2.5 req/s    | 63    |
#
# PRAGMA tuning has NO effect on the story page. The problem is not IO.

set -euo pipefail

STORY_SHORT_ID="${1:-xxxxxx}"
SQLITE_DIR="$HOME/lobsters/2-after-sqlite"
DB_CONFIG="${SQLITE_DIR}/config/database.yml"
DURATION=10s
THREADS=2
CONNECTIONS=10

echo "============================================="
echo "  PRAGMA Tuning Test"
echo "  wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}"
echo "============================================="
echo ""

# Backup config
cp "${DB_CONFIG}" "${DB_CONFIG}.bak"

echo "--- 1. SQLite with DEFAULT PRAGMAs ---"
echo ""
echo "Homepage:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/" 2>&1
echo ""
echo "Story page:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/s/${STORY_SHORT_ID}" 2>&1
echo ""

# Apply tuned PRAGMAs via an initializer
cat > "${SQLITE_DIR}/config/initializers/sqlite_pragma_bench.rb" << 'RUBY'
# Temporary PRAGMA tuning for benchmarking
Rails.application.config.after_initialize do
  if ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")
    conn = ActiveRecord::Base.connection
    conn.execute("PRAGMA cache_size = -204800")       # 200 MB
    conn.execute("PRAGMA mmap_size = 1073741824")      # 1 GB
    conn.execute("PRAGMA temp_store = MEMORY")
    Rails.logger.info "SQLite PRAGMAs tuned for benchmark"
  end
end
RUBY

systemctl --user restart lobsters-after
sleep 3

# Warm up
curl -s "http://localhost:3002/" > /dev/null 2>&1
curl -s "http://localhost:3002/s/${STORY_SHORT_ID}" > /dev/null 2>&1
sleep 1

echo "--- 2. SQLite with TUNED PRAGMAs ---"
echo "(cache_size=200MB, mmap_size=1GB, temp_store=MEMORY)"
echo ""
echo "Homepage:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/" 2>&1
echo ""
echo "Story page:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/s/${STORY_SHORT_ID}" 2>&1
echo ""

# Restore
rm -f "${SQLITE_DIR}/config/initializers/sqlite_pragma_bench.rb"
cp "${DB_CONFIG}.bak" "${DB_CONFIG}"
rm "${DB_CONFIG}.bak"
systemctl --user restart lobsters-after

echo "--- 3. MySQL (reference) ---"
echo ""
echo "Homepage:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3001/" 2>&1
echo ""
echo "Story page:"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3001/s/${STORY_SHORT_ID}" 2>&1
echo ""

echo "Original config restored and service restarted."
echo ""
echo "CONCLUSION: If story page performance is unchanged between default"
echo "and tuned PRAGMAs, the bottleneck is the query planner, not IO."
