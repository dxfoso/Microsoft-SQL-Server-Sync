{{- define "sync-admin-web.name" -}}
sync-admin-web
{{- end -}}

{{- define "sync-admin-web.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "sync-admin-web.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sync-admin-web.labels" -}}
app.kubernetes.io/name: {{ include "sync-admin-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}
