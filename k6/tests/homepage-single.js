// Stress test for the homepage: VUs request / as fast as possible.
// Measures maximum throughput each version can sustain. Unlike
// production-load.js there is no target arrival rate — every VU
// loops continuously, so there are no "dropped" requests.
//
// Usage:
//   k6 run --vus 10 --duration 5m -e TARGET_URL=https://lobsters-mariadb.eapotapov.dev homepage-single.js

import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;

export default function () {
  const res = http.get(BASE + "/");
  check(res, { "status 200": (r) => r.status === 200 });
}
