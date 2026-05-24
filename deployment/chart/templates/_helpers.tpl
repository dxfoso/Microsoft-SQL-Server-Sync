{{- define "sync-admin-web.name" -}}
sync-admin-web
{{- end -}}

{{- define "sync-admin-web.fullname" -}}
sql-sync
{{- end -}}

{{- define "sync-admin-web.resourceNamespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- define "sync-admin-web.componentFullname" -}}
{{- $root := index . 0 -}}
{{- $suffix := index . 1 -}}
{{- printf "%s-%s" (include "sync-admin-web.fullname" $root) $suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sync-admin-web.frontendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "front") -}}
{{- end -}}

{{- define "sync-admin-web.backendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "back") -}}
{{- end -}}

{{- define "sync-admin-web.postgresFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "postgres") -}}
{{- end -}}

{{- define "sync-admin-web.backendDataPvcName" -}}
{{- include "sync-admin-web.componentFullname" (list . "back-data") -}}
{{- end -}}

{{- define "sync-admin-web.postgresPvcName" -}}
{{- include "sync-admin-web.componentFullname" (list . "postgres-data") -}}
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

{{- define "sync-admin-web.imagePullPolicy" -}}
Always
{{- end -}}

{{- define "sync-admin-web.backendPostgresUrl" -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" .Values.postgres.username .Values.postgres.password (include "sync-admin-web.postgresFullname" .) .Values.postgres.service.port .Values.postgres.database -}}
{{- end -}}

{{- define "sync-admin-web.certManagerAnnotationKey" -}}
{{- if eq (.Values.certManager.issuerKind | default "ClusterIssuer") "Issuer" -}}
cert-manager.io/issuer
{{- else -}}
cert-manager.io/cluster-issuer
{{- end -}}
{{- end -}}
