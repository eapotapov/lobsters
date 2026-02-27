import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.TARGET_URL;
const ENDPOINT = __ENV.ENDPOINT || "/";
const STORY_IDS = [
  "wgwbaa", "2szaaa", "6kwbaa", "zxnaaa", "larbaa",
  "86uaaa", "5rgbaa", "oisaaa", "1tzbaa", "phocaa",
];

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
  let url = BASE + ENDPOINT;
  if (ENDPOINT === "/s/") {
    const id = STORY_IDS[Math.floor(Math.random() * STORY_IDS.length)];
    url = BASE + "/s/" + id;
  }
  const res = http.get(url);
  check(res, { "status 200": (r) => r.status === 200 });
}
