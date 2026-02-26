# Lobsters SQLite Migration Study - Server Setup

## Overview

Three versions of the [Lobsters](https://github.com/lobsters/lobsters) codebase are deployed side-by-side to study the attempted migration from MariaDB to SQLite and its subsequent revert. See PR [#1871](https://github.com/lobsters/lobsters/pull/1871) (migration) and PR [#1924](https://github.com/lobsters/lobsters/pull/1924) (revert).

## Production-Faithful Setup (DigitalOcean) — PROVISIONED

Two-server deployment matching production Lobsters infrastructure. Provisioned via ansible.

**Current status:** All services running. Databases fully seeded with production-scale data (~7.2M rows). All versions return HTTP 200.

### Servers

| Droplet | Public IP | Private IP | Spec | Role |
|---|---|---|---|---|
| `lobsters-app` | 178.128.147.216 | 10.116.0.2 | s-4vcpu-8gb, nyc1 | App server: 3x Puma, nginx |
| `lobsters-db` | 104.248.63.52 | 10.116.0.3 | s-4vcpu-8gb, nyc1 | MariaDB with production config |

DigitalOcean context: `doctl2 --context apexdata`

### Three Versions

| # | Name | Commit | DB | Port | Hostname |
|---|------|--------|----|------|----------|
| 1 | `lobsters-current` | `9b736939` (main HEAD) | MariaDB on lobsters-db | 3001 | lobsters-mariadb.eapotapov.dev |
| 2 | `lobsters-sqlite` | `74544e96` (PR #1871) | SQLite (local) | 3002 | lobsters-1871.eapotapov.dev |
| 3 | `lobsters-sqlite-fixed` | `936ccb69` (fork) | SQLite (local, fixed) | 3003 | lobsters-1927.eapotapov.dev |

### Architecture

```
                              ┌─────────────────────────────┐
                              │     lobsters-db             │
                              │     104.248.63.52           │
                              │     (10.116.0.3)            │
                              │                             │
                              │  MariaDB                    │
                              │  innodb_buffer_pool = 6GB   │
                              │  bind 10.116.0.3 (private)  │
                              └──────────┬──────────────────┘
                                         │ private network
┌────────────────────────────────────────┼──────────────────────┐
│  lobsters-app  178.128.147.216  (10.116.0.2)                 │
│                                        │                     │
│  nginx :443 ─┬── Puma :3001 ──────────►│ MariaDB (trilogy)   │
│  (TLS/LE)    ├── Puma :3002 ── SQLite (local file)          │
│              └── Puma :3003 ── SQLite (local, fixed query)   │
│              (all Puma on 127.0.0.1)                         │
└──────────────────────────────────────────────────────────────┘
```

### Security

- MariaDB binds to `10.116.0.3` (private network only) — not accessible from internet
- Puma services bind to `127.0.0.1` — only accessible via nginx
- Publicly accessible: SSH (22), HTTP (80, redirects to HTTPS), HTTPS (443)
- Let's Encrypt TLS via certbot (nginx plugin), auto-renewal configured
- robots.txt on all three sites: `Disallow: /`

### Provisioning

```bash
cd /Users/eapotapov/devel/eapotapov/lobsters-ansible
git checkout study
ansible-playbook study.yml
```

The ansible playbook (does NOT include seeding):
1. Installs base system packages on both servers
2. Installs MariaDB on `lobsters-db` with the exact production config (6 GB InnoDB buffer pool)
3. Creates the `lobsters` database user accessible from the app server's private IP
4. Installs Ruby 4.0.0 via rbenv on `lobsters-app` (with YJIT)
5. Installs Rust via rustup (needed for commonmarker gem, Ubuntu's rustc 1.75 is too old)
6. Clones all three versions at their pinned commits
7. Runs `bundle install` for each version
8. Sets up systemd services for each Puma instance
9. Configures nginx reverse proxy

Seeding (`db:setup`, `fake_data`, test user creation) is handled separately — not part of the playbook.

### App Server Layout

```
/srv/lobsters/
├── .rbenv/                    # Ruby 4.0.0 with YJIT
├── .cargo/                    # Rust toolchain (via rustup)
├── lobsters-current/          # MariaDB version (port 3001)
├── lobsters-sqlite/           # SQLite as-deployed (port 3002)
└── lobsters-sqlite-fixed/     # SQLite with fix (port 3003)
```

Each version has its own systemd service (`lobsters-current`, `lobsters-sqlite`, `lobsters-sqlite-fixed`).

### MariaDB Configuration (from production)

Key settings in `50-server.cnf`:
- `innodb_buffer_pool_size = 6G` (75% of 8 GB RAM)
- `max_connections = 257` (36 workers x 7 pool + 5)
- `query_cache_size = 16M`
- `character-set-server = utf8mb4`
- `bind-address = 10.116.0.3` (private network only)

### /etc/hosts for local testing

```
178.128.147.216 lobsters-mariadb.eapotapov.dev lobsters-1871.eapotapov.dev lobsters-1927.eapotapov.dev
```

### Test Account (after seeding)

See `CLAUDE.md` seeding pipeline for how the test user password is set. BCrypt cost must be 12 (`BCrypt::Engine::DEFAULT_COST`) or login will fail due to re-save triggering token uniqueness validation.

---

## Legacy Single-Server Setup (eapotapov-ubuntu)

The original study environment. Single server running all three versions with MySQL 8.0 (not MariaDB). This setup was used for the initial investigation and benchmarks documented in `INVESTIGATION.md`.

- **Host:** `ssh eapotapov@eapotapov-ubuntu`
- **OS:** Ubuntu 24.04.3 LTS

| # | Directory | Commit | DB | Port | Domain |
|---|-----------|--------|----|------|--------|
| 1 | `~/lobsters/1-before-sqlite` | `f5f98d6e` | MySQL `lobsters_before` | 3001 | `lobsters-before` |
| 2 | `~/lobsters/2-after-sqlite` | `74544e96` | SQLite | 3002 | `lobsters-after` |
| 3 | `~/lobsters/3-after-revert` | `fce8b853` | MySQL `lobsters_revert` | 3003 | `lobsters-revert` |

Services: systemd user services (`lobsters-before`, `lobsters-after`, `lobsters-after-revert`)
Setup scripts: `scripts/setup.sh` and related files in `scripts/`
