// Stress test for the homepage: 10 virtual users request / as fast as
// possible for 5 minutes. Measures maximum throughput each version can
// sustain. Unlike production-load.js there is no target arrival rate —
// every VU loops continuously, so there are no "dropped" requests.
//
// Usage:
//   k6 run -e TARGET_URL=https://lobsters-mariadb.eapotapov.dev homepage-single.js

import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;

export const options = {
  vus: 10,
  duration: "5m",
};

export default function () {
  const res = http.get(BASE + "/");
  check(res, { "status 200": (r) => r.status === 200 });
}
