# Schema JSON cho kubeconform

Schema mặc định của kubeconform chỉ có resource gốc của Kubernetes. Kind từ CRD mà chart `app` sinh ra cần schema riêng, nếu không kubeconform báo `could not find schema`. Không dùng `-ignore-missing-schemas`: route gõ sai field sẽ lọt qua CI và chỉ lộ khi route không `Accepted` trên cụm (`docs/standards/helm-chart.md` mục "Kiểm tra", repo `docs`).

Workflow `chart.yml` tìm schema theo `-schema-location default -schema-location 'kubeconform-schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`.

| File | Nguồn | sha256 nguồn |
|---|---|---|
| `gateway.networking.k8s.io/httproute_v1.json` | Gateway API v1.6.1 `standard-install.yaml` (cùng file vendor ở `gitops/infra/gateway-api-crds/upstream/`) | `24d931f22abd8e40c973264319ead7cfa09d0fb7716b7ab1ee2ff174cb063a73` |
| `bitnami.com/sealedsecret_v1alpha1.json` | Sealed Secrets 0.41.2, file vendor `gitops/infra/sealed-secrets/upstream/sealedsecrets-crd.yaml` | `6ccc74ae40a65ec4a1ab95baaf34b0beef0591d343fe3aea1104a36a4f283fab` |
| `monitoring.coreos.com/servicemonitor_v1.json` | Prometheus Operator 0.95.2 (kube-prometheus-stack 94.1.0), file vendor `gitops/infra/kube-prometheus-stack/upstream/monitoring.coreos.com_servicemonitors.yaml` | `373fabaf6f5b68c5a155fa94486d4e8a2863c4aa6478b066a62d0767cd86ab1f` |

Chỉ giữ schema của kind mà chart sinh ra. Cả ba file sinh bằng `scripts/openapi2jsonschema.py` của kubeconform v0.8.0 (sha256 `d145babfbb765004030764e1b4e518bfb7a4bd7f111691a08fa57983b81881f3`): `httproute_v1.json` ngày 2026-11-20 (G0-22, PyYAML 6.0.3), `sealedsecret_v1alpha1.json` ngày 2026-11-25 (G0-27, PyYAML 6.0.4), `servicemonitor_v1.json` ngày 2026-11-28 (G0-30, PyYAML 6.0.4). Script thêm `additionalProperties: false` cho mọi object, nên `-strict` bắt được field gõ sai.

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

## Sinh lại khi nâng Sealed Secrets

Làm cùng PR nâng controller trong `gitops` (ba chỗ ghim ở `gitops/apps/lab/sealed-secrets.yaml`). Nguồn là file CRD vendor đã nâng, không tải lại:

```bash
work="$(mktemp -d)" && cd "$work"
curl -fsSLO "https://raw.githubusercontent.com/yannh/kubeconform/v0.8.0/scripts/openapi2jsonschema.py"
echo "d145babfbb765004030764e1b4e518bfb7a4bd7f111691a08fa57983b81881f3  openapi2jsonschema.py" | shasum -a 256 -c -
python3 -m venv venv && venv/bin/pip install -q pyyaml
mkdir out && cd out
FILENAME_FORMAT='{kind}_{version}' ../venv/bin/python -I ../openapi2jsonschema.py <gitops>/infra/sealed-secrets/upstream/sealedsecrets-crd.yaml
cp sealedsecret_v1alpha1.json <platform>/kubeconform-schemas/bitnami.com/
```

Rồi sửa bảng trên (bản, sha256, ngày).

## Sinh lại khi nâng kube-prometheus-stack

Làm cùng commit nâng chart trong `gitops` (CRD vendor ở `gitops/infra/kube-prometheus-stack/upstream/` đổi theo tag operator). Nguồn là file CRD vendor đã nâng:

```bash
work="$(mktemp -d)" && cd "$work"
curl -fsSLO "https://raw.githubusercontent.com/yannh/kubeconform/v0.8.0/scripts/openapi2jsonschema.py"
echo "d145babfbb765004030764e1b4e518bfb7a4bd7f111691a08fa57983b81881f3  openapi2jsonschema.py" | shasum -a 256 -c -
python3 -m venv venv && venv/bin/pip install -q pyyaml
mkdir out && cd out
FILENAME_FORMAT='{kind}_{version}' ../venv/bin/python -I ../openapi2jsonschema.py <gitops>/infra/kube-prometheus-stack/upstream/monitoring.coreos.com_servicemonitors.yaml
cp servicemonitor_v1.json <platform>/kubeconform-schemas/monitoring.coreos.com/
```

Rồi sửa bảng trên (bản, sha256, ngày).
