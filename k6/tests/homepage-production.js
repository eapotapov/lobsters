// Production load test for the homepage: sends exactly 20 req/s using
// constant-arrival-rate executor. Measures response times and dropped
// requests under a fixed load that matches real Lobsters traffic (15-25 req/s).
//
// Usage:
//   k6 run -e TARGET_URL=https://lobsters-mariadb.eapotapov.dev -e DURATION=1m homepage-production.js

import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;
const DURATION = __ENV.DURATION || "5m";

export const options = {
  scenarios: {
    production: {
      executor: "constant-arrival-rate",
      rate: 20,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 10,
      maxVUs: 50,
    },
  },
};

export default function () {
  const res = http.get(BASE + "/");
  check(res, { "status 200": (r) => r.status === 200 });
}
