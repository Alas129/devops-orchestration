{{- define "ai-bot.name" -}}
ai-bot
{{- end }}

{{- define "ai-bot.labels" -}}
app.kubernetes.io/name: ai-bot
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "ai-bot.selectorLabels" -}}
app.kubernetes.io/name: ai-bot
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
