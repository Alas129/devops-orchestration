// k6 script for zero-downtime evidence.
//
// Run during deploys, AMI rotations, or schema migrations and confirm that
// http_req_failed is 0.00% in the final summary.
//
//   k6 run -e BASE_URL=https://app.uat.example.com tools/load-test/k6-zero-downtime.js
//   # or with an env-specific stage profile:
//   k6 run -e BASE_URL=... -e DURATION=10m -e VUS=50 tools/load-test/k6-zero-downtime.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const baseUrl = __ENV.BASE_URL || 'https://app.dev.example.com';
const duration = __ENV.DURATION || '5m';
const vus = parseInt(__ENV.VUS || '20', 10);

const dropped = new Counter('dropped_requests');

export const options = {
  scenarios: {
    constant_load: {
      executor: 'constant-vus',
      vus,
      duration,
    },
  },
  thresholds: {
    // Hard fail the run if any non-2xx slipped through.
    http_req_failed: ['rate==0'],
    // Soft latency bound — adjust to taste.
    http_req_duration: ['p(95)<800'],
  },
};

export default function () {
  const homepage = http.get(`${baseUrl}/`);
  const health = http.get(`${baseUrl}/api/healthz`);
  const apiHealth = http.get(`${baseUrl}/api/auth/me`, {
    // Unauthenticated, expect 401 — but never 5xx.
    headers: { Authorization: 'Bearer x' },
  });

  const ok = check(homepage, {
    'home 200': (r) => r.status === 200,
  }) && check(health, {
    'health 200': (r) => r.status === 200,
  }) && check(apiHealth, {
    'api reachable, no 5xx': (r) => r.status < 500,
  });

  if (!ok) dropped.add(1);

  sleep(1);
}

export function handleSummary(data) {
  return {
    stdout: JSON.stringify(data, null, 2),
    'k6-summary.json': JSON.stringify(data),
  };
}
