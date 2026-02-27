# k6 Performance Testing

Load tests comparing all three Lobsters versions side-by-side using [k6](https://grafana.com/docs/k6/).

## Infrastructure

| Server | IP | Spec |
|---|---|---|
| `lobsters-k6` | 68.183.105.136 | s-4vcpu-8gb, nyc1, Ubuntu 24.04 |

Dashboard: `https://lobsters-k6.eapotapov.dev` (basic auth)

## Test Scripts

| Script | Endpoints | Duration | VUs/version |
|---|---|---|---|
| `homepage.js` | `/` | 60s | 10 |
| `story-page.js` | `/s/:id` (10 random stories) | 60s | 10 |
| `comments.js` | `/comments` | 60s | 10 |
| `mixed-workload.js` | 50% `/`, 30% `/s/:id`, 20% `/comments` | 120s | 15 |

Each script runs the same workload against all three versions simultaneously, tagged by version (`mariadb`, `sqlite-broken`, `sqlite-fixed`).

## Running Tests

SSH into the k6 server and run with the web dashboard:

```bash
ssh root@68.183.105.136

# Run a test with live dashboard
k6 run --out web-dashboard /srv/k6/tests/homepage.js

# View dashboard at https://lobsters-k6.eapotapov.dev
```

To update test scripts after editing locally:

```bash
scp k6/tests/*.js root@68.183.105.136:/srv/k6/tests/
```

## Provisioning

```bash
cd k6/ansible
K6_HTPASSWD_PASS=<password> ansible-playbook -i inventory.ini playbook.yml
```

First run: use `--skip-tags certbot`, set up DNS, then run again with `--tags certbot`.

## Targets

| Version | URL |
|---|---|
| MariaDB (current) | https://lobsters-mariadb.eapotapov.dev |
| SQLite (PR #1871) | https://lobsters-1871.eapotapov.dev |
| SQLite (fixed) | https://lobsters-1927.eapotapov.dev |
