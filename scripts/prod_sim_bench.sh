#!/bin/bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"

RESULTS=~/lobsters/benchmark_results
mkdir -p "$RESULTS"
OUT="$RESULTS/prod_sim_$(date +%Y%m%d_%H%M%S).txt"

log() { echo "$@" | tee -a "$OUT"; }

STORY_BEFORE="/s/qhipqf/dolorem_sit_et_consequatur"
STORY_SQLITE="/s/szogql/vel_ullam_tempora"
STORY_REVERT="/s/qmksgq/eaque_dignissimos_ex"

log "============================================="
log "Production Simulation Benchmark - $(date)"
log "============================================="
log ""
log "SQLite DB size: $(du -h ~/lobsters/2-after-sqlite/db/development/primary.sqlite3 | cut -f1)"
log ""

#####################################################################
log "TEST A: Baseline - all 3 versions, warm cache, concurrency=10"
log "============================================="

# Warm up
for port in 3001 3002 3003; do
  for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:$port/; done
done
sleep 2

log ""
log "--- MySQL (before) - Homepage c=10 ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3001/ 2>&1 | tee -a "$OUT"

log ""
log "--- SQLite (default PRAGMAs) - Homepage c=10 ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3002/ 2>&1 | tee -a "$OUT"

log ""
log "--- MySQL (revert) - Homepage c=10 ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3003/ 2>&1 | tee -a "$OUT"

#####################################################################
log ""
log "============================================="
log "TEST B: Drop OS page cache + SQLite default cache (prod conditions)"
log "============================================="
log ""
log "Dropping OS page cache..."
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1

log "--- MySQL (before) - Homepage c=10, COLD ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3001/ 2>&1 | tee -a "$OUT"

log ""
log "Dropping OS page cache again..."
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1

log "--- SQLite (default PRAGMAs) - Homepage c=10, COLD ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3002/ 2>&1 | tee -a "$OUT"

log ""
log "Dropping OS page cache again..."
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1

log "--- MySQL (revert) - Homepage c=10, COLD ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3003/ 2>&1 | tee -a "$OUT"

#####################################################################
log ""
log "============================================="
log "TEST C: Story page - warm vs cold"
log "============================================="

# Warm up stories
for i in 1 2 3; do
  curl -s -o /dev/null "http://127.0.0.1:3001${STORY_BEFORE}"
  curl -s -o /dev/null "http://127.0.0.1:3002${STORY_SQLITE}"
  curl -s -o /dev/null "http://127.0.0.1:3003${STORY_REVERT}"
done
sleep 1

log ""
log "--- Story page WARM, c=10 ---"
log "MySQL (before):"
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3001${STORY_BEFORE}" 2>&1 | tee -a "$OUT"
log ""
log "SQLite:"
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3002${STORY_SQLITE}" 2>&1 | tee -a "$OUT"

log ""
log "--- Story page COLD, c=10 ---"
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1
log "MySQL (before):"
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3001${STORY_BEFORE}" 2>&1 | tee -a "$OUT"
log ""
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1
log "SQLite:"
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3002${STORY_SQLITE}" 2>&1 | tee -a "$OUT"

#####################################################################
log ""
log "============================================="
log "TEST D: SQLite tuned PRAGMAs vs default"
log "============================================="
log ""
log "Restarting SQLite version with tuned PRAGMAs..."
systemctl --user stop lobsters-after
sleep 1

# Create tuned initializer
cat > ~/lobsters/2-after-sqlite/config/initializers/sqlite_pragmas.rb << 'RUBY'
if ActiveRecord::Base.connection.adapter_name == "SQLite"
  db = ActiveRecord::Base.connection
  db.execute("PRAGMA cache_size = -200000")   # 200MB cache
  db.execute("PRAGMA mmap_size = 1073741824") # 1GB mmap
  db.execute("PRAGMA temp_store = MEMORY")
  Rails.logger.info "SQLite TUNED: cache=200MB, mmap=1GB, temp=memory"
end
RUBY

systemctl --user start lobsters-after
sleep 5

# Verify it's running
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3002/ | tee -a "$OUT"
log ""

# Warm up
for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:3002/; done
sleep 2

log "--- SQLite TUNED - Homepage c=10, warm ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3002/ 2>&1 | tee -a "$OUT"

log ""
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1
log "--- SQLite TUNED - Homepage c=10, COLD ---"
wrk -t4 -c10 -d10s --latency http://127.0.0.1:3002/ 2>&1 | tee -a "$OUT"

log ""
log "--- SQLite TUNED - Story c=10, warm ---"
for i in 1 2 3; do curl -s -o /dev/null "http://127.0.0.1:3002${STORY_SQLITE}"; done
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3002${STORY_SQLITE}" 2>&1 | tee -a "$OUT"

log ""
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
sleep 1
log "--- SQLite TUNED - Story c=10, COLD ---"
wrk -t4 -c10 -d10s --latency "http://127.0.0.1:3002${STORY_SQLITE}" 2>&1 | tee -a "$OUT"

#####################################################################
log ""
log "============================================="
log "Restoring SQLite to default PRAGMAs..."
log "============================================="
systemctl --user stop lobsters-after

cat > ~/lobsters/2-after-sqlite/config/initializers/sqlite_pragmas.rb << 'RUBY'
# Default pragmas - no tuning
RUBY

systemctl --user start lobsters-after
sleep 3

log ""
log "DONE. Results saved to $OUT"
