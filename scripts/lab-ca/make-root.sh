#!/usr/bin/env bash
# Tạo root CA offline của lab. Chỉ chạy MỘT lần; script từ chối chạy khi đã có khóa hoặc chứng chỉ.
# Khóa root nằm ngoài repo và ngoài cụm, mã hóa bằng passphrase; phần công khai ghi vào pki/ của repo.
#
#   make-root.sh            (hỏi passphrase hai lần khi tạo khóa, một lần khi ký)
#
# Biến môi trường:
#   LAB_CA_DIR       thư mục chứa khóa root (mặc định ~/lab-ca, quyền 700). Không đặt trong repo.
#   LAB_CA_OUT       đường dẫn chứng chỉ root (mặc định <platform>/pki/lab-root-ca.crt).
#   LAB_CA_SUBJECT   subject (mặc định "/O=commerce-hub lab/CN=commerce-hub lab root CA 2026").
#   LAB_CA_PASSFILE  file chứa passphrase, thay cho hỏi tương tác. Chỉ dùng cho test-constraints.sh.
#   OPENSSL          đường dẫn openssl (mặc định tự tìm OpenSSL 3/4, bỏ qua LibreSSL của macOS).
#
# Chuẩn: docs/standards/cluster-entry.md mục "PKI và cert-manager", ADR-0014. Ticket: G0-02.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
openssl=$(pick_openssl)

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ca_dir=${LAB_CA_DIR:-$HOME/lab-ca}
out_crt=${LAB_CA_OUT:-$repo_root/pki/lab-root-ca.crt}
subject=${LAB_CA_SUBJECT:-/O=commerce-hub lab/CN=commerce-hub lab root CA 2026}
key=$ca_dir/lab-root-ca.key
days=3650   # 10 năm. Giới hạn 398 ngày của trình duyệt chỉ áp cho leaf, không áp cho root.

# Chạy lại sẽ sinh root mới, và mọi nơi đã tin root cũ phải tin lại. Không bao giờ ghi đè.
[[ -e $key ]] && die "đã có khóa $key. Root chỉ tạo một lần; muốn xoay root thì xóa tay có chủ đích."
[[ -e $out_crt ]] && die "đã có chứng chỉ $out_crt."

# Khóa root không được nằm trong bất kỳ repo Git nào. Kiểm ở thư mục cha gần nhất đã tồn tại,
# vì $ca_dir (và vài cấp cha) có thể chưa được tạo.
anc=$ca_dir
until [[ -d $anc ]]; do anc=$(dirname "$anc"); done
if git -C "$anc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "LAB_CA_DIR nằm trong một repo Git ($ca_dir). Khóa root không được ở trong Git."
fi

mkdir -p "$(dirname "$out_crt")"   # tạo trước umask 077: thư mục pki/ là phần công khai
umask 077
mkdir -p "$ca_dir" && chmod 700 "$ca_dir"

# Khóa ghi ra file tạm, chỉ đổi tên thành $key sau khi ký xong. Nếu ký lỗi (ví dụ gõ sai passphrase
# ở lần hỏi thứ ba), không để lại khóa mồ côi chặn lần chạy lại.
key_tmp=$ca_dir/.lab-root-ca.key.partial
finished=0
cleanup() {
  rm -f "${cfg:-}"
  [[ $finished == 1 ]] || rm -f "$key_tmp" "$out_crt"
}
trap cleanup EXIT

pass_out=() pass_in=()
if [[ -n ${LAB_CA_PASSFILE:-} ]]; then
  pass_out=(-pass "file:$LAB_CA_PASSFILE")
  pass_in=(-passin "file:$LAB_CA_PASSFILE")
fi

cfg=$(mktemp)
cat >"$cfg" <<'EOF'
[req]
distinguished_name = dn
[dn]
[v3_root]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
# Mọi chứng chỉ phía dưới chỉ được mang tên DNS thuộc ba cây này (RFC 5280 §4.2.1.10).
# Name constraints chỉ ràng buộc loại tên được liệt kê, nên phải cấm riêng IP SAN (IPv4 và IPv6);
# lab truy cập HTTPS bằng tên *.lab.internal, không bằng IP.
nameConstraints      = critical, permitted;DNS:lab.internal, permitted;DNS:svc, permitted;DNS:svc.cluster.local, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:::/::
EOF

echo "Tạo khóa EC P-384 mã hóa AES-256 tại $key"
"$openssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -aes-256-cbc \
  ${pass_out[@]+"${pass_out[@]}"} -out "$key_tmp"

echo "Ký chứng chỉ root tự ký, hạn $days ngày"
"$openssl" req -x509 -new -key "$key_tmp" ${pass_in[@]+"${pass_in[@]}"} \
  -subj "$subject" -days "$days" -sha384 \
  -config "$cfg" -extensions v3_root -out "$out_crt"
chmod 644 "$out_crt"
mv "$key_tmp" "$key"
finished=1

echo
"$openssl" x509 -in "$out_crt" -noout -subject -enddate -fingerprint -sha256
echo
echo "Xong. Việc tiếp theo:"
echo "  1. Sao lưu $key và passphrase vào password manager (mất khóa = tạo root mới, tin lại ở mọi nơi)."
echo "  2. Commit $out_crt (chỉ phần công khai)."
echo "  3. Tin root trên Mac (runbook homelab mục 8.8 bước 3), so fingerprint SHA-256 ở trên với Keychain."
