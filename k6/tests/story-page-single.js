// Stress test for story pages: VUs request random /s/:id pages as fast
// as possible. Measures maximum throughput each version can sustain.
// Unlike production-load.js there is no target arrival rate — every VU
// loops continuously, so there are no "dropped" requests.
//
// Usage:
//   k6 run --vus 10 --duration 5m -e TARGET_URL=https://lobsters-mariadb.eapotapov.dev story-page-single.js

import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;
const STORY_IDS = [
  "wgwbaa", "2szaaa", "6kwbaa", "zxnaaa", "larbaa",
  "86uaaa", "5rgbaa", "oisaaa", "1tzbaa", "phocaa",
];

export default function () {
  const id = STORY_IDS[Math.floor(Math.random() * STORY_IDS.length)];
  const res = http.get(BASE + "/s/" + id);
  check(res, { "status 200": (r) => r.status === 200 });
}
