# Lobsters SQLite Migration: Performance Investigation

## The Question

On February 21, 2026, Lobsters deployed a migration from MariaDB to SQLite in production. It was reverted after ~45 minutes with the only explanation: "it was not performant." No specific metrics were captured. This document investigates the probable causes.

## Production Environment

Source: [lobste.rs/about](https://lobste.rs/about)

Three DigitalOcean VPSs:

| Role | Droplet type | vCPUs | RAM | Disk |
|------|-------------|-------|-----|------|
| Web server (Rails/Puma) | s-4vcpu-8gb | 4 | 8 GB | 160 GB SSD |
| MariaDB server | s-4vcpu-8gb | 4 | 8 GB | 160 GB SSD |
| IRC bot | s-1vcpu-1gb | 1 | 1 GB | 25 GB SSD |

Other infrastructure: Hatchbox for provisioning/deployment, DNSimple for DNS, Backblaze B2 + restic for backups.

- **Database size:** ~2.5 GB
- **Traffic profile:** Mostly reads (homepage, story views), occasional writes (votes, comments, moderation)
- **App server:** Puma (multi-threaded/multi-worker)

Note: MariaDB had a **dedicated 8 GB VPS**, meaning the InnoDB buffer pool likely had 4-6 GB of RAM available - enough to cache most or all of the 2.5 GB database in memory. After the SQLite migration, the database would run on the web server VPS, sharing its 8 GB RAM with Rails/Puma workers.

Top request types from production logs (source: [issue #539 comment](https://github.com/lobsters/lobsters/issues/539#issuecomment-3221696245)):
```
197192  StoriesController show         (single story view)
143006  HomeController index           (homepage)
 61220  CommentsController redirect    (comment permalink)
 56915  UsersController show           (user profile)
 53677  HomeController single_tag      (tag filter)
 23355  HomeController newest          (newest stories)
```

## Root Cause: SQLite Query Planner Picks Wrong Index for Story Pages

The #1 most hit endpoint (story page views, 197k hits) uses a recursive CTE query in `Comment.story_threads()` to build hierarchical comment ordering. **This query is 10-24x slower on SQLite than MySQL** due to SQLite's query planner making catastrophic index choices with large datasets.

### The Query

Both engines use a recursive CTE to traverse the parent-child comment tree and construct a `confidence_order_path` blob for sorting:

Source: [`app/models/comment.rb:598-622`](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L598-L622)

```sql
with recursive confidence as (
  select c.id, cast(confidence_order as blob) as confidence_order_path
  from comments c join stories on stories.id = c.story_id
  where (stories.id = ? or stories.merged_story_id = ?) and parent_comment_id is null
  union all
  select c.id, cast(substring(...) || c.confidence_order as blob)
  from comments c join confidence on c.parent_comment_id = confidence.id
)
SELECT comments.* FROM comments
  INNER JOIN confidence ON comments.id = confidence.id
  ORDER BY confidence.confidence_order_path
```

### EXPLAIN Analysis

We ran `EXPLAIN QUERY PLAN` (SQLite) and `EXPLAIN` (MySQL) on this query with **equal data** (~1820 comments per story on both engines).

**SQLite EXPLAIN QUERY PLAN:**
```
SEARCH c USING INDEX comments_parent_comment_id_fk (parent_comment_id=?)
SEARCH stories USING INTEGER PRIMARY KEY (rowid=?)
...
SCAN comments                           -- scans all 186,872 rows
BLOOM FILTER ON confidence (id=?)
```

**MySQL EXPLAIN:**
```
stories: index_merge  Using union(PRIMARY,index_stories_on_merged_story_id)
c:       ref          USING INDEX story_id_short_id
...
comments: eq_ref      PRIMARY        -- direct primary key lookup
```

### Two Bottlenecks Identified

#### Bottleneck 1: Wrong Index in CTE Base Case

**SQLite scans all comments where `parent_comment_id IS NULL`** (186,515 of 186,872 rows - 99.8% of the table), then joins to stories to filter by story_id. MySQL does the opposite: it resolves the story IDs first via index merge, then uses the `story_id_short_id` index to find only the relevant comments.

The [`OR stories.merged_story_id = ?`](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L609) clause in the WHERE prevents SQLite's query planner from using the `story_id` index on comments. With 99.8% of rows matching `parent_comment_id IS NULL`, this is effectively a full table scan.

**Proof:** Rewriting the query to pre-resolve story IDs and use `WHERE c.story_id IN (...)` instead of the JOIN + OR drops the CTE from 160ms to **1.5ms** - a 100x improvement.

#### Bottleneck 2: Full Table Scan on JOIN Back

Even with the CTE fixed, the [`INNER JOIN comments ON comments.id = confidence.id`](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L618) triggers another full table scan. SQLite scans the **entire 186,872-row comments table** to join against the ~25 CTE results, rather than looking up each ID via the primary key. MySQL uses `eq_ref PRIMARY` (direct primary key lookup) for this join.

**Proof:** Adding `.where(story_id: story_ids)` to the outer ActiveRecord query lets SQLite narrow the scan to just the relevant story's comments, dropping DB time from ~130ms to **~1ms**.

### Raw Query Timing (equal data: ~1820 comments per story)

| Query | MySQL | SQLite | Ratio |
|-------|-------|--------|-------|
| **Full CTE + JOIN + ORDER** | **12ms** | **280ms** | **23x** |
| Recursive CTE (count only) | 5ms | 160ms | 32x |
| Simple SELECT (no CTE) | 9ms | 7ms | 0.8x |

The simple query (no CTE) is equally fast on both engines. The recursive CTE is 23-32x slower on SQLite.

### Why MySQL Handles This Better

MySQL's query optimizer has two advantages here:

1. **Index merge**: MySQL can combine multiple index lookups (`USING union(PRIMARY, index_stories_on_merged_story_id)`) to efficiently resolve the OR condition. SQLite cannot.

2. **Join order optimization**: MySQL drives the join from the smaller CTE result set to the larger comments table via primary key lookup (`eq_ref PRIMARY`). SQLite drives from the larger comments table and filters against the CTE.

### The Fix (Verified)

Two changes to `story_threads` that address both bottlenecks:

```ruby
def self.story_threads(story)
  return Comment.none unless story.id

  # Fix 1: Pre-resolve story IDs to avoid JOIN + OR (fixes Bottleneck 1)
  story_ids = [story.id]
  story_ids += Story.where(merged_story_id: story.id).pluck(:id)
  story_ids_sql = story_ids.join(",")

  inner_join = <<~SQL
    inner join (
      with recursive confidence as (
        select c.id, cast(confidence_order as blob) as confidence_order_path
        from comments c
        where c.story_id IN (#{story_ids_sql}) and parent_comment_id is null
        union all
        select c.id, cast(substring(confidence.confidence_order_path, 1, 3 * (depth + 1)) || c.confidence_order as blob)
        from comments c join confidence on c.parent_comment_id = confidence.id
      )
      select * from confidence
    ) confidence on comments.id = confidence.id
  SQL

  # Fix 2: Add WHERE story_id to outer query (fixes Bottleneck 2)
  Comment.joins(inner_join).where(story_id: story_ids).order("confidence.confidence_order_path")
end
```

### End-to-End Load Test Verification

Tested with a **realistic story** (25 comments) in the **large database** (186,872 total comments, 662 MB). This simulates real Lobsters traffic: small per-story comment counts but a large total database.

Load test: `wrk -t2 -c10 -d10s` (10 concurrent connections for 10 seconds):

| Version | Req/s | Avg Latency | DB time | Timeouts |
|---------|-------|-------------|---------|----------|
| **SQLite (original query)** | **5.6** | **972ms** | **~310ms** | **yes** |
| SQLite (fix CTE only) | 12.2 | 487ms | ~130ms | 6 |
| **SQLite (both fixes)** | **78** | **187ms** | **~1ms** | **0** |
| MySQL | 59 | 255ms | ~7ms | 0 |

The two fixes together turn SQLite from **10x slower** to **30% faster** than MySQL on story pages. DB query time dropped from 310ms to 1ms.

## Secondary Issue: Undersized Cache

Source: [deployment gist, revision 19:02 UTC](https://gist.github.com/pushcx/eb7cdf2dc9707dc3ab9e7173d197ddfc/9ce5e1591b47e7a491e8e9d979e6ecf4459a25b1)

The PRAGMA settings captured in that revision (during production debugging) show SQLite was running with defaults:

| Setting | Value | What it means |
|---------|-------|---------------|
| `cache_size` | 2000 pages | **~8 MB** of page cache |
| `mmap_size` | 128 MB | Only 5% of the 2.5 GB database memory-mapped |

For comparison, MariaDB had a dedicated 8 GB VPS. The InnoDB buffer pool would typically be configured at 50-75% of available RAM on a dedicated DB server - roughly 4-6 GB - large enough to hold the entire 2.5 GB database in memory.

With 8 MB of cache for a 2.5 GB database, the vast majority of page reads hit disk. Every homepage load, every story view, every comment thread traversal would generate dozens of disk reads that would have been memory hits under MariaDB.

**However**, our benchmarks showed that PRAGMA tuning did NOT fix the story page issue - the query planner problem (above) was the dominant factor. Cache tuning would still be beneficial for overall performance but was not the root cause.

**Recommended production SQLite settings that were not applied:**
```sql
PRAGMA cache_size = -512000;       -- 512 MB (negative = KB)
PRAGMA mmap_size = 3000000000;     -- map the entire DB file
PRAGMA temp_store = MEMORY;        -- temp tables in RAM
PRAGMA busy_timeout = 5000;        -- 5s wait on lock contention
```

## Secondary Issue: Single-Writer Serialization Under Load

SQLite's concurrency model, even with WAL mode (which they were using), has a fundamental constraint: **only one write transaction can execute at a time** across the entire database.

```
Readers:  Unlimited concurrent readers. Readers never block writers.
          Writers never block readers. This is fine.

Writers:  ONE writer at a time. All other writers wait for a lock.
          If the wait exceeds the timeout, the write fails with SQLITE_BUSY.
```

This is a significant difference from MariaDB/InnoDB, which uses **row-level locking** - multiple writes to different rows (or even different parts of the same table) proceed concurrently.

Under normal conditions with a warm cache, individual SQLite writes complete in microseconds to low milliseconds. The single-writer lock is nearly invisible because each writer holds it so briefly. **However**, our write contention benchmarks showed SQLite was actually 4-7x faster than MySQL for writes with the test dataset - so write contention alone was not the problem at this data size.

For historical context, SQLite's write concurrency has improved over time but remains fundamentally limited:

| Era | Mode | Behavior |
|-----|------|----------|
| Pre-2010 | Journal (rollback) | Writes lock the **entire database file**. Readers block too. |
| 2010+ | WAL mode | Concurrent readers + single writer. Readers and writers don't block each other. |
| Experimental | BEGIN CONCURRENT | Multiple concurrent write transactions with optimistic page-level locking. Conflicts detected at COMMIT. **Not in mainline SQLite as of 2026.** |

## What the Dev Benchmarks Missed

Source: [PR #1871 comment](https://github.com/lobsters/lobsters/pull/1871#issuecomment-3792806780)

The pre-deploy benchmarks showed SQLite performing **better** than MariaDB:

| Benchmark | MariaDB | SQLite | Difference |
|-----------|---------|--------|------------|
| Homepage (`/`), 1000 reqs, concurrency 2 | 36ms | 34ms | SQLite 6% faster |
| Story view (`/s/:a/:b`), 1000 reqs, concurrency 2 | 53ms | 35ms | SQLite 34% faster |

These benchmarks failed to predict production behavior because:

1. **Dataset size:** Fake data is orders of magnitude smaller than the 2.5 GB production database. At small sizes, everything fits in cache regardless of settings, and even a full table scan completes in microseconds.
2. **Concurrency:** `ab -c 2` tests only 2 concurrent connections. Production Puma serves many more simultaneous requests.
3. **Read-only:** The benchmarks only tested reads (homepage, story view). No concurrent write operations were included.
4. **Cache state:** Development benchmarks start with a warm cache after the server boots and processes a few requests. Production under real traffic constantly accesses different parts of the database.

## Reproduction Results

We set up all three versions of Lobsters on an Ubuntu server and ran benchmarks. The SQLite version was bloated to ~661 MB to create a more realistic dataset.

### Test Environment

- Ubuntu 24.04, Ruby 4.0.0, MySQL 8.0, SQLite (WAL mode)
- Three instances on ports 3001 (MySQL before), 3002 (SQLite), 3003 (MySQL revert)
- Load testing with `wrk` at concurrency 10 for 10 seconds each

### Finding 1: Homepage reads - SQLite is FASTER with small/warm data

With warm OS page caches, SQLite slightly outperforms MySQL even at concurrency 10:

| Version | Req/sec | Avg latency | p99 latency |
|---------|---------|-------------|-------------|
| MySQL (before) | 80 | 134ms | 725ms |
| **SQLite (default)** | **88** | **120ms** | **669ms** |
| MySQL (revert) | 85 | 121ms | 677ms |

This matches the dev benchmarks and explains why the team expected the migration to work.

### Finding 2: Story page - SQLite COLLAPSES with large data

The story page (which loads all comments for a story) exposed the problem dramatically. With the 661 MB database:

| Version | Req/sec | Avg latency | Timeouts |
|---------|---------|-------------|----------|
| MySQL (before) | **63** | **171ms** | 0 |
| SQLite (default) | **2.6** | **1,420ms** | 19/26 |

**SQLite was 24x slower than MySQL on story page views.** 73% of requests timed out. This is the production issue.

### Finding 3: Cold OS cache makes little difference

Dropping the OS page cache (`echo 3 > /proc/sys/vm/drop_caches`) before the test had minimal impact - MySQL recovered quickly, and SQLite was already slow:

| Test | MySQL cold | SQLite cold |
|------|-----------|-------------|
| Homepage c=10 | 80 req/s | 89 req/s |
| Story page c=10 | 63 req/s | 2.3 req/s |

This suggests the bottleneck isn't just the OS page cache but SQLite's internal query handling with large datasets.

### Finding 4: Tuned PRAGMAs help homepage but NOT story pages

With tuned PRAGMAs (`cache_size=200MB`, `mmap_size=1GB`, `temp_store=MEMORY`):

| Page | SQLite default | SQLite tuned | MySQL |
|------|---------------|--------------|-------|
| Homepage c=10, warm | 88 req/s | 81 req/s | 80 req/s |
| Homepage c=10, cold | 89 req/s | 92 req/s | 80 req/s |
| Story c=10, warm | 2.6 req/s | **2.5 req/s** | 63 req/s |
| Story c=10, cold | 2.3 req/s | **2.4 req/s** | 63 req/s |

PRAGMA tuning did NOT fix the story page performance at all. The story page remained ~25x slower than MySQL regardless of cache configuration.

### Finding 5: Write contention with small data (5 threads, 250 writes)

| Version | Sequential | Concurrent | Errors | Slowdown |
|---------|-----------|------------|--------|----------|
| MySQL (before) | 41 writes/s | 40 writes/s | 1 | 1.02x |
| **SQLite** | **189 writes/s** | **296 writes/s** | **0** | **0.64x** |
| MySQL (revert) | 36 writes/s | 41 writes/s | 1 | 0.87x |

With small data, SQLite writes were 4-7x faster than MySQL and showed no contention. This confirms that write contention alone was not the problem at this data size.

## What a Second Attempt Needs

The core fix is straightforward, but a full migration would also need:

1. **Apply the `story_threads` fix** shown above (two lines changed)
2. **Audit other queries** for similar `JOIN + OR` patterns where SQLite's planner makes different choices than MySQL (e.g., `Comment.comment_threads` uses the same pattern)
3. **Test at production data scale** - the bug only manifests with large total row counts, not per-query row counts
4. **PRAGMA tuning** - still beneficial for overall performance, though not the root cause of this specific issue
5. **Add SQLite-specific indexes** (e.g., composite `(story_id, parent_comment_id)`) as insurance against planner regressions

## Conclusion

The revert was caused by SQLite's query planner making a catastrophic index choice for the `Comment.story_threads()` query - the #1 most hit endpoint on the site.

**The root cause in one sentence:** The `JOIN stories ... WHERE (stories.id = X OR stories.merged_story_id = X)` pattern causes SQLite to scan via `parent_comment_id IS NULL` (matching 99.8% of all rows), while MySQL correctly uses index merge to narrow by `story_id` first.

This is a query planner difference, not a fundamental SQLite limitation. A two-line fix (pre-resolve story IDs + add `WHERE story_id` to the outer query) makes SQLite 30% faster than MySQL on the same workload.

The dev benchmarks missed this because with small datasets (~1,000 total comments), even a full table scan completes in microseconds. The production database had ~186k+ comments, making the wrong index selection devastating.

PRAGMA tuning (cache_size, mmap_size) had no effect because the problem wasn't I/O - it was that SQLite executed the query touching 186k rows instead of 25. The team's 45-minute debugging window and focus on PRAGMAs was looking in the wrong place.

The team's statement - "we ran out of debugging time, but would like to find an expert and try again later" - is apt. The fix is small but requires understanding how SQLite's query planner differs from MySQL's.
