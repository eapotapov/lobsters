# Project: Lobsters SQLite Migration Study

A study of the Lobsters (lobste.rs) attempted MySQL/MariaDB-to-SQLite migration and its revert, with root cause analysis, performance benchmarks, and a verified fix.

## Key Context

- **PRs under study:** [#1871](https://github.com/lobsters/lobsters/pull/1871) (SQLite migration), [#1924](https://github.com/lobsters/lobsters/pull/1924) (revert), [#1927](https://github.com/lobsters/lobsters/pull/1927) (re-attempt, open)
- **Upstream repo:** https://github.com/lobsters/lobsters
- **Ansible repo:** https://github.com/eapotapov/lobsters-ansible (branch: `study`)
- **Fix fork:** https://github.com/eapotapov/lobsters-sqlite-fix (branch: `sqlite-fix`)
- **Investigation:** See `INVESTIGATION.md`, `TIMELINE.md`, `PERFORMANCE-TESTING.md`

## Current State

Infrastructure is **fully provisioned** on two DigitalOcean droplets. All three app versions are running and **databases are fully seeded** with production-scale data (~7.2M rows). All three versions return HTTP 200.

**Data in each database:**
- 5,000 users, 120,000 stories, 675,000 comments, 4,000,000 votes
- ~7.2M total rows
- MariaDB datadir: ~2.3 GB (550 MB compressed), SQLite: ~996 MB each

## Local Submodules

Three versions of the Lobsters codebase as git submodules:

| Directory | Source | Commit | Purpose |
|---|---|---|---|
| `lobsters-current/` | [lobsters/lobsters](https://github.com/lobsters/lobsters) | `9b736939` (main) | Current production (MariaDB) |
| `lobsters-sqlite/` | [lobsters/lobsters](https://github.com/lobsters/lobsters) | `74544e96` (PR #1871) | SQLite migration as-deployed |
| `lobsters-sqlite-fixed/` | [eapotapov/lobsters-sqlite-fix](https://github.com/eapotapov/lobsters-sqlite-fix) | `936ccb69` (sqlite-fix) | SQLite with story_threads query fix |

Clone with submodules: `git clone --recurse-submodules`

## Infrastructure

### Production-faithful deployment (PROVISIONED + SEEDED)

Two DigitalOcean droplets matching production Lobsters specs:

| Droplet | IP | Private IP | Role | Spec |
|---|---|---|---|---|
| `lobsters-app` | 178.128.147.216 | 10.116.0.2 | App server (3x Puma, nginx) | s-4vcpu-8gb, nyc1 |
| `lobsters-db` | 104.248.63.52 | 10.116.0.3 | MariaDB server | s-4vcpu-8gb, nyc1 |

DigitalOcean context: `doctl2 --context apexdata`

### Services running on lobsters-app

| Service | Port | Bind | DB | Hostname |
|---|---|---|---|---|
| `lobsters-current` | 3001 | 127.0.0.1 | MariaDB on lobsters-db | lobsters-mariadb.eapotapov.dev |
| `lobsters-sqlite` | 3002 | 127.0.0.1 | SQLite (local) | lobsters-1871.eapotapov.dev |
| `lobsters-sqlite-fixed` | 3003 | 127.0.0.1 | SQLite (local, fixed) | lobsters-1927.eapotapov.dev |
| nginx | 80 | 0.0.0.0 | — | routes by Host header |

MariaDB on lobsters-db binds to `10.116.0.3` (private network only).

**Note:** `.dev` TLD requires HTTPS (HSTS preloaded). Let's Encrypt certs are configured via nginx.

### /etc/hosts entry (only if DNS not yet propagated)

```
178.128.147.216 lobsters-mariadb.eapotapov.dev lobsters-1871.eapotapov.dev lobsters-1927.eapotapov.dev
```

### Legacy single-server setup (previous study)

| Server | Details |
|---|---|
| `eapotapov-ubuntu` | Single server with all 3 versions (MySQL 8.0, ports 3001-3003) |

See `SETUP.md` for the legacy setup details.

## Seeding

Data was seeded into MariaDB using a custom bulk-insert Ruby script, then transferred to both SQLite versions via TSV dump + fast import. This ensures all three databases contain **identical data**.

### Seeding pipeline

1. **Reset MariaDB:** Drop and recreate `lobsters_current` database (must run as root on db server since FK constraints block `db:schema:load`)
2. **MariaDB schema + seeds:** `SET FOREIGN_KEY_CHECKS=0` + `rails db:schema:load` + `rails db:seed` on `lobsters-current`
3. **Production-scale data:** `scripts/seed_production_scale.rb` generates bulk data via raw SQL INSERTs into MariaDB (5k users, 120k stories, 675k comments, 4M votes, etc.) and updates all counter caches via JOIN-based UPDATEs
4. **Dump from MariaDB to TSV:** `dump_mariadb_to_sqlite.sh` dumps each table to TSV via `mysql --batch`
5. **Import TSV into SQLite:** `import_to_sqlite_fast.rb` drops all 122 indexes, bulk-inserts via prepared statements, recreates indexes, rebuilds FTS (~8 min per version)
6. **Set test user password:** `rails runner` with `update_columns` to bypass Token callbacks, using `BCrypt::Engine::DEFAULT_COST` (12). Username and password are not stored in docs — check with the project owner.
7. **Restart services:** `systemctl restart lobsters-current lobsters-sqlite lobsters-sqlite-fixed`

### Key files on the server

| Path | Purpose |
|---|---|
| `/srv/lobsters/seed_production_scale.rb` | Production-scale data generator (MariaDB) |
| `/srv/lobsters/dump_mariadb_to_sqlite.sh` | Dumps MariaDB tables to TSV + calls fast import |
| `/srv/lobsters/import_to_sqlite_fast.rb` | Fast SQLite import: drops indexes, bulk insert, recreates indexes |
| `/srv/lobsters/update_counters_only.rb` | Standalone counter update script (for re-running counters without re-seeding) |
| `/srv/lobsters/snapshots/` (on lobsters-app) | SQLite database snapshots |
| `/srv/lobsters/snapshots/` (on lobsters-db) | MariaDB datadir snapshot |

### Fast restore from snapshots

See `HANDOFF.md` § "Database Snapshots" for restore commands. Faster than re-seeding (~seconds vs ~2 hours).

### Re-seeding from scratch

```bash
# 1. Reset MariaDB (on db server, as root — lobsters user may lack DROP privilege)
ssh root@104.248.63.52 "mysql -u root -e 'DROP DATABASE IF EXISTS lobsters_current; CREATE DATABASE lobsters_current CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;'"

# 2. Load schema (needs FK_CHECKS=0) and seed
ssh root@178.128.147.216
sudo -u lobsters bash -c 'cd /srv/lobsters/lobsters-current && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails runner "ActiveRecord::Base.connection.execute(\"SET FOREIGN_KEY_CHECKS=0\"); ActiveRecord::Tasks::DatabaseTasks.load_schema_current" RAILS_ENV=development && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails db:seed RAILS_ENV=development && \
  PATH=$HOME/.cargo/bin:$PATH ~/.rbenv/shims/bundle exec rails runner /srv/lobsters/seed_production_scale.rb RAILS_ENV=development'

# 3. Dump MariaDB and import into both SQLite versions (~8 min each)
sudo -u lobsters bash -c 'cd /srv/lobsters && bash dump_mariadb_to_sqlite.sh'

# 4. Set test user password on all three versions
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

# 5. Restart services
systemctl restart lobsters-current lobsters-sqlite lobsters-sqlite-fixed
```

### Seeding gotchas

- **Ruby 4.0 frozen strings:** Use `+""` for mutable strings (e.g., `result = +""`), not `result = ""`
- **MariaDB FK constraint errors on schema:load:** Must `SET FOREIGN_KEY_CHECKS=0` before loading schema, or drop/create database from db server as root
- **Counter updates must use JOINs, not correlated subqueries:** Correlated subqueries are O(N²) on 120k stories — the `comments_count` update would run for hours. JOIN-based UPDATEs complete in seconds. See `update_counters_only.rb` for the optimized versions.
- **Killing a Ruby process does NOT kill the MariaDB query:** Must `KILL <connection_id>` on MariaDB server directly
- **BCrypt cost mismatch breaks login:** Lobsters' login controller detects non-default BCrypt cost and re-saves user, triggering Token uniqueness validation. Always use `BCrypt::Engine::DEFAULT_COST` (12).
- **Token concern's `after_initialize` generates new tokens:** Using `save!` on a loaded User triggers uniqueness validation against existing tokens. Use `update_columns` to bypass all callbacks/validations.
- **SQLite binary data:** `confidence_order` column contains non-UTF-8 bytes. Must wrap in `SQLite3::Blob.new()` when importing.
- **nohup for long-running tasks:** SSH sessions time out. Always use `nohup ... &` for seeds/imports

## Common Operations

```bash
# SSH to droplets
ssh root@178.128.147.216    # lobsters-app
ssh root@104.248.63.52      # lobsters-db

# Check services
ssh root@178.128.147.216 'systemctl status lobsters-current lobsters-sqlite lobsters-sqlite-fixed nginx'

# Test all three versions
for host in lobsters-mariadb.eapotapov.dev lobsters-1871.eapotapov.dev lobsters-1927.eapotapov.dev; do
  curl -s -o /dev/null -w "$host: HTTP %{http_code}\n" http://$host/
done

# Re-run ansible provisioning
cd ../lobsters-ansible && ansible-playbook study.yml

# App code is at /srv/lobsters/{lobsters-current,lobsters-sqlite,lobsters-sqlite-fixed}
# Run Rails commands as lobsters user:
ssh root@178.128.147.216
su - lobsters
cd /srv/lobsters/lobsters-current
~/.rbenv/shims/bundle exec rails console

# Check row counts
ssh root@178.128.147.216 "mysql -h 10.116.0.3 -u lobsters -plobsters -e 'SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM stories; SELECT COUNT(*) FROM comments; SELECT COUNT(*) FROM votes' lobsters_current 2>/dev/null"
```

## Directory Layout

```
.
├── CLAUDE.md                  # This file
├── SETUP.md                   # Server setup docs (both new and legacy)
├── INVESTIGATION.md           # Root cause analysis
├── TIMELINE.md                # Deploy day timeline
├── PERFORMANCE-TESTING.md     # Benchmark results summary
├── HANDOFF.md                 # Full context for session continuity
├── lobsters-current/          # Submodule: upstream main (MariaDB)
├── lobsters-sqlite/           # Submodule: PR #1871 (SQLite, broken)
├── lobsters-sqlite-fixed/     # Submodule: fork with query fix
├── benchmarks/                # Performance test scripts
│   ├── 01-load-test-*.sh      # wrk load tests
│   ├── 02-explain-*.rb        # Query plan analysis
│   └── ...
└── scripts/                   # Seeding and server scripts
    ├── seed_production_scale.rb     # Bulk data generator for MariaDB (with JOIN-based counter updates)
    ├── import_to_sqlite_fast.rb     # Fast SQLite import (drop indexes, bulk insert, recreate)
    ├── update_counters_only.rb      # Standalone counter update script
    ├── dump_mariadb_to_sqlite.sh    # TSV dump + import pipeline (on server)
    ├── setup.sh                     # Legacy single-server setup
    ├── benchmark.sh                 # Legacy wrk benchmark suite
    └── ...
```
