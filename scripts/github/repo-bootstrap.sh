#!/usr/bin/env bash
# Tạo (nếu chưa có) và cấu hình một repo commerce-hub theo chuẩn repo public. Chạy lại bao nhiêu lần
# cũng được: mỗi mục đọc trạng thái hiện tại, chỉ ghi khi lệch, cuối cùng in số thay đổi.
#
#   repo-bootstrap.sh <name|owner/name> [--local <đường dẫn clone>] [--ecosystems gradle,docker,...]
#                     [--description "..."] [--dry-run]
#
# --local:      cũng scaffold file trong bản clone (LICENSE MIT, khối .gitignore, .github/dependabot.yml)
#               và gắn remote origin nếu thiếu. Script KHÔNG commit, KHÔNG push: chạy repo-audit.sh --local
#               rồi tự commit/push.
# --ecosystems: ecosystem Dependabot ngoài github-actions (luôn có), ví dụ gradle,docker hoặc helm.
# --dry-run:    chỉ in sẽ đổi gì.
# Chuẩn: docs/standards/ci-cd.md, ADR-0006. Ticket: docs/.scratch/g0-platform/issues/01-repo-bootstrap-script.md

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

REPO_ARG="" LOCAL="" ECOS="" DESC="" DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL="${2:?}"; shift 2 ;;
    --ecosystems) ECOS="${2:?}"; shift 2 ;;
    --description) DESC="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) [[ -z "$REPO_ARG" ]] || usage; REPO_ARG="$1"; shift ;;
  esac
done
[[ -n "$REPO_ARG" ]] || usage
need gh jq git
[[ -z "$LOCAL" || -d "$LOCAL/.git" ]] || die "'$LOCAL' không phải repo git"

REPO="$(resolve_repo "$REPO_ARG")"
CHANGES=0

ok()     { printf '  =  %s\n' "$1"; }
change() { # change <mô tả> <lệnh...>: đếm thay đổi và chạy lệnh (trừ khi --dry-run)
  local what="$1"; shift
  CHANGES=$((CHANGES + 1))
  if $DRY_RUN; then printf '  ~  %s (dry-run)\n' "$what"; return 0; fi
  printf '  +  %s\n' "$what"
  "$@" >/dev/null
}

printf 'Bootstrap %s\n' "$REPO"

# --- Repo ---------------------------------------------------------------------
# Không tự đổi repo private sang public: đó là thao tác lộ toàn bộ history, phải do người làm.
if META="$(gh api "repos/$REPO" 2>/dev/null)"; then
  [[ "$(jq -r .visibility <<<"$META")" == "public" ]] \
    || die "$REPO đang private. ADR-0006 yêu cầu public; đổi tay sau khi chạy repo-audit.sh --local."
  ok "repo public đã có"
else
  # --disable-wiki: wiki của repo public cho mọi người sửa; tài liệu nằm trong repo docs.
  change "tạo repo public" gh repo create "$REPO" --public --disable-wiki ${DESC:+--description "$DESC"}
  $DRY_RUN || META="$(gh api "repos/$REPO")"
fi

# --- Secret scanning, push protection -----------------------------------------
# Repo public mới có sẵn hai mục này (ci-cd.md), nhưng repo cũ hoặc bị tắt tay thì không.
for feature in secret_scanning secret_scanning_push_protection; do
  if [[ "$(jq -r ".security_and_analysis.${feature}.status // \"unknown\"" <<<"${META:-null}")" == "enabled" ]]; then
    ok "$feature"
  else
    change "bật $feature" gh api -X PATCH "repos/$REPO" --input - <<<"{\"security_and_analysis\":{\"${feature}\":{\"status\":\"enabled\"}}}"
  fi
done

# --- Dependabot alerts và security updates ------------------------------------
# Security updates cần alerts bật trước.
if [[ "$(http_status "repos/$REPO/vulnerability-alerts")" == "204" ]]; then
  ok "Dependabot alerts"
else
  change "bật Dependabot alerts" gh api -X PUT "repos/$REPO/vulnerability-alerts"
fi
if [[ "$(api_jq "repos/$REPO/automated-security-fixes" .enabled false)" == "true" ]]; then
  ok "Dependabot security updates"
else
  change "bật Dependabot security updates" gh api -X PUT "repos/$REPO/automated-security-fixes"
fi

# --- Actions: ghim SHA, quyền GITHUB_TOKEN --------------------------------------
# Tài khoản cá nhân không có policy cấp owner (đã kiểm 2026-11-13, ci-cd.md) nên bật trên từng repo.
AP="$(api_get "repos/$REPO/actions/permissions" '{"enabled":true,"allowed_actions":"all"}')"
if [[ "$(jq -r '.sha_pinning_required // false' <<<"$AP")" == "true" ]]; then
  ok "Actions bắt ghim SHA đầy đủ"
else
  # PUT thay cả object: giữ nguyên enabled/allowed_actions hiện tại, chỉ đổi sha_pinning_required.
  # Actions tắt thì GET không có allowed_actions; gửi null sẽ bị 422, nên chỉ gửi khi có.
  change "bật bắt ghim SHA đầy đủ" gh api -X PUT "repos/$REPO/actions/permissions" \
    --input - <<<"$(jq -c '{enabled} + (if .allowed_actions then {allowed_actions} else {} end) + {sha_pinning_required: true}' <<<"$AP")"
fi

WP="$(api_get "repos/$REPO/actions/permissions/workflow" '{}')"
if [[ "$(jq -c '[.default_workflow_permissions, .can_approve_pull_request_reviews]' <<<"$WP")" == '["read",false]' ]]; then
  ok "GITHUB_TOKEN read-only, Actions không tạo/duyệt PR"
else
  change "đặt GITHUB_TOKEN read-only, cấm Actions tạo/duyệt PR" gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
fi

# --- Ruleset nhánh mặc định ---------------------------------------------------
# Upsert theo tên: chỉ đụng ruleset của script, không xóa ruleset khác (audit sẽ báo nếu chúng bắt PR).
DESIRED_RS="$(jq -nc --arg name "$RULESET_NAME" --argjson rules "$RULESET_RULES" '{
  name: $name, target: "branch", enforcement: "active",
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  rules: $rules, bypass_actors: []
}')"
normalize_rs() { jq -cS '{name, target, enforcement, conditions, rules: ([.rules[] | {type}] | sort_by(.type)), bypass_actors: (.bypass_actors // [])}'; }

RS_ID=""
[[ -z "${META:-}" ]] || RS_ID="$(ruleset_id "$REPO")"   # repo chưa có (dry-run) thì chắc chắn chưa có ruleset
if [[ -z "$RS_ID" ]]; then
  change "tạo ruleset $RULESET_NAME (chặn xóa, chặn force push)" gh api -X POST "repos/$REPO/rulesets" --input - <<<"$DESIRED_RS"
elif [[ "$(gh api "repos/$REPO/rulesets/$RS_ID" | normalize_rs)" == "$(normalize_rs <<<"$DESIRED_RS")" ]]; then
  ok "ruleset $RULESET_NAME"
else
  change "sửa ruleset $RULESET_NAME về đúng mẫu" gh api -X PUT "repos/$REPO/rulesets/$RS_ID" --input - <<<"$DESIRED_RS"
fi

# --- CodeQL default setup -----------------------------------------------------
# Repo chưa có ngôn ngữ CodeQL hỗ trợ vẫn bật được (languages: []), đã kiểm 2026-11-13.
if [[ "$(api_jq "repos/$REPO/code-scanning/default-setup" .state unknown)" == "configured" ]]; then
  ok "CodeQL default setup"
else
  change "bật CodeQL default setup" gh api -X PATCH "repos/$REPO/code-scanning/default-setup" -f state=configured
fi

# --- Scaffold trong bản clone --------------------------------------------------
write_if_differs() { # write_if_differs <file> <mô tả>  (nội dung mới đọc từ stdin)
  local file="$1" what="$2" new
  new="$(cat)"
  if [[ -f "$file" && "$(cat "$file")" == "$new" ]]; then ok "$what"; return 0; fi
  change "$what" bash -c 'mkdir -p "$(dirname "$1")" && printf "%s\n" "$2" > "$1"' _ "$file" "$new"
}

if [[ -n "$LOCAL" ]]; then
  printf 'Bản clone %s\n' "$LOCAL"

  if ORIGIN="$(git -C "$LOCAL" remote get-url origin 2>/dev/null)"; then
    # origin trỏ repo khác (clone copy từ template...) thì lần push sau sẽ đẩy nhầm repo.
    [[ "$ORIGIN" =~ github\.com[:/]${REPO}(\.git)?$ ]] || die "origin của $LOCAL là '$ORIGIN', không phải $REPO."
    ok "remote origin"
  else
    change "gắn remote origin" git -C "$LOCAL" remote add origin "https://github.com/$REPO.git"
  fi

  # LICENSE: chỉ tạo khi thiếu. Đã có thì giữ (năm bản quyền là năm phát hành đầu, không đổi mỗi lần chạy).
  if [[ -f "$LOCAL/LICENSE" ]]; then
    if grep -q '^MIT License' "$LOCAL/LICENSE"; then ok "LICENSE MIT"; else die "$LOCAL/LICENSE có nhưng không phải MIT; sửa tay."; fi
  else
    HOLDER="$(git -C "$LOCAL" config user.name || gh api user --jq '.name // .login')"
    write_if_differs "$LOCAL/LICENSE" "tạo LICENSE MIT" <<<"$(render_license "$(date +%Y)" "$HOLDER")"
  fi

  # .gitignore: thay khối giữa hai marker, giữ nguyên phần còn lại của repo.
  GI="$LOCAL/.gitignore"
  CURRENT="$( [[ -f "$GI" ]] && cat "$GI" || true )"
  # Phần ngoài marker, bỏ dòng trống ở cuối để chạy lại không sinh thêm dòng trống.
  OUTSIDE="$(awk -v b="$GITIGNORE_BEGIN" -v e="$GITIGNORE_END" '
    $0==b {skip=1; next}  $0==e {skip=0; next}  skip {next}
    {line[++n]=$0}  NF {last=n}
    END {for (i=1; i<=last; i++) print line[i]}' <<<"$CURRENT")"
  WANT_GI="$(render_gitignore_block)"
  [[ -z "$OUTSIDE" ]] || WANT_GI="$(printf '%s\n\n%s' "$OUTSIDE" "$WANT_GI")"
  write_if_differs "$GI" "khối baseline trong .gitignore" <<<"$WANT_GI"

  # dependabot.yml: script sở hữu cả file. Có file khác mẫu thì không ghi đè, báo để người quyết.
  DB="$LOCAL/.github/dependabot.yml"
  # Không truyền --ecosystems thì giữ ecosystem đang có, để chạy lại không âm thầm bỏ gradle/docker.
  if [[ -z "$ECOS" && -f "$DB" ]]; then ECOS="$(ecosystems_in_file "$DB")"; fi
  WANT_ECOS="$(ecosystems_json "$ECOS")"
  WANT_DB="$(render_dependabot "$WANT_ECOS")"
  if [[ -f "$DB" && "$(cat "$DB")" != "$WANT_DB" ]] && ! head -n1 "$DB" | grep -q 'repo-bootstrap.sh'; then
    die "$DB do người viết, khác mẫu. Xóa đi để script sinh lại, hoặc sửa tay cho đủ ecosystem."
  fi
  write_if_differs "$DB" "dependabot.yml ($(jq -r 'join(",")' <<<"$WANT_ECOS"))" <<<"$WANT_DB"
fi

printf '\n%d thay đổi%s\n' "$CHANGES" "$($DRY_RUN && echo ' (dry-run, chưa ghi gì)')"
