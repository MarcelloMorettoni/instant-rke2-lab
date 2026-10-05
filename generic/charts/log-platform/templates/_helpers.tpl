{{/* Image reference: <global.imageRegistry>/<repository>:<tag>, or <repository>:<tag>. */}}
{{- define "lp.image" -}}
{{- $reg := trimSuffix "/" (default "" .ctx.Values.global.imageRegistry) -}}
{{- if $reg -}}{{ printf "%s/%s:%s" $reg .repository .tag }}{{- else -}}{{ printf "%s:%s" .repository .tag }}{{- end -}}
{{- end }}

{{/* nodeSelector + tolerations for the platform's own pods. */}}
{{- define "lp.placement" -}}
{{- with .Values.placement.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.placement.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "lp.labels" -}}
app.kubernetes.io/part-of: log-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* ipBlock peers from a list of CIDRs. */}}
{{- define "lp.cidrs" -}}
{{- range . }}
- ipBlock: {cidr: {{ . | quote }}}
{{- end }}
{{- end }}

{{/* DNS egress rule to kube-dns. */}}
{{- define "lp.dnsEgress" -}}
- to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
      podSelector:
        matchLabels: {k8s-app: kube-dns}
  ports:
    - {port: 53, protocol: UDP}
    - {port: 53, protocol: TCP}
{{- end }}

{{/* Public HTTPS (Entra ID, webhooks) through the hub firewall. */}}
{{- define "lp.internet443" -}}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
  ports:
    - {port: 443, protocol: TCP}
{{- end }}

{{/* Scrapers: AKS managed Prometheus (ama-metrics) and/or a Prometheus Operator's Prometheus. */}}
{{- define "lp.metricsPeers" -}}
{{- if .Values.monitoring.azurePodMonitors }}
- namespaceSelector:
    matchLabels: {kubernetes.io/metadata.name: kube-system}
  podSelector:
    matchExpressions:
      - {key: rsName, operator: In, values: [ama-metrics]}
{{- end }}
{{- if .Values.monitoring.prometheusOperator.enabled }}
- namespaceSelector:
    matchLabels: {kubernetes.io/metadata.name: {{ .Values.monitoring.prometheusOperator.namespace }}}
  podSelector:
    matchLabels: {app.kubernetes.io/name: prometheus}
{{- end }}
{{- if not (or .Values.monitoring.azurePodMonitors .Values.monitoring.prometheusOperator.enabled) }}
- podSelector:
    matchLabels: {obs.platform/no-scraper: "true"}   # no scraper configured: nobody
{{- end }}
{{- end }}

{{/* Keycloak endpoints for Grafana: keycloak.install fills in the defaults. */}}
{{- define "lp.keycloak" -}}
{{- $a := .Values.auth.keycloak }}
{{- $k := .Values.keycloak }}
{{- $url := $a.url | default (ternary (printf "https://%s" $k.hostname) "" $k.install) }}
url: {{ trimSuffix "/" $url | quote }}
internalUrl: {{ trimSuffix "/" ($a.internalUrl | default (ternary "http://keycloak-service.keycloak.svc.cluster.local:8080" $url $k.install)) | quote }}
realm: {{ $a.realm | default (ternary $k.realm.name "" $k.install) | quote }}
{{- end }}

{{/* A Secret's existing data (Helm lookup), so generated values survive upgrades: (list ctx namespace name) */}}
{{- define "lp.existing" -}}
{{- (lookup "v1" "Secret" (index . 1) (index . 2)).data | default dict | toYaml }}
{{- end }}

{{/* Pod placement for CRD-managed pods (Strimzi, Keycloak): the platform's
     node pool as nodeAffinity (their templates have no nodeSelector),
     tolerations, and a zone spread. (dict "ctx" . "selector" <labels> "hard" <bool>) */}}
{{- define "lp.podPlacement" -}}
{{- $v := .ctx.Values.placement }}
{{- with $v.nodeSelector }}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
          {{- range $key, $val := . }}
            - {key: {{ $key }}, operator: In, values: [{{ $val | quote }}]}
          {{- end }}
{{- end }}
{{- with $v.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: {{ ternary "DoNotSchedule" "ScheduleAnyway" (default false .hard) }}
    labelSelector:
      matchLabels:
        {{- toYaml .selector | nindent 8 }}
{{- end }}
