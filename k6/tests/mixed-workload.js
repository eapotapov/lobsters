import http from "k6/http";
import { check, sleep } from "k6";

const VERSIONS = {
  mariadb: "https://lobsters-mariadb.eapotapov.dev",
  "sqlite-broken": "https://lobsters-1871.eapotapov.dev",
  "sqlite-fixed": "https://lobsters-1927.eapotapov.dev",
};

// Story short IDs — replace with actual short_ids from seeded data.
const STORY_IDS = [
  "wgwbaa", "2szaaa", "6kwbaa", "zxnaaa", "larbaa",
  "86uaaa", "5rgbaa", "oisaaa", "1tzbaa", "phocaa",
];

export const options = {
  scenarios: {
    mariadb: {
      executor: "constant-vus",
      vus: 15,
      duration: "120s",
      exec: "mariadb",
      tags: { version: "mariadb" },
    },
    sqlite_broken: {
      executor: "constant-vus",
      vus: 15,
      duration: "120s",
      exec: "sqliteBroken",
      tags: { version: "sqlite-broken" },
    },
    sqlite_fixed: {
      executor: "constant-vus",
      vus: 15,
      duration: "120s",
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

function pickEndpoint(base) {
  const roll = Math.random();
  if (roll < 0.5) {
    // 50% homepage
    return `${base}/`;
  } else if (roll < 0.8) {
    // 30% story page
    const id = STORY_IDS[Math.floor(Math.random() * STORY_IDS.length)];
    return `${base}/s/${id}`;
  } else {
    // 20% comments
    return `${base}/comments`;
  }
}

function mixedLoad(base) {
  const url = pickEndpoint(base);
  const res = http.get(url);
  check(res, { "status 200": (r) => r.status === 200 });
  sleep(1);
}

export function mariadb() {
  mixedLoad(VERSIONS.mariadb);
}

export function sqliteBroken() {
  mixedLoad(VERSIONS["sqlite-broken"]);
}

export function sqliteFixed() {
  mixedLoad(VERSIONS["sqlite-fixed"]);
}
