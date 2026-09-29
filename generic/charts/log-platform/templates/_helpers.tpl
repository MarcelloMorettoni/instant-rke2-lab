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

{{/* Scrapes from AKS managed Prometheus (ama-metrics in kube-system). */}}
{{- define "lp.amaMetricsPeer" -}}
- namespaceSelector:
    matchLabels: {kubernetes.io/metadata.name: kube-system}
  podSelector:
    matchExpressions:
      - {key: rsName, operator: In, values: [ama-metrics]}
{{- end }}
