{{- define "cnpg-i-zeropod.name" -}}
cnpg-i-zeropod
{{- end }}

{{- define "cnpg-i-zeropod.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "cnpg-i-zeropod.labels" -}}
app: {{ include "cnpg-i-zeropod.name" . }}
app.kubernetes.io/name: {{ include "cnpg-i-zeropod.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "cnpg-i-zeropod.selectorLabels" -}}
app: {{ include "cnpg-i-zeropod.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "cnpg-i-zeropod.serviceAccountName" -}}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name }}
{{- else }}
{{- include "cnpg-i-zeropod.fullname" . }}
{{- end }}
{{- end }}

{{- define "cnpg-i-zeropod.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}
