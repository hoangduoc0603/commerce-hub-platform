#!/usr/bin/env bash
# Tạo intermediate CA của cụm lab, ký bằng root offline, và seal thẳng thành SealedSecret `lab-intermediate-ca`
# (namespace cert-manager) cho ClusterIssuer lab-ca. Khóa intermediate dạng rõ chỉ sống trong một thư mục tạm
# quyền 700 và bị xóa khi script kết thúc; nó không bao giờ nằm trên đĩa ngoài thư mục đó, trong Git hay trong log.
#
#   make-intermediate.sh [--replace] <file SealedSecret>
#   ví dụ: make-intermediate.sh ../gitops/infra/lab-ca/lab-intermediate-ca.sealedsecret.yaml
#
# Hỏi passphrase của khóa root MỘT lần (lúc ký). kubeseal lấy chứng chỉ sealing từ controller theo context kubectl
# hiện tại, trừ khi đặt LAB_SEAL_CERT.
#
#   --replace        ghi đè file đã có: xoay intermediate (sinh khóa MỚI, không gia hạn khóa cũ). Sau khi Argo CD
#                    áp, chạy `cmctl renew` cho mọi Certificate của lab-ca để leaf được ký lại bằng intermediate mới.
#
# Biến môi trường:
#   LAB_CA_DIR       thư mục chứa khóa root (mặc định ~/lab-ca).
#   LAB_CA_ROOT      chứng chỉ root (mặc định <platform>/pki/lab-root-ca.crt).
#   LAB_INT_SUBJECT  subject (mặc định "/O=commerce-hub lab/CN=commerce-hub lab intermediate CA <YYYYMMDD-HHMM>"; có
#                    giờ để intermediate xoay khẩn cấp trong cùng tháng không trùng subject với cái cũ).
#   LAB_KUBE_CONTEXT context kubectl để kubeseal lấy chứng chỉ sealing (mặc định homelab). Ghim để không seal nhầm
#                    bằng khóa của cụm khác (vd. cụm kind diễn tập) khi context hiện tại đang trỏ chỗ khác.
#   LAB_SEAL_CERT    chứng chỉ sealing để seal offline (`kubeseal --fetch-cert`). Test dùng khóa sealing giả.
#   LAB_CA_PASSFILE  file chứa passphrase của khóa root, thay cho hỏi tương tác. Chỉ dùng cho test-constraints.sh.
#   OPENSSL          đường dẫn openssl (mặc định tự tìm OpenSSL 3/4, bỏ qua LibreSSL của macOS).
#
# Vì sao các thông số (chuẩn: docs/standards/cluster-entry.md mục "PKI và cert-manager", ADR-0014; ticket G0-06):
# - Hạn 730 ngày: intermediate nằm trong cụm (lệch chuẩn có chủ đích), hạn ngắn giới hạn thời gian dùng được nếu lộ.
# - pathLenConstraint 0: intermediate chỉ ký leaf, không ký được CA con (RFC 5280 §4.2.1.9).
# - Name constraints lặp lại của root: lớp phòng thủ thứ hai, không phụ thuộc client có kiểm constraint ở root hay không.
# - EC P-256: cert-manager ký leaf bằng khóa này ở mỗi lần cấp; P-256 đủ mạnh, nhanh, mọi client hỗ trợ.
# - tls.crt = intermediate rồi root: cert-manager tách root (tự ký) ra làm ca.crt của chứng chỉ được cấp.
#   https://cert-manager.io/docs/configuration/ca/
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
openssl=$(pick_openssl)
command -v kubeseal >/dev/null || die "cần kubeseal (brew install kubeseal)"
command -v kubectl >/dev/null || die "cần kubectl (để dựng manifest Secret, không gọi cụm)"

replace=0
if [[ ${1:-} == --replace ]]; then replace=1; shift; fi
[[ $# -eq 1 ]] || die "cách dùng: make-intermediate.sh [--replace] <file SealedSecret>"
out=$1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ca_dir=${LAB_CA_DIR:-$HOME/lab-ca}
root_crt=${LAB_CA_ROOT:-$repo_root/pki/lab-root-ca.crt}
root_key=$ca_dir/lab-root-ca.key
subject=${LAB_INT_SUBJECT:-/O=commerce-hub lab/CN=commerce-hub lab intermediate CA $(date -u +%Y%m%d-%H%M)}
kube_context=${LAB_KUBE_CONTEXT:-homelab}
days=730

[[ -r $root_key ]] || die "không đọc được khóa root $root_key"
[[ -r $root_crt ]] || die "không đọc được chứng chỉ root $root_crt"
[[ -e $out && $replace == 0 ]] && die "đã có $out. Xoay intermediate thì chạy lại với --replace."
[[ -d $(dirname "$out") ]] || die "chưa có thư mục $(dirname "$out")"

# Intermediate không được sống lâu hơn root: client sẽ từ chối chuỗi khi root hết hạn trước.
"$openssl" x509 -in "$root_crt" -noout -checkend $((days * 86400)) >/dev/null \
  || die "root hết hạn trong vòng $days ngày: xoay root trước."

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass_in=()
[[ -n ${LAB_CA_PASSFILE:-} ]] && pass_in=(-passin "file:$LAB_CA_PASSFILE")

cat >"$work/ext.cnf" <<'EOF'
[v3_int]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
nameConstraints        = critical, permitted;DNS:lab.internal, permitted;DNS:svc, permitted;DNS:svc.cluster.local, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:::/::
EOF

echo "Tạo khóa EC P-256 cho intermediate (thư mục tạm, xóa khi kết thúc)"
"$openssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/int.key"
"$openssl" req -new -key "$work/int.key" -subj "$subject" -out "$work/int.csr"

echo "Ký intermediate bằng khóa root, hạn $days ngày (nhập passphrase của root)"
# OpenSSL 3+ tự sinh serial ngẫu nhiên khi không có -CAserial/-CAcreateserial.
"$openssl" x509 -req -in "$work/int.csr" -CA "$root_crt" -CAkey "$root_key" ${pass_in[@]+"${pass_in[@]}"} \
  -days "$days" -sha384 -extfile "$work/ext.cnf" -extensions v3_int -out "$work/int.crt"

# Tự kiểm trước khi seal: chuỗi hợp lệ với root (bắt nhầm khóa root với chứng chỉ root).
"$openssl" verify -CAfile "$root_crt" "$work/int.crt" >/dev/null || die "intermediate không xác minh được với root"
cat "$work/int.crt" "$root_crt" >"$work/chain.crt"

seal_args=(--format yaml)
if [[ -n ${LAB_SEAL_CERT:-} ]]; then
  seal_args+=(--cert "$LAB_SEAL_CERT")
else
  seal_args+=(--context "$kube_context")
  echo "Seal bằng chứng chỉ của controller trên context $kube_context"
fi

# kubectl --dry-run=client chỉ dựng manifest (và kiểm cặp khóa/chứng chỉ khớp), không gọi API server.
# Secret dạng rõ chỉ đi qua pipe sang kubeseal, không ghi ra đĩa.
fp=$("$openssl" x509 -in "$work/int.crt" -noout -fingerprint -sha256 | cut -d= -f2)
not_after=$("$openssl" x509 -in "$work/int.crt" -noout -enddate | cut -d= -f2)
{
  echo "# Intermediate CA của lab (ADR-0014), sinh bằng platform/scripts/lab-ca/make-intermediate.sh. KHÔNG sửa tay."
  echo "# Subject: ${subject}"
  echo "# Hết hạn: ${not_after}. Xoay trước 60 ngày: make-intermediate.sh --replace, rồi cmctl renew."
  echo "# SHA-256: ${fp}"
  kubectl create secret tls lab-intermediate-ca --namespace cert-manager \
    --cert "$work/chain.crt" --key "$work/int.key" --dry-run=client -o yaml \
    | kubeseal "${seal_args[@]}"
} >"$work/sealed.yaml"
grep -q 'kind: SealedSecret' "$work/sealed.yaml" || die "kubeseal không sinh SealedSecret"
umask 022
cp "$work/sealed.yaml" "$out"
chmod 644 "$out"

echo
"$openssl" x509 -in "$work/int.crt" -noout -subject -enddate -fingerprint -sha256
echo
echo "Xong: $out (đã seal, khóa dạng rõ đã xóa cùng thư mục tạm)."
echo "Đặt lịch nhắc xoay intermediate 60 ngày trước ${not_after}."
