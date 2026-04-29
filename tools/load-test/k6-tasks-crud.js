// Authenticated CRUD load — exercises auth-svc + tasks-svc + notifier-svc.
// Useful during canary so the AnalysisTemplate has real traffic to evaluate.
//
//   k6 run -e BASE_URL=https://app.uat.example.com tools/load-test/k6-tasks-crud.js

import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || 'https://app.dev.example.com';

export const options = {
  vus: 10,
  duration: __ENV.DURATION || '5m',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<800'],
  },
};

function rand(n) {
  return Math.random().toString(36).slice(2, 2 + n);
}

export default function () {
  const email = `k6-${rand(8)}@example.com`;
  const password = `pw-${rand(12)}`;

  const signup = http.post(`${baseUrl}/api/auth/signup`,
    JSON.stringify({ email, password }),
    { headers: { 'Content-Type': 'application/json' } });
  check(signup, { 'signup ok': (r) => r.status === 200 });

  const token = JSON.parse(signup.body || '{}').token;
  if (!token) return;
  const auth = { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } };

  const create = http.post(`${baseUrl}/api/tasks/tasks`,
    JSON.stringify({ name: `task-${rand(6)}` }), auth);
  check(create, { 'create task 201': (r) => r.status === 201 });

  const list = http.get(`${baseUrl}/api/tasks/tasks`, auth);
  check(list, { 'list 200': (r) => r.status === 200 });

  const t = JSON.parse(create.body || '{}');
  if (t && t.id) {
    const upd = http.patch(`${baseUrl}/api/tasks/tasks/${t.id}`,
      JSON.stringify({ done: true }), auth);
    check(upd, { 'patch 200': (r) => r.status === 200 });
  }

  sleep(0.5);
}
