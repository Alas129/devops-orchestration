{{- define "tasks-svc.name" -}}tasks-svc{{- end -}}
{{- define "tasks-svc.fullname" -}}{{- include "tasks-svc.name" . -}}{{- end -}}

{{- define "tasks-svc.labels" -}}
app.kubernetes.io/name: {{ include "tasks-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "tasks-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tasks-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
