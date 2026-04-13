{{- define "sync-admin-web.name" -}}
sync-admin-web
{{- end -}}

{{- define "sync-admin-web.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "sync-admin-web.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sync-admin-web.componentFullname" -}}
{{- $root := index . 0 -}}
{{- $suffix := index . 1 -}}
{{- $base := printf "%s-%s" $root.Release.Name (include "sync-admin-web.name" $root) -}}
{{- $budget := int (sub 63 (add 1 (len $suffix))) -}}
{{- printf "%s-%s" ($base | trunc $budget | trimSuffix "-") $suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sync-admin-web.frontendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "frontend") -}}
{{- end -}}

{{- define "sync-admin-web.backendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "backend") -}}
{{- end -}}

{{- define "sync-admin-web.backendEnabled" -}}
{{- if .Values.backend -}}
{{- if hasKey .Values.backend "enabled" -}}
{{- .Values.backend.enabled -}}
{{- else -}}
true
{{- end -}}
{{- else -}}
false
{{- end -}}
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

{{- define "sync-admin-web.certManagerCreateClusterIssuer" -}}
{{- if hasKey .Values.certManager "createClusterIssuer" -}}
{{- .Values.certManager.createClusterIssuer -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{- define "sync-admin-web.certManagerIssuerName" -}}
{{- if eq (include "sync-admin-web.certManagerCreateClusterIssuer" .) "true" -}}
{{- printf "%s-letsencrypt" (include "sync-admin-web.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Values.certManager.issuerName | default "letsencrypt-prod" -}}
{{- end -}}
{{- end -}}

{{- define "sync-admin-web.certManagerIssuerKind" -}}
{{- if eq (include "sync-admin-web.certManagerCreateClusterIssuer" .) "true" -}}
ClusterIssuer
{{- else -}}
{{- .Values.certManager.issuerKind | default "ClusterIssuer" -}}
{{- end -}}
{{- end -}}

{{- define "sync-admin-web.certManagerAnnotationKey" -}}
{{- if eq (include "sync-admin-web.certManagerIssuerKind" .) "Issuer" -}}
cert-manager.io/issuer
{{- else -}}
cert-manager.io/cluster-issuer
{{- end -}}
{{- end -}}
