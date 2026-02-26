# Lobsters SQLite Migration: Timeline & Post-Mortem

## Background

Lobsters (lobste.rs) is a computing-focused link aggregation site running on Rails. The idea to migrate away from MySQL/MariaDB was first raised in [issue #539](https://github.com/lobsters/lobsters/issues/539) in August 2018 (originally targeting PostgreSQL, later pivoted to SQLite). The actual migration work was carried out by thomasdziedzic in [PR #1871](https://github.com/lobsters/lobsters/pull/1871), building on months of work starting in late 2025. The migration was deployed to production on February 21, 2026, and reverted approximately 3 hours later.

## Pre-Deploy: Issues Encountered During Development

### Null bytes in text data (Jan-Feb 2026)

SQLite cannot handle null bytes (`\0`) in inline SQL string literals. Three records in the production database contained null bytes: two comments (from pasting out of PDFs) and one story_text (a hex dump). This was surfaced as a Rails bug: [rails/rails#55373](https://github.com/rails/rails/issues/55373).

On Feb 16, pushcx wrote a migration (`3e729cbe`) to delete the null bytes. However, creating a Moderation record to log the edit generated a Message to the author containing a diff of the old (null-byte-containing) text, creating *more* null bytes in the database. This was discovered when the migration script failed at 76% completion on the `messages` table.

### Data migration tooling (Jan 29 - Feb 18)

The initial approach used [mysql2sqlite](https://github.com/dumblob/mysql2sqlite), a 289-line AWK script. It stalled at ~547k lines (~6% completion) due to encoding issues with binary data in the `confidence_order_path` column. The team then wrote a custom Ruby rake task that dumps all tables to YAML and loads them back, which worked after the null byte issues were resolved.

### Collation limitations

SQLite's `NOCASE` collation only handles ASCII case folding, unlike MariaDB's `utf8mb4_general_ci` which treats accented characters as equivalent to unaccented. This was worked around by setting `COLLATE NOCASE` on the username column.

### Full-text search rewrite

The search system had to be rewritten from MariaDB's `MATCH ... AGAINST ... IN BOOLEAN MODE` to SQLite's FTS5 extension, which thomasdziedzic described as the majority of the migration work.

### Dev benchmark results

Benchmarks on development machines with fake data showed SQLite performing comparably or better than MariaDB:

- Homepage (`/`): ~34ms (SQLite) vs ~36ms (MariaDB) - roughly equal
- Single story view (`/s/:a/:b`): ~35ms (SQLite) vs ~53ms (MariaDB) - **18ms faster** with SQLite (~34% improvement)

These were run with `ab -n 1000 -c 2` in the development environment.

### Data integrity verification

The night before deploy (Feb 21 ~02:00 UTC), pushcx confirmed a round-trip dump/load produced identical data:
```
$ diff mariadb.dump.yml sqlite.dump.yml > diff
$ wc -l diff
0 diff
```

## Deploy Day: February 21, 2026

All times UTC. Sources: [deployment gist](https://gist.github.com/pushcx/eb7cdf2dc9707dc3ab9e7173d197ddfc) revision history (25 revisions), Git commits, PR comments, and gist comments.

### Phase 1: Preparation (16:25 - 16:46)

| Time | Event |
|------|-------|
| 16:25 | pushcx comments on PR #1871: "we're on a call and going to migrate prod now" |
| 16:38 | PR #1871 merged (commit `74544e96`) |
| 16:46 | Deployment gist created with migration checklist |
| 16:47 | Commit `a369b8b5`: "prep for sqlite migration #1871 #539" |

### Phase 2: Migration execution (16:51 - 18:17, ~1.5 hours)

| Time | Event |
|------|-------|
| 16:51 | First checklist item ticked off |
| ~16:56 | Site put into **read-only mode**, banner added linking to the gist |
| ~17:00 | `lobsters-deploy` run, MariaDB backup taken to pushcx's desktop |
| ~17:01 | `dump_db` started, pre-built SQLite file scp'd to production server |
| 17:05 | Community notices the maintenance. First gist comment: "History being re-written (to SQLite)" |
| 17:08 | Dump still running. SQLite file already on the server. |
| 17:20-17:33 | Continuing migration steps: `load_db`, jj (Jujutsu VCS) bookmark operations |
| 18:17 | **All migration checklist items marked complete.** Site deployed on SQLite and serving traffic. |

The migration itself (dump MariaDB, load into SQLite, deploy) took roughly 1 hour 20 minutes. The production database was approximately 2.5 GB.

### Phase 3: SQLite live in production (18:17 - 19:02, ~45 minutes)

| Time | Event |
|------|-------|
| 18:17 | Site is live on SQLite, serving real user traffic |
| 18:38-18:55 | Community gist comments celebrating: "I was here for the SQLite migration!", "2/22 never forget" |
| 19:02 | **Perf notes section added to gist.** The remaining post-migration tasks (remove trilogy gem, take backup, verify backup script) are struck through with `~` rather than checked off. PRAGMA settings recorded. |

The fact that the post-deploy tasks were struck through (not completed) and immediately followed by PRAGMA debugging indicates problems were apparent quickly.

### Phase 4: Decision to revert (19:02 - 19:13, ~11 minutes)

| Time | Event |
|------|-------|
| 19:02 | PRAGMA settings captured in the gist (see analysis below) |
| 19:09 | pushcx adds to gist: "# revert checklist" with body "writing now" |
| 19:10 | Full revert checklist drafted |
| 19:11-19:13 | Revert checklist refined: steps reordered, "move SQLite file to home dir" added |

From "site live" to "decision to revert" was roughly **45 minutes**.

### Phase 5: Revert execution (19:26 - 19:39, ~13 minutes)

| Time | Event |
|------|-------|
| 19:26 | PR #1924 created and immediately merged: "Revert 'Migrate to SQLite again'" |
| 19:27 | Revert commit on main (`a4cf468a`), Puma stopped |
| 19:31 | DATABASE_URL reverted, config/database.yml restored to MariaDB |
| 19:33 | `lobsters-deploy` complete, Puma restarted on MariaDB, background jobs restarted |
| 19:34 | Commit `fce8b853`: "revert read-only mode, layout" - banner and read-only mode removed |
| 19:35-19:39 | Final cleanup: SQLite file moved to pushcx's home directory for safekeeping |

### Aftermath

| Time | Event |
|------|-------|
| 19:54 | PR #1925 opened: "Fix username timeout validation" (unrelated bug found during testing) |
| 22:34 | Gist commenter asks: "What was the rationale for migrating to SQLite in the first place?" |

## Performance Analysis

### What was recorded

The only documented performance data from production is the SQLite PRAGMA settings, captured at 19:02 in the deployment gist:

```
PRAGMA foreign_keys    = 1        (enabled)
PRAGMA journal_mode    = wal      (Write-Ahead Logging)
PRAGMA synchronous     = 1        (NORMAL)
PRAGMA mmap_size       = 134217728 (128 MB)
PRAGMA journal_size_limit = 67108864 (64 MB)
PRAGMA cache_size      = 2000     (2000 pages = ~8 MB)
```

### What was NOT recorded

- No response time measurements from production
- No error rates or error logs
- No specific slow queries identified
- No comparison metrics against MariaDB production performance
- No push.cx stream recording for this date (archive jumps from Feb 19 to nothing)

### Probable issues with the PRAGMA configuration

The SQLite defaults were largely left in place, which is problematic for a 2.5 GB database under real traffic:

**`cache_size = 2000` (~8 MB)** - This is SQLite's default and critically undersized. The production database was 2.5 GB. MariaDB's InnoDB buffer pool in production would typically be configured to hold most or all of the working set in RAM (commonly 512 MB to several GB). With only 8 MB of page cache, the vast majority of SQLite reads would hit disk.

**`mmap_size = 134217728` (128 MB)** - Only maps ~5% of the 2.5 GB database file into the OS page cache via memory-mapped I/O. While the OS kernel would still cache pages separately, explicit mmap allows SQLite to bypass some overhead. For a 2.5 GB database, setting this to the full file size would be more appropriate.

**`foreign_keys = 1`** - Adds overhead to every write operation by checking referential integrity. MariaDB also enforces foreign keys, so this is not an unfair comparison, but it does contribute to write latency.

**`synchronous = 1` (NORMAL)** - This is reasonable for WAL mode and not likely a bottleneck.

**Missing optimizations** that are commonly recommended for production SQLite:
- `PRAGMA cache_size = -512000` (512 MB) or larger
- `PRAGMA mmap_size = 3000000000` (map the entire DB)
- `PRAGMA temp_store = MEMORY`
- `PRAGMA busy_timeout = 5000` (though `timeout: 1000` was set in database.yml)
- Connection pooling tuning for WAL mode concurrent readers

### Why dev benchmarks didn't predict this

The development benchmarks used fake data (much smaller dataset) on a developer laptop. At small data sizes, SQLite's lower overhead (no client-server protocol, no network socket) gives it an advantage. At production data sizes (2.5 GB), the database no longer fits in SQLite's tiny default cache, and every request that touches uncached pages becomes I/O-bound.

MariaDB in production had years of tuning (buffer pool sizing, query cache, etc.) that SQLite didn't get.

## Summary

The SQLite migration was reverted after ~45 minutes in production. The revert PR states: "We deployed and it was not performant. We ran out of debugging time, but would like to find an expert and try again later."

The most likely cause was SQLite running with default configuration (particularly the 8 MB cache) against a 2.5 GB database under real traffic, where the well-tuned MariaDB installation it replaced would have had most of the working set cached in memory. The team did not have time to tune SQLite's PRAGMAs in production before deciding to revert.

The decision was made quickly (7 minutes from PRAGMA capture to "writing revert checklist now") and executed efficiently (13 minutes from revert PR to site fully restored). The team expressed interest in trying again with expert help.

## Source Links

- [PR #1871 - Migrate to SQLite again](https://github.com/lobsters/lobsters/pull/1871)
- [PR #1924 - Revert](https://github.com/lobsters/lobsters/pull/1924)
- [Issue #539 - Original migration discussion (2018)](https://github.com/lobsters/lobsters/issues/539)
- [Deployment gist with checklist and perf notes](https://gist.github.com/pushcx/eb7cdf2dc9707dc3ab9e7173d197ddfc)
- [Rails bug #55373 - Null bytes in SQLite](https://github.com/rails/rails/issues/55373)
- [push.cx stream: Jan 26 - Initial PR review](https://push.cx/stream/2026-01-26-longiclangs)
- [push.cx stream: Jan 29 - mysql2sqlite stall](https://push.cx/stream/2026-01-29)
- [push.cx stream: Feb 16 - Null byte migration](https://push.cx/stream/2026-02-16-whats-the-over-under-on-this-being-vibecoded)
- [push.cx stream: Feb 19 - Deploy prep](https://push.cx/stream/2026-02-19-also-we-told-your-mom)
