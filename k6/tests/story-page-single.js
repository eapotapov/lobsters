import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.TARGET_URL;
const STORY_IDS = [
  "wgwbaa", "2szaaa", "6kwbaa", "zxnaaa", "larbaa",
  "86uaaa", "5rgbaa", "oisaaa", "1tzbaa", "phocaa",
];

export const options = {
  vus: 10,
  duration: "5m",
};

export default function () {
  const id = STORY_IDS[Math.floor(Math.random() * STORY_IDS.length)];
  const res = http.get(BASE + "/s/" + id);
  check(res, { "status 200": (r) => r.status === 200 });
  sleep(0.5);
}
