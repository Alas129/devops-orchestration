{{- define "frontend.name" -}}frontend{{- end -}}
{{- define "frontend.fullname" -}}frontend{{- end -}}

{{- define "frontend.labels" -}}
app.kubernetes.io/name: frontend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
env: {{ .Values.env }}
{{- end -}}

{{- define "frontend.selectorLabels" -}}
app.kubernetes.io/name: frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
