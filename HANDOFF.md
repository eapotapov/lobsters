# Handoff: Lobsters SQLite Migration Study

This document contains everything a new session needs to continue this project from where we left off.

## What This Project Is

A study of the Lobsters (lobste.rs) failed SQLite migration. On Feb 21, 2026, they migrated from MariaDB to SQLite in production. It was reverted after ~45 minutes because "it was not performant." We investigated the root cause, found a fix, and built a production-faithful reproduction environment.

## What's Been Done

### Phase 1: Investigation (complete)
- Identified root cause: SQLite query planner picks wrong index for `Comment.story_threads()` — the #1 most-hit endpoint
- The `JOIN stories ... WHERE (stories.id = X OR stories.merged_story_id = X)` pattern causes SQLite to scan 99.8% of comments table
- Two-line fix makes SQLite 30% *faster* than MySQL on the same query
- Full analysis in `INVESTIGATION.md`, timeline in `TIMELINE.md`

### Phase 2: Benchmarking on single server (complete)
- Set up three versions on `eapotapov-ubuntu` (single server, MySQL 8.0)
- Confirmed 24x slowdown on story pages with SQLite
- Confirmed PRAGMA tuning does NOT fix it
- Confirmed the query fix eliminates the bottleneck
- Scripts in `benchmarks/`, results in `INVESTIGATION.md`

### Phase 3: Production-faithful reproduction (COMPLETE)

**Infrastructure: COMPLETE. Databases: SEEDED. Data: VERIFIED IDENTICAL.**

All three versions are running and serving pages over HTTPS with production-scale data. Playwright-based comparison confirmed identical content across all three sites (homepage, /recent, /comments, story pages, user profiles).

## Infrastructure

### DigitalOcean droplets (context: `doctl2 --context apexdata`)

| Droplet | ID | Public IP | Private IP | Spec | Region |
|---|---|---|---|---|---|
| `lobsters-app` | 554384035 | 178.128.147.216 | 10.116.0.2 | s-4vcpu-8gb | nyc1 |
| `lobsters-db` | 554384112 | 104.248.63.52 | 10.116.0.3 | s-4vcpu-8gb | nyc1 |

SSH: `ssh root@178.128.147.216` / `ssh root@104.248.63.52`

### Services on lobsters-app

| Service | Port | DB | Hostname |
|---|---|---|---|
| `lobsters-current` | 3001 | MariaDB on 10.116.0.3 | lobsters-mariadb.eapotapov.dev |
| `lobsters-sqlite` | 3002 | SQLite (local) | lobsters-1871.eapotapov.dev |
| `lobsters-sqlite-fixed` | 3003 | SQLite (local) | lobsters-1927.eapotapov.dev |
| nginx | 80/443 | — | routes by Host header, HTTPS via Let's Encrypt |

All Puma services bind to 127.0.0.1 (nginx proxies). MariaDB binds to 10.116.0.3 (private only).

**HTTPS:** Let's Encrypt certs via certbot (nginx plugin). Auto-renewal configured. Cert at `/etc/letsencrypt/live/lobsters-mariadb.eapotapov.dev/`. All three domains on one cert. Certbot added `listen 443 ssl` and HTTP→HTTPS redirect to nginx config.

**robots.txt:** All three sites return `Disallow: /` via nginx `location = /robots.txt` block (inline, no file on disk).

### /etc/hosts entry

```
178.128.147.216 lobsters-mariadb.eapotapov.dev lobsters-1871.eapotapov.dev lobsters-1927.eapotapov.dev
```

### App server software

| Component | Version/Details |
|---|---|
| OS | Ubuntu 24.04.3 LTS |
| Ruby | 4.0.0 via rbenv (with YJIT) |
| Rust | latest stable via rustup (in `/srv/lobsters/.cargo/`) |
| Rails env | `RAILS_ENV=development` (all three) |
| nginx | system package, ports 80+443 (Let's Encrypt via certbot) |

App code lives at `/srv/lobsters/{lobsters-current,lobsters-sqlite,lobsters-sqlite-fixed}`.
All run as the `lobsters` system user.

## Database Seeding

### Current state

All three databases contain identical data:

| Table | Rows |
|---|---|
| users | 5,000 |
| stories | 120,000 |
| comments | 675,000 |
| votes | 4,000,000 |
| taggings | 240,044 |
| story_texts | 120,000 |
| read_ribbons | 2,000,000 |
| saved_stories | 49,999 |
| hidden_stories | 30,000 |
| hats | 500 |
| categories | 9 |
| tags | 79 |
| domains | 1 |
| keystores | 10,001 |
| moderations | 88 |
| mod_activities | 88 |
| usernames | 5,000 |
| **Total** | **~7,250,000** |

- MariaDB datadir: ~2.3 GB (550 MB compressed)
- SQLite: ~996 MB each

Test user password is set on all three versions via `update_columns` (bypasses Token callbacks). Credentials not stored in docs.

### How seeding was done

**Step 1: Generate data into MariaDB**

Used `scripts/seed_production_scale.rb` — a custom bulk-insert script that generates production-scale data using raw SQL INSERTs (batches of 5000). The script also updates all counter caches (score, flags, comments_count, karma, etc.) using optimized JOIN-based UPDATEs. Runs via `rails runner` on the `lobsters-current` version.

MariaDB must be reset first (DROP/CREATE from db server as root), and schema must be loaded with `SET FOREIGN_KEY_CHECKS=0`.

```bash
# Reset MariaDB (on db server)
ssh root@104.248.63.52 "mysql -u root -e 'DROP DATABASE IF EXISTS lobsters_current; CREATE DATABASE lobsters_current CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;'"

# Load schema + seed (on app server)
sudo -u lobsters bash -c 'cd /srv/lobsters/lobsters-current && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails runner "ActiveRecord::Base.connection.execute(\"SET FOREIGN_KEY_CHECKS=0\"); ActiveRecord::Tasks::DatabaseTasks.load_schema_current" RAILS_ENV=development && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails db:seed RAILS_ENV=development && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails runner /srv/lobsters/seed_production_scale.rb RAILS_ENV=development'
```

**Step 2: Dump MariaDB to TSV and import into SQLite**

Used `dump_mariadb_to_sqlite.sh` which dumps each table from MariaDB to TSV via `mysql --batch`, then calls `import_to_sqlite_fast.rb` for each SQLite version.

The fast import script:
1. Drops all 122 non-autoindex indexes
2. Imports each table via prepared statements with 100k-row transactions
3. Handles binary data (e.g., `confidence_order`) via `SQLite3::Blob`
4. Recreates all indexes
5. Rebuilds FTS indexes

~8 minutes per SQLite version for 7.2M rows.

```bash
sudo -u lobsters bash -c 'cd /srv/lobsters && bash dump_mariadb_to_sqlite.sh'
```

**Step 3: Set test user passwords and restart**

Must use `update_columns` (not `save!`) to bypass Token concern's `after_initialize` callback which generates new tokens and triggers uniqueness validation. BCrypt cost must be 12 (`BCrypt::Engine::DEFAULT_COST`) — Lobsters' login controller detects mismatched cost and re-saves the user.

```bash
cat > /tmp/set_password.rb << 'RUBY'
u = User.find_by(username: ENV["TEST_USER"])
digest = BCrypt::Password.create(ENV["TEST_PASS"], cost: BCrypt::Engine::DEFAULT_COST)
u.update_columns(password_digest: digest)
puts "Password set for user: #{u.username}"
RUBY

for version in lobsters-current lobsters-sqlite lobsters-sqlite-fixed; do
  sudo -u lobsters bash -c "cd /srv/lobsters/$version && \
    TEST_USER=<username> TEST_PASS=<password> \
    PATH=\$HOME/.cargo/bin:\$PATH ~/.rbenv/shims/bundle exec rails runner /tmp/set_password.rb RAILS_ENV=development"
done

systemctl restart lobsters-current lobsters-sqlite lobsters-sqlite-fixed
```

### Important lessons learned during seeding

1. **TSV import works but needs careful binary handling.** MySQL CLI outputs `\N` for NULLs and backslash-escapes special chars (`\n`, `\t`, `\\`). Binary data (e.g., `confidence_order`) contains non-UTF-8 bytes — must wrap in `SQLite3::Blob.new()`. The `import_to_sqlite_fast.rb` script handles all of this correctly.

2. **Drop indexes before bulk SQLite import.** Inserting 7M rows with 122 indexes is ~10x slower than dropping indexes, inserting, then recreating. The fast import script does this automatically.

3. **Counter updates must use JOINs, not correlated subqueries.** Correlated subqueries like `UPDATE stories SET comments_count = (SELECT COUNT(*) ... WHERE cs.id = s.id)` are O(N²). With 120k stories, that's 14.4 billion row checks — runs for hours. JOIN-based UPDATEs complete in seconds. All 14 counter updates take ~136 seconds total with JOINs.

4. **Killing a Ruby process does NOT kill the MariaDB query.** The database query continues running as an orphan. Must `KILL <connection_id>` on MariaDB server directly (`SHOW PROCESSLIST` to find it).

5. **BCrypt cost mismatch breaks Lobsters login.** The login controller detects when `password_digest` uses non-default BCrypt cost, re-saves the user, which triggers Token concern's `after_initialize` uniqueness validation. Always use `BCrypt::Engine::DEFAULT_COST` (12).

6. **Use `update_columns` for password changes.** The Token concern generates new TypeID tokens on `after_initialize`. Using `save!` triggers uniqueness validation. `update_columns` bypasses all callbacks/validations.

7. **Always use `nohup` for remote long-running tasks.** SSH sessions time out.

8. **Ruby 4.0 frozen string literals.** Use `+""` for mutable strings, not `""`.

9. **Shell quoting with Rails runner.** Multi-statement Ruby code with single quotes is nearly impossible to pass via SSH→sudo→bash→rails runner chain. Write a temp `.rb` file on the server instead.

## Repository Map

### Study repo: `eapotapov/lobsters` (this repo)
```
/Users/eapotapov/devel/eapotapov/lobsters/
├── CLAUDE.md              # Project instructions for Claude
├── SETUP.md               # Server setup documentation
├── INVESTIGATION.md       # Root cause analysis (read this first)
├── TIMELINE.md            # Deploy day minute-by-minute timeline
├── PERFORMANCE-TESTING.md # Benchmark summary
├── HANDOFF.md             # This file
├── lobsters-current/      # git submodule → lobsters/lobsters @ main
├── lobsters-sqlite/       # git submodule → lobsters/lobsters @ 74544e96
├── lobsters-sqlite-fixed/ # git submodule → eapotapov/lobsters-sqlite-fix @ sqlite-fix
├── benchmarks/            # Performance test scripts (run on remote server)
│   ├── 01-load-test-story-vs-homepage.sh
│   ├── 02-explain-query-plans.rb
│   └── ...
└── scripts/
    ├── seed_production_scale.rb     # Bulk data generator for MariaDB (with JOIN-based counter updates)
    ├── import_to_sqlite_fast.rb     # Fast SQLite import (drop indexes, bulk insert, recreate)
    ├── update_counters_only.rb      # Standalone counter update script
    ├── dump_mariadb_to_sqlite.sh    # TSV dump + import pipeline (on server)
    ├── setup.sh                     # Legacy single-server setup
    └── benchmark.sh                 # Legacy wrk benchmark suite
```

### Ansible repo: `eapotapov/lobsters-ansible` (branch: `study`)
```
/Users/eapotapov/devel/eapotapov/lobsters-ansible/
├── study.yml                    # Main playbook (4 plays: sysadm, mariadb, lobsters, nginx)
├── ansible.cfg                  # Points to study inventory
├── inventories/study.ini        # db_server + app hosts
├── group_vars/all.yml           # Three version definitions, IPs (NOTE: all.yml not study.yml)
├── roles/
│   ├── sysadm/                  # Base system setup (both servers)
│   ├── mariadb/                 # MariaDB with production 50-server.cnf
│   │   └── files/mysql/mariadb.conf.d/50-server.cnf  # 6GB buffer pool, bind 10.116.0.3
│   ├── lobsters/
│   │   ├── tasks/main.yml           # Creates user, installs Ruby+Rust, loops versions
│   │   ├── tasks/deploy_version.yml # Per-version: clone, bundle, puma service (NO seeding)
│   │   ├── templates/database-trilogy.yml.j2   # MariaDB config (connects to db_host)
│   │   ├── templates/database-sqlite3.yml.j2   # SQLite config
│   │   └── templates/lobsters-puma.service.j2  # Per-version systemd unit (binds 127.0.0.1)
│   └── nginx/
│       └── templates/lobsters-study.conf.j2    # Three reverse proxy blocks by hostname
```

### Fix fork: `eapotapov/lobsters-sqlite-fix` (branch: `sqlite-fix`)
- Two commits on `sqlite-fix` branch:
  1. Revert of revert (re-applies SQLite migration from PR #1871)
  2. `936ccb69` — Fix story_threads query (pre-resolve story IDs + scope outer query)

## The Fix (for reference)

In `app/models/comment.rb`, method `story_threads`:

**Before (broken on SQLite with large data):**
```ruby
# Joins stories table with OR condition — SQLite can't optimize this
join stories on stories.id = c.story_id
where (stories.id = #{story.id} or stories.merged_story_id = #{story.id})
  and parent_comment_id is null
```

**After (fixed):**
```ruby
# Pre-resolve story IDs to avoid JOIN + OR
story_ids = [story.id]
story_ids += Story.where(merged_story_id: story.id).pluck(:id)
# Use IN clause — SQLite can use the story_id index
where c.story_id IN (#{story_ids_sql}) and parent_comment_id is null
# Also scope outer query to help SQLite narrow the final join
Comment.joins(inner_join).where(story_id: story_ids).order(...)
```

## Database Snapshots

Latest snapshots taken 2026-02-26 with all services stopped (suffix `b` = includes mod_activities fix).

| Snapshot | Server | Path | Size |
|---|---|---|---|
| MariaDB datadir | lobsters-db (104.248.63.52) | `/srv/lobsters/snapshots/mariadb-lobsters_current-20260226b.tar.gz` | 550 MB |
| SQLite (PR #1871) | lobsters-app (178.128.147.216) | `/srv/lobsters/snapshots/lobsters-sqlite-20260226b.sqlite3` | 996 MB |
| SQLite (fixed) | lobsters-app (178.128.147.216) | `/srv/lobsters/snapshots/lobsters-sqlite-fixed-20260226b.sqlite3` | 996 MB |

### Restore

```bash
# MariaDB (on lobsters-db)
systemctl stop mariadb
rm -rf /var/lib/mysql/lobsters_current
cd /var/lib/mysql && tar xzf /srv/lobsters/snapshots/mariadb-lobsters_current-20260226b.tar.gz
chown -R mysql:mysql /var/lib/mysql/lobsters_current
systemctl start mariadb

# SQLite (on lobsters-app)
systemctl stop lobsters-sqlite lobsters-sqlite-fixed
cp /srv/lobsters/snapshots/lobsters-sqlite-20260226b.sqlite3 /srv/lobsters/lobsters-sqlite/db/development/primary.sqlite3
cp /srv/lobsters/snapshots/lobsters-sqlite-fixed-20260226b.sqlite3 /srv/lobsters/lobsters-sqlite-fixed/db/development/primary.sqlite3
chown lobsters:lobsters /srv/lobsters/lobsters-sqlite/db/development/primary.sqlite3 /srv/lobsters/lobsters-sqlite-fixed/db/development/primary.sqlite3
systemctl start lobsters-sqlite lobsters-sqlite-fixed
```

## Current Status (as of 2026-02-26)

All three versions are **fully operational** with production-scale data:
- All return HTTPS 200 on all pages
- HTTPS via Let's Encrypt (certbot, auto-renewal)
- robots.txt blocks all crawlers on all three sites
- Test user passwords set on all versions
- Database snapshots taken (suffix `b` includes mod_activities fix)
- Data verified identical across all three via Playwright comparison:
  - Homepage (25 stories: scores, titles, tags, users, comment counts)
  - /recent, /comments pages
  - Multiple story pages with comments
  - User profile page

## Next Steps

1. **Set up k6 performance testing** against all three versions
2. **Write up final benchmark results** comparing MariaDB vs SQLite-broken vs SQLite-fixed
