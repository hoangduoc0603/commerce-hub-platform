# commerce-hub platform

Hạ tầng và công cụ dùng chung cho mọi repo của commerce-hub.

| Thư mục | Dùng cho |
|---|---|
| `compose/` | Docker Compose dựng hạ tầng chạy local (PostgreSQL, Kafka, Schema Registry, Keycloak, ...) |
| `kind/` | Cấu hình cụm kind và add-on |
| `charts/` | Helm chart dùng chung `app` cho mọi workload (service, `marketplace-sim`, `seller-web`), publish lên OCI registry (theo ticket 11 trong `docs/.scratch/architecture-g0-g1/`) |
| `docs/` | Hướng dẫn dựng hạ tầng (homelab Hyper-V) |
| `scripts/github/` | Tạo và kiểm repo GitHub theo chuẩn repo public (`repo-bootstrap.sh`, `repo-audit.sh`) |
| `.github/workflows/` | Reusable workflow cho CI của các repo (`java-library.yml` cho `libs/*`; `java-service.yml` và các workflow khác sẽ thêm) |

Cụm chạy chính là cụm Kubernetes home lab (kubeadm trên Hyper-V ở máy bàn, truy cập từ MacBook qua Tailscale, context `kubectl` là `homelab`). Kafka, PostgreSQL, Redis, OpenSearch chạy trong cụm này. Cách dựng xem [`docs/homelab-hyperv.md`](docs/homelab-hyperv.md). `compose/` và `kind/` chỉ dùng khi cần chạy thử nhanh trên MacBook.

## Reusable workflow

| Workflow | Dùng cho | Quyền bên gọi phải cấp | Secret |
|---|---|---|---|
| `java-library.yml` | Thư viện Java (`libs/*`): `check` mọi lần chạy, `dependency-graph` trên push nhánh mặc định, `publish` lên GitHub Packages trên push tag `v*` | `contents: write`, `packages: write` | Không (dùng `GITHUB_TOKEN`) |

Bên gọi ghim workflow bằng SHA 40 ký tự của commit, kèm comment. Workflow được gọi chỉ hạ được quyền so với bên gọi, không nâng được, nên mỗi job trong đó tự khai đúng phần nó cần.
