{{/*
Helper dùng chung cho mọi template. File bắt đầu bằng _ nên Helm không render nó thành manifest.
*/}}

{{/*
app.name: giá trị nhãn app.kubernetes.io/name, tức tên ứng dụng (hello, order...).
Chart dùng chung nên lấy tên release, không lấy tên chart: tên chart lúc nào cũng là "app".
Cắt 63 ký tự vì giá trị nhãn tối đa 63 ký tự.
*/}}
{{- define "app.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
app.fullname: tên của mọi resource (Deployment, Service, SA...). Tên release là tên Application của Argo CD,
mỗi namespace một service, nên không cần ghép thêm tên chart.
*/}}
{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
app.chart: nhãn helm.sh/chart = <tên chart>-<version>. "+" của SemVer build metadata không hợp lệ trong nhãn.
*/}}
{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
app.selectorLabels: chỉ name và instance. Selector của Deployment không đổi được sau khi tạo, nên không đưa
nhãn hay đổi (version, helm.sh/chart) vào đây.
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
app.labels: bộ nhãn chung cho metadata của mọi resource (helm-chart.md "Labels").
version chỉ có khi values có image.tag.
*/}}
{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/part-of: commerce-hub
{{- with .Values.image.tag }}
app.kubernetes.io/version: {{ . | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
{{- end }}

{{/*
app.serviceAccountName: tên SA mà pod dùng (bước 2 gọi trong Deployment).
*/}}
{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
app.javaToolOptions: giá trị biến JAVA_TOOL_OPTIONS. jvm.extraOptions đứng đầu, cờ của chart đứng sau:
JVM lấy giá trị xuất hiện sau cùng, nên values không ghi đè được cờ của chart, kể cả cờ truststore.
Không đặt trustStorePassword: Bundle lab-trust để mật khẩu rỗng, trust-manager ghi PKCS12 không mã hóa (G0-07).
*/}}
{{- define "app.javaToolOptions" -}}
{{- $opts := list }}
{{- with .Values.jvm.extraOptions }}
{{- $opts = append $opts . }}
{{- end }}
{{- $opts = append $opts (printf "-XX:MaxRAMPercentage=%v" .Values.jvm.maxRAMPercentage) }}
{{- $opts = append $opts (printf "-XX:ActiveProcessorCount=%v" .Values.jvm.activeProcessorCount) }}
{{- if .Values.trust.enabled }}
{{- $opts = append $opts (printf "-Djavax.net.ssl.trustStore=%s/bundle.p12" (include "app.trustDir" .)) }}
{{- $opts = append $opts "-Djavax.net.ssl.trustStoreType=PKCS12" }}
{{- end }}
{{- join " " $opts }}
{{- end }}

{{/*
app.trustDir: thư mục mount trust bundle. Một chỗ cho volumeMount, cờ JVM và NODE_EXTRA_CA_CERTS.
*/}}
{{- define "app.trustDir" -}}
/etc/trust
{{- end }}
