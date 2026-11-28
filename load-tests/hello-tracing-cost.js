// Chi phí tracing của hello (G0-30 bước 11, observability.md "Kiểm chứng": chi phí tracing).
// Tạo lời chào (JWT thật + INSERT qua PgBouncer) với tốc độ cố định, mỗi request mang traceparent cờ SAMPLED:
//   SAMPLED=01: span được sample (sampler parent-based theo bên gọi) → tạo span, exemplar, gửi OTLP tới Collector.
//   SAMPLED=00: không sample → span không ghi, không gửi; chi phí còn lại là đọc header và tạo context.
// Cả hai lần chạy đều gửi traceparent, nên chỉ khác đúng một việc: span có được giữ hay không. Cách này tương đương
// management.tracing.sampling.probability 1.0 và 0.0 cho request không có cha, mà không phải deploy lại pod (JIT, pool
// giữ nguyên giữa các lần đo, chạy xen kẽ được).
//
// Chạy (secret của client smoke-test lấy từ cụm, không ghi ra file):
//   SMOKE_TEST_CLIENT_SECRET="$(kubectl -n keycloak get secret realm-commerce-hub \
//     -o jsonpath='{.data.SMOKE_TEST_CLIENT_SECRET}' | base64 -d)" \
//   k6 run -e SAMPLED=01 -e RATE=50 -e DURATION=120s --summary-export out.json hello-tracing-cost.js
import http from 'k6/http';
import { check } from 'k6';
import crypto from 'k6/crypto';

const BASE = __ENV.BASE || 'https://hello.lab.internal';
const TOKEN_URL = __ENV.TOKEN_URL || 'https://auth.lab.internal/realms/commerce-hub/protocol/openid-connect/token';
const SAMPLED = __ENV.SAMPLED || '01';
if (SAMPLED !== '01' && SAMPLED !== '00') {
  throw new Error('SAMPLED phải là 01 hoặc 00');
}

export const options = {
  // Tốc độ cố định (open model): request đi theo lịch dù server chậm, nên độ trễ không bị che bởi việc k6 chờ.
  scenarios: {
    greetings: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 50),
      timeUnit: '1s',
      duration: __ENV.DURATION || '120s',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

// Token client credentials sống 300 s (Keycloak realm commerce-hub): mỗi lần chạy phải ngắn hơn.
export function setup() {
  const res = http.post(TOKEN_URL, {
    grant_type: 'client_credentials',
    client_id: 'smoke-test',
    client_secret: __ENV.SMOKE_TEST_CLIENT_SECRET,
  });
  if (res.status !== 200) {
    throw new Error(`không lấy được token: HTTP ${res.status}`);
  }
  return { token: res.json('access_token') };
}

export default function (data) {
  // trace-id ngẫu nhiên mỗi request: mỗi request là một trace riêng, như traffic thật.
  const traceparent = `00-${hex(16)}-${hex(8)}-${SAMPLED}`;
  const res = http.post(`${BASE}/v1/greetings`, JSON.stringify({ name: 'k6' }), {
    headers: {
      Authorization: `Bearer ${data.token}`,
      'Content-Type': 'application/json',
      traceparent,
    },
  });
  check(res, { 'tạo được lời chào (201)': (r) => r.status === 201 });
}

// Chuỗi hex ngẫu nhiên n byte (trace-id 16 byte, span-id 8 byte của W3C Trace Context).
function hex(n) {
  const bytes = new Uint8Array(crypto.randomBytes(n));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}
