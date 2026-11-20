# Schema JSON cho kubeconform

Schema mặc định của kubeconform chỉ có resource gốc của Kubernetes. Kind từ CRD mà chart `app` sinh ra cần schema riêng, nếu không kubeconform báo `could not find schema`. Không dùng `-ignore-missing-schemas`: route gõ sai field sẽ lọt qua CI và chỉ lộ khi route không `Accepted` trên cụm (`docs/standards/helm-chart.md` mục "Kiểm tra", repo `docs`).

Workflow `chart.yml` tìm schema theo `-schema-location default -schema-location 'kubeconform-schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`.

| File | Nguồn | sha256 nguồn |
|---|---|---|
| `gateway.networking.k8s.io/httproute_v1.json` | Gateway API v1.6.1 `standard-install.yaml` (cùng file vendor ở `gitops/infra/gateway-api-crds/upstream/`) | `24d931f22abd8e40c973264319ead7cfa09d0fb7716b7ab1ee2ff174cb063a73` |

Chỉ giữ schema của kind mà chart sinh ra. Sinh ngày 2026-11-20 (G0-22) bằng `scripts/openapi2jsonschema.py` của kubeconform v0.8.0 (sha256 `d145babfbb765004030764e1b4e518bfb7a4bd7f111691a08fa57983b81881f3`), PyYAML 6.0.3. Script thêm `additionalProperties: false` cho mọi object, nên `-strict` bắt được field gõ sai.

## Sinh lại khi nâng Gateway API

Làm cùng PR nâng CRD trong `gitops`. Chạy trong thư mục tạm, không chạy trong repo:

```bash
V=v1.6.1   # bản Gateway API mới
work="$(mktemp -d)" && cd "$work"
curl -fsSLO "https://raw.githubusercontent.com/yannh/kubeconform/v0.8.0/scripts/openapi2jsonschema.py"
echo "d145babfbb765004030764e1b4e518bfb7a4bd7f111691a08fa57983b81881f3  openapi2jsonschema.py" | shasum -a 256 -c -
curl -fsSLO "https://github.com/kubernetes-sigs/gateway-api/releases/download/${V}/standard-install.yaml"
shasum -a 256 standard-install.yaml   # so với file vendor trong gitops
python3 -m venv venv && venv/bin/pip install -q pyyaml
mkdir out && cd out
FILENAME_FORMAT='{kind}_{version}' ../venv/bin/python -I ../openapi2jsonschema.py ../standard-install.yaml
cp httproute_v1.json <platform>/kubeconform-schemas/gateway.networking.k8s.io/
```

Rồi sửa bảng trên (bản, sha256, ngày).
