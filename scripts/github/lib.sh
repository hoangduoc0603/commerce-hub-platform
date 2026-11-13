# shellcheck shell=bash
# Hàm và hằng dùng chung cho repo-audit.sh và repo-bootstrap.sh.
# Nguồn chuẩn: docs/standards/ci-cd.md (mục "Repo public", "Nhánh và cập nhật phụ thuộc"), ADR-0006.

set -euo pipefail

# Tên ruleset do script quản lý. Script chỉ đụng tới ruleset có đúng tên này (upsert theo tên).
readonly RULESET_NAME="default-branch-minimal"

# Hai rule duy nhất trên nhánh mặc định: chặn xóa và chặn force push (ADR-0006).
readonly RULESET_RULES='[{"type":"deletion"},{"type":"non_fast_forward"}]'

# Rule không được có ở bất kỳ ruleset nào: ADR-0006 cố ý không bắt PR, không bắt status check.
readonly FORBIDDEN_RULE_TYPES='["pull_request","required_status_checks","required_deployments","merge_queue"]'

# Khối .gitignore do script quản lý, nằm giữa hai dòng marker. Phần ngoài marker là của repo.
readonly GITIGNORE_BEGIN="# >>> commerce-hub baseline (platform/scripts/github) >>>"
readonly GITIGNORE_END="# <<< commerce-hub baseline <<<"

# Tên file mẫu phải bị .gitignore chặn. Mỗi tên đại diện cho một loại credential.
readonly IGNORE_SAMPLES=(
  ".env"
  ".env.local"
  "lab.kubeconfig"
  "kubeconfig"
  "config/kubeconfig-homelab"
  "tskey-auth-k123"
  "tailscale-authkey.txt"
  "sealed-secrets-key-backup.yaml"
  "root-ca.key"
)

# Tên file phải KHÔNG bị chặn (để chắc khối ignore không nuốt nhầm file mẫu).
readonly NOT_IGNORE_SAMPLES=(
  ".env.example"
)

readonly NOREPLY_RE='(@users\.noreply\.github\.com|^noreply@github\.com)$'

die() { printf 'lỗi: %s\n' "$*" >&2; exit 2; }

need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "thiếu lệnh '$cmd'"
  done
}

# Mọi repo trên GitHub có prefix này để không lẫn với dự án khác trên tài khoản cá nhân
# (ADR-0006, mục "Đặt tên repo"). Thư mục local giữ tên ngắn: platform/ ↔ commerce-hub-platform.
readonly REPO_PREFIX="commerce-hub-"

# owner/name từ tham số. Tên ngắn (platform, services/hello → hello) được thêm REPO_PREFIX;
# thiếu owner thì lấy login của tài khoản gh đang đăng nhập. owner/name đầy đủ thì giữ nguyên.
resolve_repo() {
  local arg="$1" name
  if [[ "$arg" == */* ]]; then
    printf '%s' "$arg"
    return
  fi
  name="$arg"
  [[ "$name" == "$REPO_PREFIX"* ]] || name="${REPO_PREFIX}${name}"
  printf '%s/%s' "$(gh api user --jq .login)" "$name"
}

# GET qua gh api, in body khi thành công; lỗi (404, repo chưa có) thì in <mặc định>.
# Không viết `gh api ... || echo x`: khi lỗi HTTP, gh vẫn in body lỗi ra stdout, giá trị sẽ bị trộn.
api_get() { # api_get <path> [mặc định]
  local out
  if out="$(gh api "$1" 2>/dev/null)"; then printf '%s' "$out"; else printf '%s' "${2:-}"; fi
}

# Một giá trị từ GET, lọc bằng jq; lỗi thì in <mặc định>.
api_jq() { # api_jq <path> <jq filter> <mặc định>
  local out
  out="$(api_get "$1")"
  if [[ -n "$out" ]]; then jq -r "$2" <<<"$out"; else printf '%s' "$3"; fi
}

# id ruleset theo tên, rỗng nếu chưa có. Lỗi API thì dừng hẳn (không coi là "chưa có",
# vì như vậy bootstrap sẽ POST thêm một ruleset trùng tên).
ruleset_id() { # ruleset_id <owner/name>
  local list
  list="$(gh api "repos/$1/rulesets")" || die "không đọc được rulesets của $1"
  jq -r --arg n "$RULESET_NAME" 'first(.[] | select(.name == $n) | .id) // empty' <<<"$list"
}

# Ecosystem đang có trong một dependabot.yml, dạng "a,b".
ecosystems_in_file() { # ecosystems_in_file <file>
  grep -E '^[[:space:]]*-[[:space:]]*package-ecosystem:' "$1" | awk '{print $NF}' | paste -sd, -
}

# HTTP status của một GET (không in body). Dùng cho endpoint trả 204/404 như vulnerability-alerts.
http_status() {
  gh api -i "$1" 2>/dev/null | awk 'NR==1 {print $2; exit}' || true
}

# Danh sách ecosystem "a,b,c" → mảng JSON đã sắp xếp, bỏ trùng; luôn có github-actions.
ecosystems_json() {
  local csv="${1:-}"
  printf '%s' "github-actions,${csv}" \
    | tr -d '[:space:]' | tr ',' '\n' | sed '/^$/d' | sort -u \
    | jq -R . | jq -sc .
}

# Nội dung .github/dependabot.yml sinh từ danh sách ecosystem (ci-cd.md: groups gộp minor/patch,
# giữ cooldown mặc định).
render_dependabot() {
  local eco
  printf '%s\n' \
    "# Sinh bởi platform/scripts/github/repo-bootstrap.sh. Thêm ecosystem bằng cách chạy lại script với --ecosystems." \
    "# Chuẩn: docs/standards/ci-cd.md, mục \"Nhánh và cập nhật phụ thuộc\"." \
    "version: 2" \
    "updates:"
  for eco in $(jq -r '.[]' <<<"$1"); do
    printf '%s\n' \
      "  - package-ecosystem: ${eco}" \
      "    directory: /" \
      "    schedule:" \
      "      interval: weekly" \
      "    groups:" \
      "      minor-and-patch:" \
      "        update-types: [minor, patch]"
  done
}

render_gitignore_block() {
  printf '%s\n' \
    "$GITIGNORE_BEGIN" \
    "# Credential không bao giờ vào Git, kể cả repo private (ADR-0006, docs/standards/ci-cd.md \"Repo public\")." \
    "# .gitignore chỉ chặn theo TÊN file; nội dung secret do push protection của GitHub bắt." \
    ".env" \
    ".env.*" \
    "!.env.example" \
    "*.kubeconfig" \
    "kubeconfig*" \
    ".kube/" \
    "tskey-*" \
    "*.tskey" \
    "tailscale-authkey*" \
    "sealed-secrets-key*" \
    "*.key" \
    "$GITIGNORE_END"
}

render_license() {
  local year="$1" holder="$2"
  cat <<EOF
MIT License

Copyright (c) ${year} ${holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}
