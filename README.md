# Lobsters SQLite Migration Study

Root cause analysis and production-faithful reproduction of the [Lobsters](https://lobste.rs) failed SQLite migration (Feb 21, 2026).

Lobsters migrated from MariaDB to SQLite via [PR #1871](https://github.com/lobsters/lobsters/pull/1871) and reverted 45 minutes later via [PR #1924](https://github.com/lobsters/lobsters/pull/1924) because "it was not performant." This study identifies the bug and demonstrates a fix.

## The Bug

SQLite's query planner picks the wrong index for `Comment.story_threads()` — the most-hit endpoint (every story page). The `JOIN stories ... WHERE (stories.id = X OR stories.merged_story_id = X)` pattern causes SQLite to scan 99.8% of the comments table. MariaDB handles it fine.

**The fix** ([PR #1927](https://github.com/lobsters/lobsters/pull/1927)): pre-resolve story IDs and use `WHERE story_id IN (...)` instead of the JOIN+OR. Two lines changed. SQLite becomes 30% *faster* than MariaDB on this query.

## Reproduction Environment

Two DigitalOcean droplets run three versions side-by-side with identical production-scale data (~7.2M rows):

| Version | DB | Hostname |
|---|---|---|
| Current (main) | MariaDB (separate server) | `lobsters-mariadb.eapotapov.dev` |
| PR #1871 (broken) | SQLite | `lobsters-1871.eapotapov.dev` |
| Fix (PR #1927) | SQLite | `lobsters-1927.eapotapov.dev` |

## Repository Structure

```
INVESTIGATION.md           Root cause analysis
TIMELINE.md                Deploy day minute-by-minute
PERFORMANCE-TESTING.md     Benchmark results
SETUP.md                   Server setup documentation
HANDOFF.md                 Full context for session continuity
CLAUDE.md                  Claude Code project instructions
lobsters-current/          Submodule: upstream main (MariaDB)
lobsters-sqlite/           Submodule: PR #1871 (SQLite, broken)
lobsters-sqlite-fixed/     Submodule: fork with query fix
benchmarks/                wrk load tests and query plan analysis
scripts/
  seed_production_scale.rb   Bulk data generator (MariaDB)
  import_to_sqlite_fast.rb   Fast SQLite import (drop/recreate indexes)
  update_counters_only.rb    Standalone counter cache updater
  dump_mariadb_to_sqlite.sh  MariaDB-to-SQLite transfer pipeline
```

## Key Findings

1. **PRAGMA tuning does not help.** The bottleneck is a bad query plan, not SQLite configuration.
2. **The OR-based JOIN is the sole cause.** One query pattern accounts for the entire performance gap.
3. **With the fix, SQLite matches or beats MariaDB** on all tested endpoints.

See [INVESTIGATION.md](INVESTIGATION.md) for the full analysis.
