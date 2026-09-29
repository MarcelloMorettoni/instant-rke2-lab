# 06 · Operations runbook

Every alert in [`alerts/loki-alerts.yaml`](../alerts/loki-alerts.yaml)
links to a section here. Dashboards: import the
[loki-mixin](https://github.com/grafana/loki/tree/main/production/loki-mixin) dashboards into
the **platform** org, backed by the managed Prometheus data source.

## First install

Once per environment, in this order:

1. **Prerequisites on the AKS cluster**:
   - OIDC issuer + Workload Identity enabled;
   - Azure Monitor managed Prometheus (ama-metrics) enabled;
   - Azure Policy (Gatekeeper) with an exemption for ns `otel-agent` (hostPath `/var/log/pods` read-only, `/var/lib/otelcol`);
   - `kubectl`, `helm`, `az`, `jq`, `python3` with PyYAML on the runner.
2. **Mirror images** into the bank's ACR, then set `global.imageRegistry` in the three
   values files:
   - `grafana/loki`, `otel/opentelemetry-collector-contrib`, `grafana/grafana`, `memcached`, `prom/memcached-exporter`;
   - `grafana/rollout-operator`, the kgateway and envoy images, the ESO images.
3. **Terraform** (`infra/terraform`) from a runner with network access to the private Key
   Vault. Then:
   ```bash
   cp -r environments/example environments/<env>
   terraform -chdir=infra/terraform output -raw environment_values > environments/<env>/terraform.yaml
   ```
4. **PostgreSQL role for Grafana**, as the DBA, with the password from Key Vault secret
   `grafana-db-password`:
   ```sql
   CREATE ROLE grafana LOGIN PASSWORD '<grafana-db-password>';
   GRANT CONNECT ON DATABASE grafana TO grafana;
   \c grafana
   GRANT ALL ON SCHEMA public TO grafana;
   ```
5. **Entra app registration** for Grafana ([02](02-tenancy-and-access.md#entra-id-app-registration));
   its secret goes into Key Vault as `grafana-entra-client-secret`.
6. **Fill in `environments/<env>/`** ([09 · Helm charts](09-helm-charts.md)):
   - `values.yaml`: registry, cluster name, CIDRs, zone names, hostnames, Entra IDs;
   - `cluster.env`: the kubectl context;
   - `overlays.txt`: optional, e.g. `test-cluster.yaml`.
7. Run `scripts/install.sh <env>`. It finishes with `scripts/smoke-test.sh <env>`.

## Pushes failing

`LokiPushErrors`, `LokiPushLatencyHigh`, `OtelAgentQueueFilling`, `OtelDroppingLogs`, `OtelQueueFull`.

1. Is it one tenant or all? A single tenant usually gets **429**, which is
   [tenant over limits](#tenant-over-limits), not this alert.
2. Distributors:
   ```bash
   kubectl -n loki get pods -l app.kubernetes.io/component=distributor
   ```
   Check the logs for `context deadline` or `too many unhealthy instances in the ring`.
3. Ingester ring (below). If two zones are unhealthy, writes fail by design (no quorum).
4. Collectors: `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` by job
   (`otel/agent`, `otel/gateway`) and exporter.
   - Agents filling: the gateways are slow or unreachable. Check
     `kubectl -n otel get pods` and the NetworkPolicy.
   - One gateway exporter filling: that tenant, see [tenant over limits](#tenant-over-limits).
   - All gateway exporters filling: Loki's write path.
5. `OtelDroppingLogs` means records were given up after retries (6 h at the gateway): that
   data is **lost**. Record it for the incident report, with the tenant(s) and the time
   window.
6. `OtelQueueFull` means back-pressure: a full gateway queue rejects its tenant's data, and
   the agents retry, which delays other tenants on the same nodes. Raise the tenant's Loki
   limit or its `gatewayQueueMiB`, or temporarily lower its log volume.

## Ingester unhealthy

`LokiIngesterUnhealthyInRing`.

```bash
kubectl -n loki get pods -l app.kubernetes.io/component=ingester -o wide
kubectl -n loki port-forward svc/loki-distributor 3100:3100   # then open http://localhost:3100/ring
```

- A pod crash-looping on **WAL replay** (OOM): raise its memory limit temporarily, or lower
  `wal.replay_memory_ceiling`.
- An ingester that is gone for good, e.g. its PVC is lost: `autoforget_unhealthy` removes it from
  the ring after the heartbeat timeout. Otherwise click **Forget** on `/ring`.
- **Never delete ingesters in two zones at once.**

## Flush failures

`LokiIngesterFlushFailures`, `LokiWALDiskFull`.

1. Ingester logs: `failed to flush`. Typical causes:
   - **403**: the Workload Identity role assignment is missing, or the federated credential
     subject is wrong (`system:serviceaccount:loki:loki`).
   - **DNS or timeout**: the private endpoint or its DNS zone link, or the firewall.
   - **Key Vault CMK disabled or expired**: Blob returns 403 `KeyVaultEncryptionKeyNotFound`.
     **This is urgent**: re-enable the key version.
2. Test from inside an ingester pod: `getent hosts <account>.blob.core.windows.net`
   must return a private IP.
3. WAL disk full: expand the PVC (the storage class allows expansion):
   ```bash
   kubectl -n loki patch pvc data-loki-ingester-zone-a-0 -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
   ```

## Tenant over limits

`LokiTenantLogsDropped`. The `reason` label says why:

| reason | Meaning | Fix |
|---|---|---|
| `rate_limited` | tenant above `ingestion_rate_mb` | tell the tenant; raise the tier, or `limits.ingestion_rate_mb` in `tenants.yaml` |
| `per_stream_rate_limit` | one stream is too hot | usually one noisy pod or log level `DEBUG` in prod |
| `stream_limit` | too many active streams | cardinality problem: which label explodes? `logcli series --analyze-labels` |
| `line_too_long` | line > 256 KB | truncated, not dropped (`max_line_size_truncate`) |
| `greater_than_max_sample_age` | line older than 7 days | clock skew or a replay; usually harmless |

Changing a limit: edit `tenants.yaml`, run `scripts/render-tenants.py`, then
`scripts/install.sh <env> 30`. The runtime config reloads within seconds, with no restart.

## Queries slow or failing

`LokiQueryErrors`.

- Query frontend logs contain `metrics.go` lines with `org_id`, `query`, `duration`,
  `total_bytes`. Find the tenant and the query.
- Typical causes:
  - selectors that are too broad (`{k8s_namespace_name=~".+"}`);
  - regexes run before cheap `|=` filters;
  - 30-day ranges on the Cold tier.
- Guardrails are per tenant: `max_query_length`, `query_timeout`, `max_query_series`.
- Scale queriers if the scheduler queue is long for **all** tenants.

## Compactor

`LokiRetentionNotRunning`.

```bash
kubectl -n loki logs sts/loki-compactor --since=6h | grep -iE 'retention|error'
```

Typical causes: its PVC is full, Blob errors (see flush failures), or the pod is not
scheduled. A few hours of delay only postpones deletion; there is no data risk.

## Collector

`OtelAgentMissingOnNodes`.

```bash
kubectl -n otel-agent get pods -o wide
kubectl -n otel-agent describe ds otel-agent-agent
kubectl -n otel-agent logs ds/otel-agent-agent --tail=50
```

- A new node pool with an unexpected taint: the agent tolerates everything
  (`operator: Exists`), so check its resources and priority class.
- Blocked by Azure Policy: the hostPath exemption must include ns `otel-agent`.
- `k8s_attributes` errors (RBAC, API server unreachable): OTLP senders can't be identified,
  so their logs land in `unassigned`. Stdout logs are unaffected (namespace from the path).

## General triage

- `LokiPanics`: get the stack trace from the pod's previous logs
  (`kubectl logs --previous`), open an issue upstream, and check whether one tenant's query
  triggers it.
- The read gateway's access log is in the `platform` tenant: `{k8s_namespace_name="loki", k8s_container_name="kgateway-proxy"}`
  (the container name may differ by kgateway version).

## Routine operations

### Rotate a view key

```bash
scripts/tenant-keys.sh --rotate payments
```

This writes the new key to Key Vault, forces the External Secrets refresh, and updates the
org's data source. Expect a few seconds of 401 for that org.

### Rotate the Grafana break-glass password

After every use:

```bash
az keyvault secret set --vault-name kv-obs-prod-weu --name grafana-admin-password --file <(openssl rand -hex 24)
kubectl -n grafana annotate externalsecret grafana-admin force-sync=$(date +%s) --overwrite
kubectl -n grafana exec deploy/grafana -- grafana cli admin reset-admin-password "$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
```

### Deletion requests

For example, GDPR erasure. The delete API is not exposed through the gateway;
the platform team runs it with an approved ticket:

```bash
kubectl -n loki port-forward svc/loki-compactor 3100:3100
curl -X POST -H 'X-Scope-OrgID: payments' \
  'http://localhost:3100/loki/api/v1/delete?query={k8s_namespace_name="payments-prod"} |= "customer-4711"&start=1735689600&end=1738368000'
curl -H 'X-Scope-OrgID: payments' http://localhost:3100/loki/api/v1/delete   # status
```

Deletion runs after `delete_request_cancel_period` (24 h) and is irreversible.

### Test a masking pattern before adding it

1. Add an OTTL statement to `transform/mask` in `collector/agent-config.yaml` (bodies and
   attributes).
2. Add a sample line and an assertion to `scripts/pipeline-test.sh`.
3. Run `scripts/pipeline-test.sh`: the real collectors and Loki in Docker, with the same
   `loki.process` block as production.
4. Run `scripts/validate.sh`.
5. Roll out the collectors with `scripts/install.sh <env> 30`.
