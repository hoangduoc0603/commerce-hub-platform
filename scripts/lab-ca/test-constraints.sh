#!/usr/bin/env bash
# Kiểm make-root.sh sinh root có name constraints đúng và có tác dụng. Không đụng root thật.
# Dựng chuỗi tạm root → intermediate → leaf trong thư mục tạm, kiểm từng leaf bằng `openssl verify`,
# rồi xóa hết. Intermediate cố ý KHÔNG có name constraints riêng: tình huống xấu nhất khi lộ khóa
# intermediate trong cụm, chỉ còn ràng buộc của root chặn được.
# In PASS/FAIL từng trường hợp; exit 1 nếu có FAIL.
#
#   test-constraints.sh
#
# Chuẩn: docs/standards/cluster-entry.md mục "PKI và cert-manager". Ticket: G0-02.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"
OPENSSL=$(pick_openssl); export OPENSSL
openssl() { "$OPENSSL" "$@"; }
echo "Dùng $("$OPENSSL" version)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

# Passphrase giả chỉ sống trong thư mục tạm này.
printf 'test-only-throwaway\n' >pass

mkroot() { # mkroot <thư mục khóa> <file chứng chỉ> [subject]: chạy make-root.sh, output vào mkroot.log
  LAB_CA_DIR=$1 LAB_CA_OUT=$2 LAB_CA_PASSFILE=$tmp/pass LAB_CA_SUBJECT=${3:-/O=test/CN=test root} \
    "$here/make-root.sh" >mkroot.log 2>&1
}
mkroot "$tmp/ca" "$tmp/root.crt" || { cat mkroot.log >&2; echo "FAIL  make-root.sh không tạo được root thử"; exit 1; }

fail=0
check() { # check <mô tả> <lệnh...>: PASS nếu lệnh thành công
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $what"; else echo "FAIL  $what"; fail=1; fi
}

ext=$(openssl x509 -in root.crt -noout -ext basicConstraints,keyUsage,nameConstraints)
check "root: Basic Constraints critical" grep -q 'Basic Constraints: critical' <<<"$ext"
check "root: CA:TRUE" grep -q 'CA:TRUE' <<<"$ext"
check "root: keyUsage keyCertSign, cRLSign" grep -q 'Certificate Sign, CRL Sign' <<<"$ext"
check "root: nameConstraints critical" grep -q 'Name Constraints: critical' <<<"$ext"
check "root: khóa được mã hóa" grep -q 'ENCRYPTED PRIVATE KEY' ca/lab-root-ca.key

rerun_refused() { # chạy lại bị từ chối ĐÚNG vì đã có khóa, và khóa cũ không đổi
  local before; before=$(shasum -a 256 ca/lab-root-ca.key)
  ! mkroot "$tmp/ca" "$tmp/root2.crt" && grep -q 'đã có khóa' mkroot.log \
    && [[ $(shasum -a 256 ca/lab-root-ca.key) == "$before" ]]
}
check "chạy lại make-root.sh bị từ chối, khóa cũ giữ nguyên" rerun_refused

sign_fail_clean() { # ký lỗi (subject sai cú pháp) thì không để lại khóa, khóa tạm hay chứng chỉ
  ! mkroot "$tmp/ca-bad" "$tmp/bad.crt" "subject-sai-cu-phap" \
    && [[ ! -e $tmp/ca-bad/lab-root-ca.key && ! -e $tmp/ca-bad/.lab-root-ca.key.partial && ! -e $tmp/bad.crt ]]
}
check "ký lỗi không để lại khóa mồ côi" sign_fail_clean

in_repo_refused() { # thư mục khóa lồng sâu, chưa tồn tại, nằm trong một repo Git: bị chặn, không tạo gì
  git init -q "$tmp/repo"
  ! mkroot "$tmp/repo/a/b/ca" "$tmp/repo.crt" && grep -q 'repo Git' mkroot.log && [[ ! -e $tmp/repo/a ]]
}
check "thư mục khóa trong repo Git bị từ chối" in_repo_refused

# Intermediate tạm, không có name constraints riêng.
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout int.key \
  -subj "/CN=test intermediate" -out int.csr 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >int.ext
openssl x509 -req -in int.csr -CA root.crt -CAkey ca/lab-root-ca.key -passin file:pass \
  -days 1 -extfile int.ext -out int.crt 2>/dev/null

leaf() { # leaf <tên file> <subjectAltName>
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" \
    -subj "/CN=$1" -out "$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$2" >"$1.ext"
  openssl x509 -req -in "$1.csr" -CA int.crt -CAkey int.key -days 1 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}
verify() { # verify <tên file> <chuỗi mong đợi trong kết quả>
  # Không pipe thẳng vào grep: với pipefail, mã thoát 2 của `openssl verify` (khi từ chối, đúng như
  # mong đợi) làm cả pipeline thất bại dù grep tìm thấy chuỗi.
  local out
  out=$(openssl verify -CAfile root.crt -untrusted int.crt "$1.crt" 2>&1 || true)
  grep -q -- "$2" <<<"$out"
}

leaf ok         "DNS:ok.lab.internal";            check "leaf ok.lab.internal: chấp nhận"                verify ok         ': OK'
leaf wildcard   "DNS:*.lab.internal";             check "leaf *.lab.internal: chấp nhận"                 verify wildcard   ': OK'
leaf svc        "DNS:kc-service.keycloak.svc";    check "leaf kc-service.keycloak.svc: chấp nhận"        verify svc        ': OK'
leaf svclocal   "DNS:kc-service.keycloak.svc.cluster.local"
check "leaf ...svc.cluster.local: chấp nhận" verify svclocal ': OK'
leaf evil       "DNS:evil.example.com";           check "leaf evil.example.com: từ chối"                 verify evil       'permitted subtree violation'
leaf lookalike  "DNS:lab.internal.evil.com";      check "leaf lab.internal.evil.com: từ chối"            verify lookalike  'permitted subtree violation'
leaf suffix     "DNS:evillab.internal";           check "leaf evillab.internal: từ chối"                 verify suffix     'permitted subtree violation'
leaf mixed      "DNS:ok.lab.internal,DNS:github.com"
check "leaf có thêm một tên ngoài: từ chối" verify mixed 'permitted subtree violation'
leaf ipv4       "DNS:ip.lab.internal,IP:10.20.0.200"
check "leaf có IP SAN IPv4: từ chối" verify ipv4 'excluded subtree violation'
leaf ipv6       "DNS:ip6.lab.internal,IP:::1"
check "leaf có IP SAN IPv6: từ chối" verify ipv6 'excluded subtree violation'

exit $fail
