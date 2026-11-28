#!/usr/bin/env bash
# So major.minor của image hạ tầng giữa compose (vòng dev trên Mac) và gitops (lab). Lệch thì thoát 1.
# G0-32, story 76 của spec G0: ba nơi (compose, Testcontainers, lab) không được trôi xa nhau. Ở G0 chỉ so compose với
# gitops; tag Testcontainers ghim trong test của từng service, quét chúng xét lại ở G1 (ADR-0018).
#
# Dùng: scripts/compose-image-drift.sh <compose.yaml> <thư mục gitops>
# Workflow compose-image-drift.yml chạy script này theo lịch, trên PR đổi compose, và chạy tay được.
# Cần: bash, yq v4 (mikefarah; có sẵn trên runner ubuntu-24.04).
#
# Chỉ so major.minor, không so patch hay digest: patch lệch là bình thường (lab nâng patch trước, compose theo sau),
# minor lệch mới đổi hành vi (tính năng, cấu hình, định dạng dữ liệu). Patch khác nhau thì in để biết, không đỏ.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Dùng: $0 <compose.yaml> <thư mục gitops>" >&2
  exit 2
fi
compose_file=$1
gitops_dir=$2

# Phần version của một image ref "repo:tag@sha256:..." hoặc một version trần "4.3.2": bỏ digest, lấy tag, bỏ hậu tố.
# Ví dụ: ghcr.io/cloudnative-pg/postgresql:18.7-202611122305-standard-trixie@sha256:… → 18.7;
# adorsys/keycloak-config-cli:6.6.0-26.8.1 → 6.6.0 (phần sau "-" là bản Keycloak build cùng, không so).
version_of() {
  local ref=${1%%@*}
  local tag=${ref##*:}
  [[ "$tag" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && echo "${BASH_REMATCH[1]}"
}

major_minor() {
  [[ "$1" =~ ^([0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}"
}

# Image của một service trong compose.
compose_image() {
  yq ".services.\"$1\".image // \"\"" "$compose_file"
}

# Giá trị đầu tiên của biểu thức yq trên mọi document có kind cho trước, tìm trong cả gitops (bỏ upstream/ và .git).
# Dùng cho thành phần chưa có trên lab ở G0 (Kafka): chưa biết file nằm ở đâu.
# yq lỗi (file YAML hỏng) thì trả 1: bên gọi phải dừng, không được hiểu nhầm thành "gitops chưa có" (review G0-32).
gitops_find() {
  local kind=$1 expr=$2 out
  out=$(find "$gitops_dir" \( -name .git -o -name upstream \) -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
    | xargs -0 yq eval --no-doc "select(.kind == \"$kind\") | $expr") || return 1
  grep -v '^null$' <<<"$out" | head -n 1 || true
}

# Giá trị của biểu thức yq trong một file gitops cố định. File biến mất (đổi tên, dời chỗ) thì đỏ: sửa script cùng commit.
gitops_value() {
  local file="$gitops_dir/$1" expr=$2
  if [[ ! -f "$file" ]]; then
    echo "LỖI: không có $file (gitops dời file thì sửa $0)" >&2
    return 1
  fi
  yq eval --no-doc "$expr" "$file" | grep -v '^null$' | head -n 1
}

failed=0
printf '%-20s %-12s %-12s %s\n' "Image" "compose" "gitops" "Kết quả"

# check <tên> <version compose> <version gitops> [optional]
# optional: gitops chưa có thành phần này thì bỏ qua thay vì đỏ (Kafka ở G0, ticket 15 hoãn tới G1).
check() {
  local name=$1 compose_ver=$2 gitops_ver=$3 optional=${4:-} result
  if [[ -z "$compose_ver" ]]; then
    result="LỖI: compose không có version"
    failed=1
  elif [[ -z "$gitops_ver" && -n "$optional" ]]; then
    result="bỏ qua: gitops chưa có"
  elif [[ -z "$gitops_ver" ]]; then
    result="LỖI: gitops không có version"
    failed=1
  elif [[ "$(major_minor "$compose_ver")" != "$(major_minor "$gitops_ver")" ]]; then
    result="LỆCH major.minor"
    failed=1
  elif [[ "$compose_ver" != "$gitops_ver" ]]; then
    result="ok (patch khác)"
  else
    result="ok"
  fi
  printf '%-20s %-12s %-12s %s\n' "$name" "${compose_ver:--}" "${gitops_ver:--}" "$result"
}

check "PostgreSQL" \
  "$(version_of "$(compose_image postgres)")" \
  "$(version_of "$(gitops_value infra/pg-main/cluster.yaml 'select(.kind == "Cluster") | .spec.imageName')")"

check "PgBouncer" \
  "$(version_of "$(compose_image pgbouncer)")" \
  "$(version_of "$(gitops_value infra/pg-main/pooler.yaml 'select(.kind == "Pooler") | .spec.pgbouncer.image')")"

check "Keycloak" \
  "$(version_of "$(compose_image keycloak)")" \
  "$(version_of "$(gitops_value infra/keycloak/keycloak.yaml 'select(.kind == "Keycloak") | .spec.image')")"

check "keycloak-config-cli" \
  "$(version_of "$(compose_image keycloak-config)")" \
  "$(version_of "$(gitops_value infra/keycloak/keycloak-config-cli.yaml \
      'select(.kind == "Job") | .spec.template.spec.containers[] | select(.name == "keycloak-config-cli") | .image')")"

# Lab chạy Kafka bằng Strimzi: version nằm ở spec.kafka.version của CR Kafka, không ở tag image (kafka.md bắt khai rõ
# version; CR thiếu trường này thì dòng Kafka hiện "bỏ qua"). Gọi ngoài $(...) của check để lỗi yq dừng script.
kafka_gitops=$(gitops_find Kafka '.spec.kafka.version') || { echo "LỖI: yq không đọc được YAML trong $gitops_dir" >&2; exit 1; }
check "Kafka" \
  "$(version_of "$(compose_image kafka)")" \
  "$(version_of "$kafka_gitops")" \
  optional

if [[ $failed -ne 0 ]]; then
  echo
  echo "Compose lệch major.minor với lab. Đổi tag và digest trong $compose_file cho cùng major.minor với gitops" >&2
  echo "(tra digest: docker buildx imagetools inspect <image>:<tag>), chạy lại vòng dev rồi commit." >&2
  exit 1
fi
