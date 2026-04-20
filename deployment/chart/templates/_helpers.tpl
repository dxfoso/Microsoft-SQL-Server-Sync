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
{{- $base := include "sync-admin-web.fullname" $root -}}
{{- $budget := int (sub 63 (add 1 (len $suffix))) -}}
{{- printf "%s-%s" ($base | trunc $budget | trimSuffix "-") $suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sync-admin-web.frontendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "front") -}}
{{- end -}}

{{- define "sync-admin-web.backendFullname" -}}
{{- include "sync-admin-web.componentFullname" (list . "back") -}}
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

{{- define "sync-admin-web.imageRef" -}}
{{- $image := . -}}
{{- if kindIs "string" $image -}}
{{- $image -}}
{{- else -}}
{{- $repository := $image.repository | default "" | lower -}}
{{- $tag := $image.tag | default "" -}}
{{- $hasDigest := contains "@" $repository -}}
{{- $hasTag := regexMatch ".+:[^/]+$" $repository -}}
{{- if or $hasDigest $hasTag (eq $tag "") -}}
{{- $repository -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sync-admin-web.componentImageRepository" -}}
{{- $repository := index . 0 | default "" | lower -}}
{{- $component := index . 1 -}}
{{- $dockerRegistry := "" -}}
{{- if ge (len .) 3 -}}
{{- $dockerRegistry = index . 2 | default "" -}}
{{- end -}}
{{- if and $dockerRegistry (not (contains "/" $repository)) -}}
{{- $repository = printf "%s/%s" $dockerRegistry $repository -}}
{{- end -}}
{{- $repository = trimSuffix "/frontend" $repository -}}
{{- $repository = trimSuffix "/backend" $repository -}}
{{- printf "%s/%s" ($repository | trimSuffix "/") $component -}}
{{- end -}}

{{- define "sync-admin-web.imagePullPolicy" -}}
{{- $image := . -}}
{{- if and (kindIs "map" $image) $image.pullPolicy -}}
{{- $image.pullPolicy -}}
{{- else -}}
Always
{{- end -}}
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
{{- $issuerName := .Values.certManager.issuerName | default "" -}}
{{- if or (eq $issuerName "") (eq $issuerName "sync-admin-web-letsencrypt") -}}
letsencrypt-http01
{{- else -}}
{{- $issuerName -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sync-admin-web.certManagerShouldManageTls" -}}
{{- $enabled := false -}}
{{- if .Values.certManager -}}
{{- if hasKey .Values.certManager "enabled" -}}
{{- $enabled = .Values.certManager.enabled -}}
{{- else -}}
{{- $enabled = true -}}
{{- end -}}
{{- end -}}
{{- if $enabled -}}
true
{{- else -}}
{{- $tlsConfigured := and .Values.frontend .Values.frontend.ingress .Values.frontend.ingress.enabled .Values.frontend.ingress.tls -}}
{{- if $tlsConfigured -}}
{{- $tls := index .Values.frontend.ingress.tls 0 -}}
{{- if and $tls $tls.secretName -}}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $tls.secretName -}}
{{- if $existingSecret -}}
false
{{- else -}}
true
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
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
