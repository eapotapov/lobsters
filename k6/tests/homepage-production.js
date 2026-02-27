// Production load test for the homepage: sends exactly 20 req/s for 5 minutes
// using constant-arrival-rate executor. Measures response times and dropped
// requests under a fixed load that matches real Lobsters traffic (15-25 req/s).
//
// Usage:
//   k6 run -e TARGET_URL=https://lobsters-mariadb.eapotapov.dev homepage-production.js

import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;

export const options = {
  scenarios: {
    production: {
      executor: "constant-arrival-rate",
      rate: 20,
      timeUnit: "1s",
      duration: "5m",
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
  },
};

export default function () {
  const res = http.get(BASE + "/");
  check(res, { "status 200": (r) => r.status === 200 });
}
