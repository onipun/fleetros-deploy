{{/*
Common labels applied to every resource.
*/}}
{{- define "fleetros.labels" -}}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: fleetros
{{- end -}}

{{/*
Resolve fully-qualified image reference: <registry>/<image>:<tag>
*/}}
{{- define "fleetros.image" -}}
{{- $registry := .global.imageRegistry | default "docker.io" -}}
{{- printf "%s/%s:%s" $registry .image .tag -}}
{{- end -}}
