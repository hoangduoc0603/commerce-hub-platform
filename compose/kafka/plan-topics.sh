#!/bin/sh
# Bước 1 của init topic (container kafka-topics-plan, image mikefarah/yq): tìm mọi CR KafkaTopic của Strimzi trong bản
# checkout gitops (mount ở /gitops), ghi mỗi topic một dòng vào /plan/topics.txt:
#   <tên topic> <partitions> [<key>=<value> ...]
# Bước 2 (create-topics.sh) đọc file này. Nhờ vậy partition, retention, compaction giống lab mà không chép danh sách
# topic vào platform (ticket 13 của map kiến trúc, Q5).
#
# Bỏ min.insync.replicas: compose có 1 broker, giữ giá trị của lab (2) thì producer acks=all lỗi NotEnoughReplicas.
# Không đọc spec.replicas: compose luôn tạo replication factor 1.
# Giả định giá trị config không chứa dấu cách (đúng với mọi config topic của Kafka).
set -eu

out=/plan/topics.txt

# Bỏ thư mục upstream/ (CRD và manifest tải về của bên thứ ba) và .git. Chỉ file YAML: dashboard JSON không phải CR.
find /gitops \( -name .git -o -name upstream \) -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print \
  | sort > /tmp/files

# `eval` (không phải eval-all): biểu thức chạy riêng trên từng document, nên [...] chỉ gom giá trị của một topic (eval-all
# gom mọi document vào một mảng, đã thử). --no-doc: không in "---" giữa các kết quả.
# Lỗi parse ở file nào thì yq dừng và in tên file, container thoát khác 0: không bỏ qua im lặng.
# shellcheck disable=SC2046 # Tên file trong gitops không chứa dấu cách.
yq eval --no-doc '
  select(.kind == "KafkaTopic")
  | [(.spec.topicName // .metadata.name), ((.spec.partitions // 1) | tostring)]
    + ((.spec.config // {}) | to_entries
       | map(select(.key != "min.insync.replicas") | .key + "=" + (.value | tostring)))
  | join(" ")
' $(cat /tmp/files) > "${out}.tmp"

mv "${out}.tmp" "$out"
echo "Đọc $(wc -l < /tmp/files) file YAML trong gitops, có $(grep -c . "$out" || true) KafkaTopic"
