# platform/compose: vòng dev trên Mac

Hạ tầng chạy trên Docker Desktop để code một service trên Mac mà không đụng tới lab. Service chạy trên host bằng Spring profile `local` (image service chỉ có `linux/amd64`, không chạy trong compose). Thiết kế: ticket 13 của map kiến trúc (`docs/.scratch/architecture-g0-g1/issues/13-dev-loop.md`, repo `docs`); làm ở ticket G0-32.

| Service | Image | Cổng trên host | Giống lab ở chỗ |
|---|---|---|---|
| `postgres` | `postgres:18.7` | 15432 | Cùng 18.7; database và role của từng service như CR `DatabaseRole`/`Database`; `pg_hba` reject mọi cặp role–database không khai |
| `pgbouncer` | `cloudnative-pg/pgbouncer:1.25.2` | 16432 | Cùng image, digest; `transaction`, `default_pool_size 8` như Pooler |
| `keycloak` | `keycloak:26.8.2` | 18080 | Cùng image, digest; `start` (không `start-dev`), DB PostgreSQL, memory 1536 MiB |
| `keycloak-config` | `keycloak-config-cli:6.6.0-26.8.1` | – | Áp **chính** `gitops/infra/keycloak/realm/commerce-hub.yaml`, cùng biến `IMPORT_*` của Job lab |
| `kafka` | `apache/kafka:4.3.2` | 19092 | Bản broker dự kiến của lab (Strimzi, G1); không tự tạo topic |
| `kafka-topics-plan`, `kafka-topics` | `mikefarah/yq`, `apache/kafka` | – | Tạo topic từ CR `KafkaTopic` trong gitops (G0 chưa có topic nào) |
| `lgtm` (profile `obs`) | `grafana/otel-lgtm:0.41.2` | 3000, 4317, 4318 | Grafana, Tempo, Loki, Prometheus như stack quan sát của lab, gộp một container |

Cổng host dải 1xxxx để không trùng `kubectl port-forward` tới lab (pg-main 5432, Keycloak admin 8180). Trùng cổng thì service trên Mac có thể nối nhầm vào lab. Mọi cổng chỉ nghe `127.0.0.1`.

## Lệch ADR-0001, chỉ ở dev

[ADR-0001](https://github.com/hoangduoc0603/commerce-hub-docs/blob/main/adr/0001-polyrepo.md) nói repo chỉ nối nhau qua artifact có version và runtime. Compose thì đọc thẳng **bản checkout `gitops` nằm cạnh** (`GITOPS_DIR`, mặc định `../../gitops`) lúc chạy: realm Keycloak và CR `KafkaTopic`.

Lý do: mục tiêu là dev giống lab với **một** nguồn cấu hình. Cách còn lại là chép realm và danh sách topic vào `platform`, và bản chép sẽ trôi khỏi `gitops` mà không ai biết. Lệch chỉ ở dev: không image, chart hay workflow nào phụ thuộc vào checkout này. Version image không đọc được từ gitops theo cách đó (compose cần tag cố định), nên job [`compose-image-drift`](../.github/workflows/compose-image-drift.yml) so major.minor hằng ngày và đỏ khi lệch.

## Dùng

Cần: Docker Desktop (VM ≥ 4 GB), repo `gitops` clone cạnh `platform`.

```bash
cp .env.example .env
```

```bash
docker compose up -d && docker compose wait keycloak-config kafka-topics
```

`wait` chờ hai init chạy xong; một init lỗi thì lệnh thoát khác 0, xem `docker compose logs keycloak-config`. Không dùng `up --wait`: nó coi init đã thoát (dù mã 0) là lỗi và trả 1. Lần đầu khoảng 30 s khi đã có image.

Chạy service, ví dụ `hello` (repo `services/hello`). Migrate trước, một lần sau mỗi `down -v` hoặc khi có migration mới:

```bash
./gradlew bootRun --args='--spring.profiles.active=local,migrate'
```

```bash
./gradlew bootRun --args='--spring.profiles.active=local'
```

Như lab ([ADR-0020](https://github.com/hoangduoc0603/commerce-hub-docs/blob/main/adr/0020-migrations-run-as-argocd-presync-job.md)): profile `migrate` chạy Flyway bằng role `_migrator` nối thẳng `postgres` rồi JVM thoát (thay cho Job `PreSync`), runtime không migrate và chỉ đi qua `pgbouncer` bằng role `_app`. Quên migrate thì runtime vẫn lên, nhưng request ghi DB trả 500 (`relation "greeting" does not exist`).

### Thử hello

```bash
TOKEN=$(curl -s -d grant_type=client_credentials -d client_id=smoke-test -d client_secret=smoke-test-local-secret http://localhost:18080/realms/commerce-hub/protocol/openid-connect/token | jq -r .access_token)
```

```bash
curl -i -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Mac"}' http://localhost:8080/v1/greetings
```

`client_secret` là `SMOKE_TEST_CLIENT_SECRET` trong `.env`; đổi ở đó thì đổi cả lệnh trên. Đọc lại bằng `curl -H "Authorization: Bearer $TOKEN" http://localhost:8080<Location>`.

### Xem trace (profile `obs`)

```bash
docker compose --profile obs up -d
```

```bash
./gradlew bootRun --args='--spring.profiles.active=local,obs'
```

Grafana ở <http://localhost:3000> (ẩn danh, quyền admin), Explore → Tempo → tìm theo `service.name = hello`. Không bật Spring profile `obs` thì service không gửi span (exporter tắt), vẫn chạy bình thường.

### Thao tác khác

| Việc | Lệnh |
|---|---|
| Áp lại realm sau khi sửa file trong gitops | `docker compose up keycloak-config` |
| Admin Console | <http://localhost:18080/admin>, user `admin`, mật khẩu `KC_BOOTSTRAP_ADMIN_PASSWORD` |
| psql | `psql -h localhost -p 15432 -U postgres` |
| Dừng, giữ dữ liệu | `docker compose --profile obs stop` |
| Reset sạch (xóa container, network, volume) | `docker compose --profile obs down -v` |

Reset phải có `--profile obs`: `down` chỉ gỡ service của profile đang bật, nên thiếu cờ thì container `lgtm` còn chạy (đã thử). Không bật `obs` thì thêm cờ cũng không sao.

## Thêm một service (G1)

1. `postgres/initdb/<số>-<service>.sql` theo mẫu `20-hello.sql`, chép từ CR của service trong `gitops/infra/pg-main/`.
2. Một dòng ở `pgbouncer/pgbouncer.ini` (`[databases]`), `pgbouncer/userlist.txt`, `postgres/pg_hba.conf`.
3. `docker compose --profile obs down -v`, rồi `up`: script initdb chỉ chạy khi volume rỗng.

## Chỗ lệch lab

Ghi chi tiết tại chỗ trong từng file. Tóm tắt:

- Không TLS ở PostgreSQL, PgBouncer, Keycloak, Kafka. Kafka không xác thực.
- PgBouncer xác thực bằng file mật khẩu, lab dùng `auth_query` với client cert.
- Keycloak hostname động (issuer theo địa chỉ client gọi), lab cố định `https://auth.lab.internal`. keycloak-config-cli đăng nhập bằng admin bootstrap, lab dùng client service account.
- Kafka 1 broker: replication factor 1, `min.insync.replicas` của topic bị bỏ. Sửa topic đã tạo trong gitops thì compose không cập nhật theo (`--if-not-exists`); áp lại bằng reset.
- SMTP của realm trỏ Mailpit trên `gw` (10.20.0.5): không tới được từ Mac, G0 không gửi email.
- Không giới hạn memory trừ Keycloak; số đo RAM ở `docs/experiments/2026-11-g0-32-compose-dev-loop.md` (repo `docs`).
