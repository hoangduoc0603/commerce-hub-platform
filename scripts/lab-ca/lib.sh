# Hàm dùng chung cho scripts/lab-ca. Chỉ source, không chạy trực tiếp.

die() { echo "LỖI: $*" >&2; exit 1; }

is_openssl_3_or_4() {
  case "$("$1" version 2>/dev/null)" in
    "OpenSSL 3."* | "OpenSSL 4."*) return 0 ;;
    *) return 1 ;;
  esac
}

# In đường dẫn một openssl là OpenSSL 3 hoặc 4. /usr/bin/openssl trên macOS là LibreSSL: khác cú pháp
# và hành vi kiểm name constraints, nên không phụ thuộc thứ tự PATH. Biến OPENSSL nếu đã đặt thì phải
# hợp lệ, không lặng lẽ rơi về bản khác.
pick_openssl() {
  if [[ -n ${OPENSSL:-} ]]; then
    [[ -x $OPENSSL ]] && is_openssl_3_or_4 "$OPENSSL" \
      || die "OPENSSL=$OPENSSL không phải OpenSSL 3 hoặc 4 chạy được"
    echo "$OPENSSL"; return 0
  fi
  local c
  for c in "$(command -v openssl || true)" /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    [[ -x $c ]] && is_openssl_3_or_4 "$c" && { echo "$c"; return 0; }
  done
  die "không tìm thấy OpenSSL 3 hoặc 4 (brew install openssl, hoặc đặt OPENSSL=<đường dẫn>)"
}
