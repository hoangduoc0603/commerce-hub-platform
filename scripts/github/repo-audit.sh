#!/usr/bin/env bash
# Kiểm một repo commerce-hub có đạt chuẩn repo public không. Chỉ đọc, không sửa gì.
# In PASS/FAIL theo từng tiêu chí; exit 1 nếu có FAIL.
#
#   repo-audit.sh <name|owner/name>   (name ngắn như "platform" thành "commerce-hub-platform") [--local <đường dẫn clone>] [--ecosystems gradle,docker,...]
#                 [--release-tags]
#
# --local:        kiểm thêm phần chỉ có ở bản clone: file scaffold, .gitignore, và email trong history.
#                 Chạy trước lần push đầu để chặn email thật lọt lên repo public.
# --release-tags: repo publish từ tag vX.Y.Z: kiểm thêm ruleset khóa tag v* (cấm dời, cấm xóa).
# Chuẩn: docs/standards/ci-cd.md, ADR-0006. Ticket: docs/.scratch/g0-platform/issues/01-repo-bootstrap-script.md

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

REPO_ARG="" LOCAL="" ECOS="" RELEASE_TAGS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL="${2:?}"; shift 2 ;;
    --ecosystems) ECOS="${2:?}"; shift 2 ;;
    --release-tags) RELEASE_TAGS=true; shift ;;
    -h|--help) usage ;;
    *) [[ -z "$REPO_ARG" ]] || usage; REPO_ARG="$1"; shift ;;
  esac
done
[[ -n "$REPO_ARG" ]] || usage
need gh jq git

REPO="$(resolve_repo "$REPO_ARG")"
FAILS=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s%s\n' "$1" "${2:+  ($2)}"; FAILS=$((FAILS + 1)); }
check() { # check <mô tả> <thực tế> <mong đợi>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "đang: $2, cần: $3"; fi
}

printf 'Audit %s\n' "$REPO"

# --- Repo -------------------------------------------------------------------
if ! META="$(gh api "repos/$REPO" 2>/dev/null)"; then
  fail "repo tồn tại trên GitHub"
  printf '\n%d FAIL\n' "$FAILS"; exit 1
fi
check "repo public" "$(jq -r .visibility <<<"$META")" "public"
check "license MIT (GitHub nhận diện)" "$(jq -r '.license.spdx_id // "none"' <<<"$META")" "MIT"

# --- Secret scanning, push protection, Dependabot -----------------------------
SA="$(jq -c '.security_and_analysis // {}' <<<"$META")"
check "secret scanning" "$(jq -r '.secret_scanning.status // "unknown"' <<<"$SA")" "enabled"
check "push protection" "$(jq -r '.secret_scanning_push_protection.status // "unknown"' <<<"$SA")" "enabled"
check "Dependabot alerts" "$(http_status "repos/$REPO/vulnerability-alerts")" "204"
check "Dependabot security updates" "$(api_jq "repos/$REPO/automated-security-fixes" .enabled unknown)" "true"

# --- Actions ------------------------------------------------------------------
AP="$(api_get "repos/$REPO/actions/permissions" '{}')"
check "Actions bắt ghim SHA đầy đủ" "$(jq -r '.sha_pinning_required // false' <<<"$AP")" "true"
WP="$(api_get "repos/$REPO/actions/permissions/workflow" '{}')"
check "GITHUB_TOKEN mặc định read-only" "$(jq -r .default_workflow_permissions <<<"$WP")" "read"
check "Actions không được tạo/duyệt PR" "$(jq -r .can_approve_pull_request_reviews <<<"$WP")" "false"

# --- Code scanning ------------------------------------------------------------
check "CodeQL default setup" "$(api_jq "repos/$REPO/code-scanning/default-setup" .state unknown)" "configured"

# --- Nhánh mặc định -----------------------------------------------------------
RS_ID="$(ruleset_id "$REPO")"
if [[ -z "$RS_ID" ]]; then
  fail "ruleset '$RULESET_NAME'" "chưa có"
else
  RS="$(gh api "repos/$REPO/rulesets/$RS_ID")"
  check "ruleset: enforcement" "$(jq -r .enforcement <<<"$RS")" "active"
  check "ruleset: áp lên nhánh mặc định" "$(jq -c '.conditions.ref_name.include' <<<"$RS")" '["~DEFAULT_BRANCH"]'
  check "ruleset: chỉ chặn xóa và force push" "$(jq -c '[.rules[].type] | sort' <<<"$RS")" '["deletion","non_fast_forward"]'
fi
# Không ruleset nào (kể cả do người khác tạo) được bắt PR hay status check (ADR-0006).
# Lỗi API ở đây phải dừng có thông báo, không được thoát im lặng giữa chừng vì set -e.
RS_IDS="$(gh api "repos/$REPO/rulesets" --jq '.[].id')" || die "không đọc được rulesets của $REPO"
FORBIDDEN=""
for id in $RS_IDS; do
  TYPES="$(gh api "repos/$REPO/rulesets/$id" --jq ".rules[].type | select(IN(${FORBIDDEN_RULE_TYPES}[]))")" \
    || die "không đọc được ruleset $id"
  FORBIDDEN="$(printf '%s\n%s' "$FORBIDDEN" "$TYPES" | sed '/^$/d' | sort -u | paste -sd, -)"
done
check "không ruleset nào bắt PR/status check" "${FORBIDDEN:-none}" "none"

# --- Tag phát hành (--release-tags) --------------------------------------------
if $RELEASE_TAGS; then
  TAG_RS_ID="$(ruleset_id "$REPO" "$TAG_RULESET_NAME")"
  if [[ -z "$TAG_RS_ID" ]]; then
    fail "ruleset '$TAG_RULESET_NAME'" "chưa có"
  else
    TRS="$(gh api "repos/$REPO/rulesets/$TAG_RS_ID")"
    check "ruleset tag: enforcement" "$(jq -r .enforcement <<<"$TRS")" "active"
    check "ruleset tag: target" "$(jq -r .target <<<"$TRS")" "tag"
    check "ruleset tag: áp lên $TAG_RULESET_PATTERN" "$(jq -c '.conditions.ref_name.include' <<<"$TRS")" "[\"$TAG_RULESET_PATTERN\"]"
    check "ruleset tag: cấm dời và xóa" "$(jq -c '[.rules[].type] | sort' <<<"$TRS")" '["deletion","update"]'
    check "ruleset tag: không ai được bypass" "$(jq -c '.bypass_actors // []' <<<"$TRS")" '[]'
  fi
fi

DEFAULT_BRANCH="$(jq -r .default_branch <<<"$META")"
check "không dùng branch protection rule cũ" \
  "$(http_status "repos/$REPO/branches/$DEFAULT_BRANCH/protection")" "404"

# --- Bản clone local ----------------------------------------------------------
if [[ -n "$LOCAL" ]]; then
  [[ -d "$LOCAL/.git" ]] || die "'$LOCAL' không phải repo git"
  printf 'Bản clone %s\n' "$LOCAL"

  if grep -q '^MIT License' "$LOCAL/LICENSE" 2>/dev/null; then pass "LICENSE MIT"; else fail "LICENSE MIT" "thiếu hoặc không phải MIT"; fi

  if grep -qxF "$GITIGNORE_BEGIN" "$LOCAL/.gitignore" 2>/dev/null; then
    pass ".gitignore có khối baseline"
  else
    fail ".gitignore có khối baseline" "thiếu marker"
  fi
  for f in "${IGNORE_SAMPLES[@]}"; do
    if git -C "$LOCAL" check-ignore -q --no-index "$f"; then pass ".gitignore chặn $f"; else fail ".gitignore chặn $f"; fi
  done
  for f in "${NOT_IGNORE_SAMPLES[@]}"; do
    if git -C "$LOCAL" check-ignore -q --no-index "$f"; then fail ".gitignore không chặn nhầm $f"; else pass ".gitignore không chặn nhầm $f"; fi
  done

  WANT_ECOS="$(ecosystems_json "$ECOS")"
  DB="$LOCAL/.github/dependabot.yml"
  if [[ -f "$DB" ]]; then
    HAVE_ECOS="$(ecosystems_in_file "$DB" | tr ',' '\n' | jq -R . | jq -sc 'unique')"
    MISSING="$(jq -rn --argjson w "$WANT_ECOS" --argjson h "$HAVE_ECOS" '$w - $h | join(",")')"
    check "dependabot.yml có đủ ecosystem $(jq -r 'join(",")' <<<"$WANT_ECOS")" "${MISSING:+thiếu $MISSING}" ""
  else
    fail "dependabot.yml" "thiếu file"
  fi

  # GH007 chỉ xét commit mới nhất và chỉ email đã thêm vào tài khoản (ci-cd.md, "Repo public"),
  # nên lớp chặn thật là quét toàn bộ history ở đây.
  if git -C "$LOCAL" rev-parse -q --verify HEAD >/dev/null; then
    # Chỉ đếm, không in email ra: output audit có thể được dán vào issue/log công khai.
    # Gồm cả tagger của annotated tag: tag release cũng được push và mang email.
    LEAKS="$( { git -C "$LOCAL" log --all --format='%ae%n%ce'
                git -C "$LOCAL" for-each-ref refs/tags --format='%(taggeremail:trim)' | sed 's/^<//; s/>$//' | sed '/^$/d'; } \
      | sort -u | { grep -Ev "$NOREPLY_RE" || true; } | wc -l | tr -d ' ')"
    check "history chỉ có email noreply (số email khác)" "$LEAKS" "0"
  else
    pass "history chỉ có email noreply (chưa có commit)"
  fi
  NEXT_EMAIL="$(git -C "$LOCAL" config user.email || true)"
  if [[ "$NEXT_EMAIL" =~ $NOREPLY_RE ]]; then
    pass "user.email cho commit tiếp theo là noreply"
  else
    fail "user.email cho commit tiếp theo là noreply" "thiếu includeIf? xem ci-cd.md"
  fi
fi

printf '\n'
if [[ "$FAILS" -gt 0 ]]; then printf '%d FAIL\n' "$FAILS"; exit 1; fi
printf 'Tất cả PASS\n'
