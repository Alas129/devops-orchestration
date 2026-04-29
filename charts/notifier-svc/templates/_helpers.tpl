{{- define "notifier-svc.name" -}}notifier-svc{{- end -}}
{{- define "notifier-svc.fullname" -}}{{- include "notifier-svc.name" . -}}{{- end -}}

{{- define "notifier-svc.labels" -}}
app.kubernetes.io/name: {{ include "notifier-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "notifier-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notifier-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
