{{/*
Phần pod dùng chung cho Deployment và Job migrate (ticket 27). Job chạy cùng image nên phải cùng Pod Security,
cùng /tmp ghi được, cùng truststore và cờ JVM; tách ra đây để hai nơi không lệch nhau.
*/}}

{{/*
app.image: image theo digest. required ở đây nên Deployment và Job báo cùng một thông điệp.
*/}}
{{- define "app.image" -}}
{{ required "image.repository là bắt buộc, ví dụ ghcr.io/hoangduoc0603/commerce-hub-hello" .Values.image.repository }}@{{ required "image.digest là bắt buộc (sha256:...), CI ghi vào gitops" .Values.image.digest }}
{{- end }}

{{/*
app.podSecurityContext: Pod Security Standards "restricted" (helm-chart.md "Bảo mật pod"). Không mở qua values.
*/}}
{{- define "app.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.securityContext.runAsUser }}
runAsGroup: {{ .Values.securityContext.runAsGroup }}
fsGroup: {{ .Values.securityContext.runAsGroup }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
app.containerSecurityContext: phần "restricted" ở mức container, root filesystem chỉ đọc.
*/}}
{{- define "app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
app.runtimeEnv: phần tử env do chart đặt (JAVA_TOOL_OPTIONS hoặc NODE_EXTRA_CA_CERTS). Rỗng nếu không có gì.
Workload không chạy JVM trong dự án là Node (seller-web): trust đi qua NODE_EXTRA_CA_CERTS.
*/}}
{{- define "app.runtimeEnv" -}}
{{- if .Values.jvm.enabled }}
- name: JAVA_TOOL_OPTIONS
  value: {{ include "app.javaToolOptions" . | quote }}
{{- else if .Values.trust.enabled }}
{{- /* Chỉ root lab: biến này THÊM vào root có sẵn của Node, trỏ vào gói CA công khai sẽ tin lại root Node đã gỡ. */}}
- name: NODE_EXTRA_CA_CERTS
  value: {{ include "app.trustDir" . }}/lab-root-ca.pem
{{- end }}
{{- end }}

{{/*
app.secretEnv: phần tử env lấy từ Secret. Gọi với dict "map" (secretEnv hoặc migration.secretEnv) và "path"
(tên value, để thông điệp lỗi chỉ đúng chỗ).
secretEnv: mỗi biến lấy MỘT key của một Secret (ticket 27 Q3). Không dùng envFrom.secretRef: Secret basic-auth có
key username/password, envFrom sẽ sinh biến tên "password" mà Spring không đọc. Secret hoặc key không tồn tại thì
pod kẹt CreateContainerConfigError: lỗi lộ ngay, không âm thầm rỗng.
*/}}
{{- define "app.secretEnv" -}}
{{- $path := .path }}
{{- range $envName, $ref := .map }}
{{- /* Trùng tên thì Kubernetes lấy phần tử sau, ghi đè cờ JVM và truststore của chart (review G0-27). */}}
{{- if has $envName (list "JAVA_TOOL_OPTIONS" "NODE_EXTRA_CA_CERTS") }}
{{- fail (printf "%s.%s: biến này do chart đặt, không lấy từ Secret được" $path $envName) }}
{{- end }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf "%s.%s.secret là bắt buộc" $path $envName) $ref.secret }}
      key: {{ required (printf "%s.%s.key là bắt buộc" $path $envName) $ref.key }}
{{- end }}
{{- end }}

{{/*
app.resources: memory limit = request, không CPU limit (helm-chart.md "Tài nguyên và JVM"). Gọi với dict
"resources" và "path".
*/}}
{{- define "app.resources" -}}
{{- $memory := required (printf "%s.requests.memory là bắt buộc, ví dụ 512Mi" .path) .resources.requests.memory -}}
requests:
  cpu: {{ required (printf "%s.requests.cpu là bắt buộc, ví dụ 250m" .path) .resources.requests.cpu | quote }}
  memory: {{ $memory | quote }}
limits:
  memory: {{ $memory | quote }}
{{- end }}

{{/*
app.volumeMounts, app.volumes: /tmp ghi được (root filesystem chỉ đọc) và trust bundle.
*/}}
{{- define "app.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- if .Values.trust.enabled }}
- name: trust
  mountPath: {{ include "app.trustDir" . }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "app.volumes" -}}
- name: tmp
  emptyDir:
    sizeLimit: {{ .Values.tmp.sizeLimit }}
{{- if .Values.trust.enabled }}
{{- /*
Gộp hai ConfigMap do trust-manager chép vào namespace (gitops infra/lab-ca/bundles.yaml) vào một thư mục.
Một Bundle chỉ ghi được một key PEM nên phải hai nguồn. Không optional: thiếu ConfigMap thì pod kẹt
ContainerCreating, lỗi lộ ngay thay vì JVM lặng lẽ dùng cacerts. projected/configMap hợp PSS restricted.
Root đổi thì trust-manager cập nhật file, nhưng JVM và Node chỉ đọc lúc khởi động: phải restart pod.
*/}}
- name: trust
  projected:
    sources:
      - configMap:
          name: lab-trust
          items:
            - key: bundle.p12
              path: bundle.p12
      - configMap:
          name: lab-root
          items:
            - key: ca.crt
              path: lab-root-ca.pem
{{- end }}
{{- end }}
