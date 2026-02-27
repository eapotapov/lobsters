import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.TARGET_URL;

export const options = {
  vus: 10,
  duration: "5m",
};

export default function () {
  const res = http.get(BASE + "/");
  check(res, { "status 200": (r) => r.status === 200 });
  sleep(0.5);
}
