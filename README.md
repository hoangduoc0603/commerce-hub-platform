# commerce-hub platform

Hạ tầng và công cụ dùng chung cho mọi repo của commerce-hub.

| Thư mục | Dùng cho |
|---|---|
| `compose/` | Docker Compose dựng hạ tầng chạy local (PostgreSQL, Kafka, Schema Registry, Keycloak, ...) |
| `kind/` | Cấu hình cụm kind và add-on |
| `charts/` | Helm chart dùng chung `app` cho mọi workload (service, `marketplace-sim`, `seller-web`), publish lên OCI registry (theo ticket 11 trong `docs/.scratch/architecture-g0-g1/`) |
| `docs/` | Hướng dẫn dựng hạ tầng (homelab Hyper-V) |
| `.github/workflows/` | Reusable workflow cho CI của các repo service (sẽ thêm) |

Cụm chạy chính là cụm Kubernetes home lab (kubeadm trên Hyper-V ở máy bàn, truy cập từ MacBook qua Tailscale, context `kubectl` là `homelab`). Kafka, PostgreSQL, Redis, OpenSearch chạy trong cụm này. Cách dựng xem [`docs/homelab-hyperv.md`](docs/homelab-hyperv.md). `compose/` và `kind/` chỉ dùng khi cần chạy thử nhanh trên MacBook.
