# Script tạo và kiểm repo GitHub

Tạo và cấu hình mọi repo của commerce-hub bằng một lệnh, thay cho bấm tay trên GitHub. Chuẩn áp dụng: [ADR-0006](https://github.com/hoangduoc0603/docs/blob/main/adr/0006-public-repos-on-personal-account.md) và các mục "Repo public", "Nhánh và cập nhật phụ thuộc" của `docs/standards/ci-cd.md`.

| File | Việc |
|---|---|
| `repo-bootstrap.sh` | Tạo repo nếu chưa có, đưa settings về đúng mẫu, scaffold file trong bản clone. Đọc → so → chỉ ghi khi lệch, in số thay đổi. Không commit, không push. |
| `repo-audit.sh` | Chỉ đọc. In PASS/FAIL theo từng tiêu chí, exit 1 nếu có FAIL. |
| `lib.sh` | Hằng và mẫu dùng chung: tên ruleset, khối `.gitignore`, `dependabot.yml`, LICENSE. |

Cần `gh` (đã `gh auth login`, scope `repo`), `jq`, `git`.

## Thêm một repo mới

```bash
mkdir -p ~/Desktop/sys-craft/lab/commerce-hub/services/foo && cd $_ && git init -b main
../../platform/scripts/github/repo-bootstrap.sh foo --local . --ecosystems gradle,docker --description "..."
git add -A && git commit -m "chore: khởi tạo repo"
../../platform/scripts/github/repo-audit.sh foo --local . --ecosystems gradle,docker   # phải "Tất cả PASS" trước khi push
git push -u origin main
```

Chạy `repo-audit.sh --local` **trước** lần push đầu: nó quét email của mọi commit. Lớp chặn `GH007` của GitHub chỉ xét commit mới nhất và chỉ chặn email đã thêm vào tài khoản, nên không đủ.

## Những gì script đặt

| Mục | Giá trị | Vì sao |
|---|---|---|
| Visibility | public (không tự đổi private → public) | ADR-0006. Đổi visibility lộ toàn bộ history nên để người làm. |
| Secret scanning, push protection | enabled | Repo public mới có sẵn, script vẫn đặt lại để repo cũ cũng đúng. |
| Dependabot alerts, security updates | enabled | Mặc định đang tắt. |
| Actions `sha_pinning_required` | true | Tài khoản cá nhân không có policy cấp owner, phải bật từng repo (đã kiểm 2026-11-13). |
| `GITHUB_TOKEN` mặc định | read, Actions không được tạo/duyệt PR | ci-cd.md, "Quyền và credential". |
| Ruleset `default-branch-minimal` | `~DEFAULT_BRANCH`: chỉ `deletion`, `non_fast_forward` | ADR-0006: không bắt PR, không bắt status check. Upsert theo tên; ruleset tên khác không bị đụng, nhưng audit FAIL nếu nó bắt PR. |
| CodeQL default setup | configured | Bật được cả khi repo chưa có ngôn ngữ CodeQL hỗ trợ (`languages: []`). |
| `LICENSE` | MIT, chỉ tạo khi thiếu | Năm bản quyền là năm phát hành đầu, không đổi mỗi lần chạy. |
| `.gitignore` | khối giữa hai marker `commerce-hub baseline` | Phần ngoài marker là của repo, giữ nguyên. |
| `.github/dependabot.yml` | `github-actions` + `--ecosystems` | Script sở hữu cả file; file do người viết thì không ghi đè. |

Chưa làm: allowlist action (`allowed_actions: selected`). Thêm khi có workflow đầu tiên (ticket G0-17).
