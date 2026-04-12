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

{{- define "sync-admin-web.registrySecretName" -}}
{{ include "sync-admin-web.fullname" . }}-registry
{{- end -}}

{{- define "sync-admin-web.registrySecretData" -}}
{{- $auth := printf "%s:%s" .Values.dockerUsername .Values.dockerPassword | b64enc -}}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .Values.dockerRegistry .Values.dockerUsername .Values.dockerPassword .Values.dockerEmail $auth | b64enc -}}
{{- end -}}

{{- define "sync-admin-web.certManagerAnnotationKey" -}}
{{- if eq (.Values.certManager.issuerKind | default "ClusterIssuer") "Issuer" -}}
cert-manager.io/issuer
{{- else -}}
cert-manager.io/cluster-issuer
{{- end -}}
{{- end -}}
