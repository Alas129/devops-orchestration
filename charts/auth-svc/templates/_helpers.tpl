{{- define "auth-svc.name" -}}auth-svc{{- end -}}
{{- define "auth-svc.fullname" -}}{{- include "auth-svc.name" . -}}{{- end -}}

{{- define "auth-svc.labels" -}}
app.kubernetes.io/name: {{ include "auth-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "auth-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "auth-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
