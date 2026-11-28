# commerce-hub platform

Hạ tầng và công cụ dùng chung cho mọi repo của commerce-hub.

| Thư mục | Dùng cho |
|---|---|
| `compose/` | Docker Compose cho vòng dev trên Mac: PostgreSQL, PgBouncer, Keycloak (realm đọc từ checkout `../gitops`), Kafka, profile `obs` với `grafana/otel-lgtm`. Cách dùng và chỗ lệch lab: [`compose/README.md`](compose/README.md) |
| `kind/` | Cấu hình cụm kind và add-on |
| `kubeconform-schemas/` | Schema JSON của kind từ CRD (`HTTPRoute`, `SealedSecret`) cho kubeconform trong `chart.yml` |
| `charts/` | Helm chart dùng chung `app` cho mọi workload (service, `marketplace-sim`, `seller-web`), publish lên OCI registry (theo ticket 11 trong `docs/.scratch/architecture-g0-g1/`) |
| `docs/` | Hướng dẫn dựng hạ tầng (homelab Hyper-V) |
| `scripts/compose-image-drift.sh` | So major.minor image giữa `compose/` và `gitops`; workflow `compose-image-drift.yml` chạy hằng ngày |
| `scripts/github/` | Tạo và kiểm repo GitHub theo chuẩn repo public (`repo-bootstrap.sh`, `repo-audit.sh`) |
| `.github/workflows/` | Reusable workflow cho CI của các repo (mục [Reusable workflow](#reusable-workflow)) và workflow thử của chính repo này |

Cụm chạy chính là cụm Kubernetes home lab (kubeadm trên Hyper-V ở máy bàn, truy cập từ MacBook qua Tailscale, context `kubectl` là `homelab`). Kafka, PostgreSQL, Redis, OpenSearch chạy trong cụm này. Cách dựng xem [`docs/homelab-hyperv.md`](docs/homelab-hyperv.md). `compose/` là hạ tầng của vòng code trên MacBook (Mac không ghi vào lab); `kind/` chỉ dùng khi gỡ lỗi chart.

## Chart `app`

Chart dùng chung `charts/app` cho mọi workload, publish lên `oci://ghcr.io/hoangduoc0603/charts/app` (package public, kéo không cần đăng nhập). Chuẩn: `docs/standards/helm-chart.md` (repo `docs`); thiết kế ở ticket G0-21.

- Bắt buộc trong values: `image.repository`, `image.digest`, `resources.requests.cpu`, `resources.requests.memory`. Thiếu thì `helm template` lỗi với thông điệp rõ.
- Chart tự đặt, values không đổi được: Pod Security "restricted", root chỉ đọc và `/tmp` emptyDir, `limits.memory = requests.memory`, không CPU limit, probe `/livez` `/readyz` trên cổng `http`, rolling update `maxSurge 1` `maxUnavailable 0`, `preStop` 10 s, grace 60 s.
- Chỉnh qua values: `replicaCount`, `ports` (map tên → số), `jvm.*` (ghép `JAVA_TOOL_OPTIONS`), `env` (ConfigMap, giá trị phải là chuỗi), `secretRevision`, `probes.startupFailureThreshold`. Mô tả từng value ở `charts/app/values.yaml`.
- Trust của lab (từ 0.2.0, G0-22): `trust.enabled` mặc định `true`, mount `/etc/trust/bundle.p12` (ConfigMap `lab-trust`) và `/etc/trust/lab-root-ca.pem` (ConfigMap `lab-root`) do trust-manager chép vào namespace mang nhãn `trust.lab.internal/inject: "true"`. JVM nhận `-Djavax.net.ssl.trustStore` ở cuối `JAVA_TOOL_OPTIONS`; `jvm.enabled=false` thì nhận `NODE_EXTRA_CA_CERTS`. Namespace thiếu nhãn thì pod kẹt `ContainerCreating` (cố ý). **Thay đổi phá vỡ khi nâng từ 0.1.x:** release không đổi values cũng nhận volume trust, nên gắn nhãn namespace trước khi nâng (hoặc đặt `trust.enabled: false`). Root lab đổi thì phải `kubectl rollout restart`: JVM và Node chỉ đọc truststore lúc khởi động.
- Cửa vào (từ 0.2.0, G0-22): `httpRoute.enabled`, `httpRoute.hostnames` (mỗi tên đúng một nhãn trước `.lab.internal`), `httpRoute.parentRef` (mặc định `edge/edge`, listener `https`), `httpRoute.timeouts`. Route luôn trỏ cổng `http`. Namespace phải mang nhãn `edge.lab.internal/routes: "true"`.
- Secret (từ 0.3.0, G0-27): `sealedSecrets` (map tên Secret → `type`, `encryptedData`, `preSync`) render SealedSecret; tên phải trùng tên lúc `kubeseal` (scope strict). `preSync: true` biến nó thành hook `PreSync` wave `-1`, xóa khi sync thành công, để có trước Job migrate. `secretEnv` (map tên biến → `secret`, `key`) nối từng key vào env bằng `secretKeyRef`. Đổi nội dung Secret thì tăng `secretRevision` trong cùng commit.
- Migration (từ 0.3.0, G0-27): `migration.enabled` sinh Job hook `PreSync` (wave `0`, `BeforeHookCreation`, `backoffLimit` 2, `activeDeadlineSeconds` 600, không TTL) chạy cùng image ở `SPRING_PROFILES_ACTIVE=migrate`. Job không nạp `env` của runtime; cấu hình riêng ở `migration.env`, `migration.secretEnv`, `migration.resources` (rỗng thì lấy `resources`). Chỉ bật khi image đã có chế độ migrate-only, nếu không Job treo tới `activeDeadlineSeconds`. Job lỗi thì Argo CD dừng sync, Deployment giữ bản cũ. Từ 0.3.1: Job dùng ServiceAccount `default` khi `serviceAccount.create=true` (SA do chart tạo chưa có lúc PreSync của lần sync đầu); `migration.env.<KEY>: null` gỡ key mặc định; `sealedSecrets.*.preSync` chỉ nhận boolean; `secretEnv` không được trùng `JAVA_TOOL_OPTIONS`, `NODE_EXTRA_CA_CERTS`; CI có bước "Bất biến Job migrate".
- Observability (từ 0.4.0, G0-30): `serviceMonitor.enabled` sinh ServiceMonitor scrape cổng `management` theo tên (`serviceMonitor.path` mặc định `/actuator/prometheus`, `serviceMonitor.interval` rỗng thì theo Prometheus); cần `ports.management`. Pod nhận `OTEL_RESOURCE_ATTRIBUTES` = `service.version=<image.tag>` cộng các cặp trong `otel.resourceAttributes` (giá trị chuỗi, không chứa `,` hay `=`; không đặt được `service.version`), cả Deployment lẫn Job migrate. Spring Boot: property `management.opentelemetry.resource-attributes` cùng khóa thắng biến này.
- Biến thể được CI kiểm: `charts/app/ci/*-values.yaml`.

Workflow `chart.yml`: PR đổi `charts/**`, `kubeconform-schemas/**` hoặc chính workflow thì `helm lint --strict`, `kubeconform` (Kubernetes 1.37.0, cộng schema `HTTPRoute`, `SealedSecret`, `ServiceMonitor` trong `kubeconform-schemas/`) từng biến thể `ci/` và test thiếu value bắt buộc. Push vào `main` đổi `charts/**` thì kiểm thêm, rồi package và push nếu version trong `Chart.yaml` chưa có trên GHCR. **Mỗi PR đổi chart phải tăng `version`** (SemVer: đổi nghĩa hay xóa value tăng MAJOR, thêm value tăng MINOR, sửa template tăng PATCH); version đã có thì job `publish` fail.

```bash
helm show chart oci://ghcr.io/hoangduoc0603/charts/app --version 0.4.0
```

## Reusable workflow

Workflow dùng chung nằm ở `.github/workflows/`, gọi bằng `jobs.<id>.uses`. Chuẩn: `docs/standards/ci-cd.md` (repo `docs`), mục "Reusable workflow" và "Quyền và credential".

| Workflow | Làm gì | Từ |
|---|---|---|
| `container-image.yml` | Build `<context>/Dockerfile` bằng Buildx cho `linux/amd64`, nạp vào Docker, quét Trivy (chặn HIGH/CRITICAL đã có bản vá, đẩy SARIF lên Code scanning). Push vào nhánh mặc định thì mới push đúng bản đã quét lên `ghcr.io/<owner>/<image>:<git SHA>` và trả `digest`; sự kiện khác chỉ build và quét. Tag đã có thì fail, không push đè (`v0.1.1`). Nhãn OCI `source`, `revision`, `version`, `created`, cache BuildKit `type=gha`, tải artifact trước khi build (`v0.2.0`). Push theo digest, kiểm layer trùng bản đã quét rồi mới gắn tag SHA bằng `skopeo copy --preserve-digests` (`v0.2.1`) | `v0.1.0` |
| `java-service.yml` | Service Spring Boot: `./gradlew build`, upload jar, gửi dependency graph Gradle (chỉ nhánh mặc định), rồi gọi lồng `container-image.yml` với jar đó | `v0.2.0` |
| `update-gitops.yml` | Ghi digest và tag (git SHA) của image vừa push vào `envs/<environment>/<service>/values.yaml` của `gitops` bằng token GitHub App (chỉ repo `gitops`, `contents: write`). File values phải có sẵn: CI không tạo service. Bỏ qua nếu SHA cũ hơn bản đang có (compare API); push bị từ chối thì lấy nhánh mới rồi làm lại, tối đa 5 lần; `concurrency` theo môi trường, `queue: max`. Bên gọi cấp `contents: read`, truyền `client-id` và secret `app-private-key`. Ghi hai dòng bằng `awk`, `yq` chỉ đọc lại để kiểm, diff phải đúng 2 dòng (`v0.3.1`: `yq -i` 4.54.3 trên runner xóa dòng trống) | `v0.3.0` |

`ghcr-smoke.yml` là workflow thử của chính repo này: nó gọi `container-image.yml` với image `.github/ghcr-smoke/` (`FROM scratch`).

### Gọi từ repo khác

Service Java gọi `java-service.yml`:

```yaml
jobs:
  ci:
    # Ghim SHA 40 ký tự của commit release, comment là tên release. Không ghim tag hay nhánh.
    uses: hoangduoc0603/commerce-hub-platform/.github/workflows/java-service.yml@152b52fc524f56f2a2898658728730da2b26b506 # v0.2.1
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
