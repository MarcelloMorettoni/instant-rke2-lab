{{/* Image: <global.imageRegistry or the image's own registry>/<repository>:<tag>. (dict "ctx" . "img" <images.x>) */}}
{{- define "demo.image" -}}
{{- $reg := trimSuffix "/" (default (default "" .img.registry) .ctx.Values.global.imageRegistry) -}}
{{- if $reg -}}{{ printf "%s/%s:%s" $reg .img.repository .img.tag }}{{- else -}}{{ printf "%s:%s" .img.repository .img.tag }}{{- end -}}
{{- end }}

{{- define "demo.labels" -}}
app.kubernetes.io/part-of: log-flow-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Read-gateway views: one per tenant (its own data) and platform (everything). YAML list. */}}
{{- define "demo.views" -}}
{{- $all := list "platform" "unassigned" }}
{{- range .Values.tenants }}{{- $all = append $all .id }}{{- end }}
{{- range .Values.tenants }}
- {view: {{ .id }}, title: {{ .title | quote }}, tenants: [{{ .id }}]}
{{- end }}
- {view: platform, title: "Platform (admin)", tenants: {{ toJson $all }}}
{{- end }}

{{/* A view's key, DERIVED from demoKeySeed (demo only). (list ctx view) */}}
{{- define "demo.key" -}}
{{- printf "%s:%s" (index . 0).Values.demoKeySeed (index . 1) | sha256sum | trunc 40 -}}
{{- end }}

{{/* Owners of data in Loki: platform, unassigned, every tenant. */}}
{{- define "demo.owners" -}}
{{- $o := list "platform" "unassigned" }}
{{- range .Values.tenants }}{{- $o = append $o .id }}{{- end }}
{{- toJson $o }}
{{- end }}

{{/* The grafana-sync pod (Job and CronJob). */}}
{{- define "demo.syncPod" -}}
metadata:
  labels: {app.kubernetes.io/name: grafana-sync}
spec:
  restartPolicy: OnFailure
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001}
  containers:
    - name: sync
      image: {{ include "demo.image" (dict "ctx" . "img" .Values.images.python) }}
      command: [python3, /config/grafana-sync.py]
      env:
        - {name: PYTHONDONTWRITEBYTECODE, value: "1"}
        - {name: GRAFANA_URL, value: {{ printf "http://grafana.%s.svc.cluster.local" .Release.Namespace | quote }}}
        - {name: READ_GATEWAY, value: {{ printf "http://obs-gateway.%s.svc.cluster.local:8080" .Release.Namespace | quote }}}
        - {name: RECORDED_METRICS, value: "true"}
        - name: GF_ADMIN_USER
          valueFrom: {secretKeyRef: {name: grafana-admin, key: admin-user}}
        - name: GF_ADMIN_PASSWORD
          valueFrom: {secretKeyRef: {name: grafana-admin, key: admin-password}}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 128Mi}
      volumeMounts:
        - {name: config, mountPath: /config, readOnly: true}
        - {name: keys, mountPath: /keys, readOnly: true}
        - {name: local-users, mountPath: /local, readOnly: true}
  volumes:
    - name: config
      configMap: {name: grafana-sync}
    - name: keys
      secret: {secretName: obs-gateway-keys}
    - name: local-users
      secret: {secretName: grafana-local-users}
{{- end }}
