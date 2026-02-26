# Performance Test Suite: SQLite Story Page Bottleneck

These files reproduce the confirmed root cause of the Lobsters SQLite migration
revert: **SQLite's query planner picks the wrong index for `Comment.story_threads()`**,
causing 24x slowdown on story page views (the #1 most-hit endpoint).

## Evidence Chain

| Step | File | What it proves |
|------|------|---------------|
| 1 | `01-load-test-story-vs-homepage.sh` | Story pages collapse on SQLite (24x slower); homepage is fine |
| 2 | `02-explain-query-plans.rb` | SQLite scans 186k rows; MySQL does direct index lookups |
| 3 | `03-raw-query-timing.rb` | CTE query is 23x slower on SQLite; simple queries are equal |
| 4 | `04-story-threads-fix.rb` | Two-line fix makes SQLite 30% faster than MySQL |
| 5 | `05-load-test-with-fix.sh` | End-to-end verification: 5.6 req/s -> 78 req/s |

Supporting files:
- `06-write-contention.rb` - Proves write contention was NOT the cause
- `07-pragma-tuning.sh` - Proves PRAGMA tuning does NOT fix the story page issue

## Prerequisites

- Remote server: `ssh eapotapov@eapotapov-ubuntu`
- Three Lobsters instances running (see `../SETUP.md`)
- `wrk` installed on the remote server (`sudo apt install wrk`)
- SQLite version (port 3002) bloated to ~661 MB with `bin/rails fake_data`
- All versions have matching story data for fair comparison

## Running

Scripts are designed to run **on the remote server**. Copy them over or run via SSH:

```bash
# Copy benchmarks to server
scp -r benchmarks/ eapotapov@eapotapov-ubuntu:~/lobsters/

# Or run individual scripts via SSH
ssh eapotapov@eapotapov-ubuntu 'bash ~/lobsters/benchmarks/01-load-test-story-vs-homepage.sh'
```

Rails runner scripts must be run from the appropriate app directory:

```bash
cd ~/lobsters/2-after-sqlite
bin/rails runner ~/lobsters/benchmarks/02-explain-query-plans.rb
```
