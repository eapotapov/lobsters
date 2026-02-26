# Performance Testing

Scripts that reproduce the confirmed root cause of the Lobsters SQLite migration revert: **SQLite's query planner picks the wrong index for `Comment.story_threads()`**, causing 24x slowdown on story page views.

## Evidence Chain

| Step | Script | What it proves |
|------|--------|---------------|
| 1 | [01-load-test-story-vs-homepage.sh](benchmarks/01-load-test-story-vs-homepage.sh) | Story pages collapse on SQLite (24x slower); homepage is fine |
| 2 | [02-explain-query-plans.rb](benchmarks/02-explain-query-plans.rb) | SQLite scans 186k rows; MySQL does direct index lookups |
| 3 | [03-raw-query-timing.rb](benchmarks/03-raw-query-timing.rb) | CTE query is 23x slower on SQLite; simple queries are equal |
| 4 | [04-story-threads-fix.rb](benchmarks/04-story-threads-fix.rb) | Two-line fix makes SQLite 30% faster than MySQL |
| 5 | [05-load-test-with-fix.sh](benchmarks/05-load-test-with-fix.sh) | End-to-end verification: 5.6 req/s → 78 req/s |

## Ruling Out Alternative Causes

| Script | What it disproves |
|--------|-------------------|
| [06-write-contention.rb](benchmarks/06-write-contention.rb) | Write contention was NOT the cause (SQLite was 4-7x faster) |
| [07-pragma-tuning.sh](benchmarks/07-pragma-tuning.sh) | PRAGMA tuning does NOT fix the story page issue |

## How to Run

Scripts run on the remote server (`ssh eapotapov@eapotapov-ubuntu`) where the three Lobsters instances are deployed. See [SETUP.md](SETUP.md) for server details.

```bash
# Shell scripts (wrk load tests) - run directly on server
bash ~/lobsters/benchmarks/01-load-test-story-vs-homepage.sh <story_short_id>

# Ruby scripts (query analysis) - run via rails runner from the app directory
cd ~/lobsters/2-after-sqlite
bin/rails runner ~/lobsters/benchmarks/02-explain-query-plans.rb
```

## Key Results

Story page load test (`wrk -t2 -c10 -d10s`):

| Version | Req/s | Avg Latency | Timeouts |
|---------|-------|-------------|----------|
| MySQL (before) | 63 | 171ms | 0 |
| **SQLite (original)** | **2.6** | **1,420ms** | **19/26** |
| **SQLite (with fix)** | **78** | **187ms** | **0** |

Full analysis: [INVESTIGATION.md](INVESTIGATION.md) · Timeline: [TIMELINE.md](TIMELINE.md)
