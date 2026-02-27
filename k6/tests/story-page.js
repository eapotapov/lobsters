import http from "k6/http";
import { check, sleep } from "k6";
const VERSIONS = {
  mariadb: "https://lobsters-mariadb.eapotapov.dev",
  "sqlite-broken": "https://lobsters-1871.eapotapov.dev",
  "sqlite-fixed": "https://lobsters-1927.eapotapov.dev",
};

// Story short IDs to test — these should exist in all three databases.
// Replace with actual short_ids from your seeded data.
const STORY_IDS = [
  "wgwbaa", "2szaaa", "6kwbaa", "zxnaaa", "larbaa",
  "86uaaa", "5rgbaa", "oisaaa", "1tzbaa", "phocaa",
];

export const options = {
  scenarios: {
    mariadb: {
      executor: "constant-vus",
      vus: 10,
      duration: "60s",
      exec: "mariadb",
      tags: { version: "mariadb" },
    },
    sqlite_broken: {
      executor: "constant-vus",
      vus: 10,
      duration: "60s",
      exec: "sqliteBroken",
      tags: { version: "sqlite-broken" },
    },
    sqlite_fixed: {
      executor: "constant-vus",
      vus: 10,
      duration: "60s",
      exec: "sqliteFixed",
      tags: { version: "sqlite-fixed" },
    },
  },
  thresholds: {
    "http_req_duration{version:mariadb}": ["p(95)<2000"],
    "http_req_duration{version:sqlite-broken}": ["p(95)<10000"],
    "http_req_duration{version:sqlite-fixed}": ["p(95)<2000"],
  },
};

function hitStoryPage(base) {
  const id = STORY_IDS[Math.floor(Math.random() * STORY_IDS.length)];
  const res = http.get(`${base}/s/${id}`);
  check(res, { "status 200": (r) => r.status === 200 });
  sleep(1);
}

export function mariadb() {
  hitStoryPage(VERSIONS.mariadb);
}

export function sqliteBroken() {
  hitStoryPage(VERSIONS["sqlite-broken"]);
}

export function sqliteFixed() {
  hitStoryPage(VERSIONS["sqlite-fixed"]);
}
