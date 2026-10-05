{{/* <global.imageRegistry or quay.io>/<path>:<tag> */}}
{{- define "ops.image" -}}
{{- $reg := trimSuffix "/" (default "quay.io" .ctx.Values.global.imageRegistry) -}}
{{- printf "%s/%s:%s" $reg .path .tag -}}
{{- end }}
