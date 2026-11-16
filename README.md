# commerce-hub platform

Hạ tầng và công cụ dùng chung cho mọi repo của commerce-hub.

| Thư mục | Dùng cho |
|---|---|
| `compose/` | Docker Compose dựng hạ tầng chạy local (PostgreSQL, Kafka, Schema Registry, Keycloak, ...) |
| `kind/` | Cấu hình cụm kind và add-on |
| `charts/` | Helm chart dùng chung `app` cho mọi workload (service, `marketplace-sim`, `seller-web`), publish lên OCI registry (theo ticket 11 trong `docs/.scratch/architecture-g0-g1/`) |
| `docs/` | Hướng dẫn dựng hạ tầng (homelab Hyper-V) |
| `scripts/github/` | Tạo và kiểm repo GitHub theo chuẩn repo public (`repo-bootstrap.sh`, `repo-audit.sh`) |
| `.github/workflows/` | Reusable workflow cho CI của các repo (mục [Reusable workflow](#reusable-workflow)) và workflow thử của chính repo này |

Cụm chạy chính là cụm Kubernetes home lab (kubeadm trên Hyper-V ở máy bàn, truy cập từ MacBook qua Tailscale, context `kubectl` là `homelab`). Kafka, PostgreSQL, Redis, OpenSearch chạy trong cụm này. Cách dựng xem [`docs/homelab-hyperv.md`](docs/homelab-hyperv.md). `compose/` và `kind/` chỉ dùng khi cần chạy thử nhanh trên MacBook.

## Reusable workflow

Workflow dùng chung nằm ở `.github/workflows/`, gọi bằng `jobs.<id>.uses`. Chuẩn: `docs/standards/ci-cd.md` (repo `docs`), mục "Reusable workflow" và "Quyền và credential".

| Workflow | Làm gì | Từ |
|---|---|---|
| `container-image.yml` | Build `<context>/Dockerfile` bằng Buildx cho `linux/amd64`, nạp vào Docker, quét Trivy (chặn HIGH/CRITICAL đã có bản vá, đẩy SARIF lên Code scanning). Push vào nhánh mặc định thì mới push đúng bản đã quét lên `ghcr.io/<owner>/<image>:<git SHA>` và trả `digest`; sự kiện khác chỉ build và quét. Tag đã có thì fail, không push đè (`v0.1.1`). Nhãn OCI `source`, `revision`, `version`, `created`, cache BuildKit `type=gha`, tải artifact trước khi build (`v0.2.0`) | `v0.1.0` |
| `java-service.yml` | Service Spring Boot: `./gradlew build`, upload jar, gửi dependency graph Gradle (chỉ nhánh mặc định), rồi gọi lồng `container-image.yml` với jar đó | `v0.2.0` |

`ghcr-smoke.yml` là workflow thử của chính repo này: nó gọi `container-image.yml` với image `.github/ghcr-smoke/` (`FROM scratch`).

### Gọi từ repo khác

Service Java gọi `java-service.yml`:

```yaml
jobs:
  ci:
    # Ghim SHA 40 ký tự của commit release, comment là tên release. Không ghim tag hay nhánh.
    uses: hoangduoc0603/commerce-hub-platform/.github/workflows/java-service.yml@<SHA của v0.2.0> # v0.2.0
    # Quyền tối đa bên gọi cấp; workflow được gọi chỉ hạ được, không nâng được. Mỗi job bên trong tự hạ:
    # contents: write chỉ cho dependency-graph trên nhánh mặc định, packages: write chỉ cho job publish.
    permissions:
      contents: write
      packages: write
      security-events: write
    with:
      image: commerce-hub-<tên repo>   # chữ thường
      # java-version: '25'
```

Repo khác (Dockerfile không cần jar) gọi thẳng `container-image.yml` với cùng cách ghim, quyền `contents: read`, `packages: write`, `security-events: write`, và input `image`, `context` (mặc định `.`), `artifact`, `artifact-path` (mặc định không tải).

Output của cả hai: `needs.<job>.outputs.image` (`ghcr.io/<owner>/<image>`) và `needs.<job>.outputs.digest` (`sha256:…`), chỉ có giá trị khi đã push. Không cần secret nào: push bằng `GITHUB_TOKEN`.

Ngoại lệ Trivy ghi trong `<context>/.trivyignore`, mỗi mã CVE kèm lý do và ngày hết hạn.

Package GHCR tạo từ workflow của repo public sẽ tự public và tự nối với repo đó (đã xác minh 2026-11-16, ticket G0-17), nên cụm kéo image không cần pull secret.

### Phát hành

- Version theo SemVer, phát hành bằng GitHub release `vX.Y.Z` trên commit của `main`. Đổi input, output hoặc quyền theo kiểu phá vỡ thì tăng MAJOR; thêm input có mặc định thì tăng MINOR; sửa lỗi thì tăng PATCH. Còn ở `0.x` thì đổi phá vỡ tăng MINOR (SemVer mục 4): `v0.2.0` bắt bên gọi cấp thêm `security-events: write`.
- Repo bật immutable releases: tag của release khóa vào commit, không dời hay xóa được; tên release đã dùng thì không dùng lại được. Ruleset `release-tags-immutable` chặn dời và xóa mọi tag `v*`, kể cả tag không có release.
- Lấy SHA để ghim: `gh api repos/hoangduoc0603/commerce-hub-platform/commits/vX.Y.Z --jq .sha`.

Lịch sử: `java-library.yml` (publish thư viện Java lên GitHub Packages từ tag, viết cho `libs/service-kit` ở G0-18) đã xóa ngày 2026-11-15 khi dự án thôi dùng thư viện dùng chung (ADR-0018 trong repo `docs`); mã cũ ở commit `f836c28`, `contracts` dùng lại khi viết bước publish Maven.
