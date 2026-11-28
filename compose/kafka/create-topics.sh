#!/bin/bash
# Bước 2 của init topic (container kafka-topics, image apache/kafka): tạo từng topic trong /plan/topics.txt do
# plan-topics.sh sinh từ CR KafkaTopic của gitops.
#
# --if-not-exists: chạy lại mỗi lần `up` không lỗi. Hệ quả: sửa partitions hay config của topic đã có trong gitops thì
# compose KHÔNG cập nhật theo (khác Topic Operator của lab). Muốn áp lại: docker compose down -v, hoặc xóa riêng topic đó
# bằng kafka-topics.sh --delete rồi docker compose up kafka-topics.
set -euo pipefail

plan=/plan/topics.txt
bootstrap=kafka:9092

if ! grep -q . "$plan"; then
  echo "Không có KafkaTopic nào trong gitops, không tạo topic"
  exit 0
fi

while read -r name partitions configs; do
  [[ -z "$name" ]] && continue
  args=()
  for c in $configs; do
    args+=(--config "$c")
  done
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" --create --if-not-exists \
    --topic "$name" --partitions "$partitions" --replication-factor 1 "${args[@]}"
done < "$plan"

/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" --list
