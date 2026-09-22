# Soft tenancy on the lab

Two tenants share the cluster, `tenant-a` and `tenant-b`. The goals:

- They **cannot talk to each other**: not by service name, pod IP or NodePort,
  not through the ingress, and not even by DNS lookup.
- Each tenant **logs into Grafana and sees only its own telemetry**: logs,
  metrics, traces and profiles, all linked together.
- The isolation **holds when someone makes a mistake**: a sloppy allow policy,
  a spoofed header, an over-privileged Grafana user.

"Soft" tenancy means one cluster, one kernel, shared nodes, with isolation
enforced by policy. The [limits](#what-soft-tenancy-does-not-protect-against)
section covers what that does *not* give you.

**Word versions for the team:**
[`soft-tenancy-lab-walkthrough.docx`](./soft-tenancy-lab-walkthrough.docx) (this walkthrough),
[`soft-multi-tenancy-guide.docx`](./soft-multi-tenancy-guide.docx) (the same design for any Cilium cluster),
and [`confluence/`](./confluence/) (two "basics" pages and one page per backend, with SVG and PNG diagrams, plus paste instructions).

**Every gateway is kgateway** (Envoy, Gateway API): the read gateway in front of
the observability backends (step 07) and the tenant ingress (step 12).

## The design

```
tenant-a pods ──✗── tenant-b pods           Cilium CCNP: both directions denied (deny beats allow)
     │                    │
     │ DNS *.tenant-a     │ DNS *.tenant-b   ← Cilium DNS proxy filters names; anything else is NXDOMAIN
     └──► CoreDNS (kube-system, shared) ◄────┘

observability (platform-only namespace, locked down in step 10)
  write   Alloy DaemonSet pulls from every node, tenant = namespace
            logs     /var/log/pods        ──► Loki
            metrics  /metrics  (opt-in)   ──► Mimir
            profiles /debug/pprof (opt-in)──► Pyroscope
          traces: tenant-a pods ──► otlp-tenant-a ──► Tempo ──► Mimir (service graph)
                  tenant-b pods ──► otlp-tenant-b ──┘      (receiver stamps the tenant)
  read    Grafana org "Tenant A" ─┐
          Grafana org "Tenant B" ─┼─► obs-gateway (kgateway) ──► Loki :3100  Mimir :8080  Tempo :3200  Pyroscope :4040
          Grafana org "Platform" ─┘   X-Scope-OrgID = owner of the API key (whatever the client sent is replaced)
```

**One rule behind every decision: a tenant never controls anything that sets
its own identity.** Tenants choose their pod labels, the headers they send and
the data sources they create, so none of those are trusted. They can't change
namespace names or namespace labels (cluster-scoped objects), so those are.

| Layer | Trusted identity | Enforced by |
|---|---|---|
| Network | namespace label `tenant` | `CiliumClusterwideNetworkPolicy` (step 03) |
| DNS | namespace label `tenant` | Cilium DNS proxy rules, NXDOMAIN for the rest (steps 00, 03) |
| Kubernetes API | user → namespaced RoleBinding | RBAC (step 02) |
| Pods | namespace PSA label | Pod Security `restricted`: no hostNetwork/hostPath (steps 01, 02) |
| Namespaces | name and label must match | ValidatingAdmissionPolicy (step 01) |
| Logs, metrics, profiles (write) | namespace name | Alloy pulls them and maps `tenant-X[-*]` → tenant `tenant-X` (step 08) |
| Traces (write) | which receiver the pod can reach | one OTLP receiver per tenant; Cilium lets only that tenant reach it (steps 03, 08, 10) |
| All signals (read) | gateway API key | kgateway's `apiKeyAuth` sets `X-Scope-OrgID` from the key on every backend (step 07) |
| Grafana | org membership | one org per tenant with four linked data sources; users are Editors, never Admins (step 09) |
| Ingress | Gateway listener, proxy identity | one kgateway Gateway per tenant; its listener only accepts that tenant's routes, and Cilium limits its proxy to that tenant (step 12) |

## What gets deployed

| Component | How | Namespace |
|---|---|---|
| Admission guard, RBAC, quotas | plain YAML | cluster / tenants |
| Tenant network baselines | `CiliumClusterwideNetworkPolicy` | cluster-wide |
| Workloads: nginx `web`, podinfo `frontend` → `backend`, netshoot `client` | plain YAML, applied *as the tenant user* | `tenant-a`, `tenant-b` |
| Loki 3.6: logs | `grafana/loki` 7.3.0, single binary | `observability` |
| Mimir 3.2: metrics | plain manifest, single binary | `observability` |
| Tempo 3.0: traces, with service graphs | `grafana-community/tempo` 3.0.0 | `observability` |
| Pyroscope 2.3: profiles | `grafana/pyroscope` 2.3.1 | `observability` |
| Read gateway (kgateway): one listener per backend | Gateway API YAML | `observability` |
| Alloy 1.19 DaemonSet: logs, metrics, profiles | `grafana/alloy` 1.12.1 | `observability` |
| Per-tenant OTLP receivers (Alloy): traces | plain YAML | `observability` |
| Grafana 13.2 | `grafana-community/grafana` 13.2.5 | `observability` |
| kgateway 2.4 (Gateway API 1.6), installed in step 07 | `oci://cr.kgateway.dev/kgateway-dev/charts/kgateway` v2.4.5 | `kgateway-system` |
| Ingress Gateways: one per tenant, one for the platform | plain YAML | `kgateway-system` |

Chart versions are pinned in [`lib.sh`](./lib.sh).

## Before you start

- The lab is up: `make all` in the repo root, and `kubectl get nodes` shows 3 Ready nodes.
- On the host: `helm`, `jq`, `openssl`, `envsubst` (all used by the scripts).
- The VMs can reach the internet (images, and the `example.com` allowlist test).

Every command below runs from this folder:

```bash
cd soft-tenancy
export KUBECONFIG=$PWD/../.state/kubeconfig
```

---

## Walkthrough

### 00 · DNS: NXDOMAIN instead of REFUSED

```bash
./00-cilium-dns/apply.sh
```

By default Cilium's DNS proxy answers blocked names with `REFUSED`, and glibc
**stops walking the search path** on REFUSED. With `ndots:5`, `example.com` is
first tried as `example.com.tenant-a.svc.cluster.local`. That query gets
refused and the real name is never asked. `nameError` (NXDOMAIN) fixes this,
and gives the semantics we want: to tenant a, tenant b's services don't exist.

The script adds [`cilium-dns-values.yaml`](./00-cilium-dns/cilium-dns-values.yaml)
to the lab's HelmChartConfig on cp1 (a `kubectl edit` would be reverted by
RKE2), waits for `cilium-config`, and restarts the agents.

### 01 · Namespaces and the admission guard

```bash
kubectl apply -f 01-namespaces/namespace-guard.yaml
kubectl apply -f 01-namespaces/namespaces.yaml
```

Everything later keys off the namespace `tenant` label. The guard makes that
label impossible to get wrong:

- a namespace named `tenant-*` must have it
- the value is one token, so `tenant-a-dev` can only belong to tenant `a`
- `tenant=X` is only allowed on `tenant-X` or `tenant-X-*`, so a namespace
  called `sneaky` can't join tenant a
- tenant namespaces must enforce Pod Security `restricted`. Otherwise a
  `hostNetwork` pod gets the *node's* identity and walks around every pod policy.

Try it:

```bash
kubectl create namespace tenant-c        # denied, and the message says why
```

### 02 · What a tenant user may do

```bash
kubectl apply -f 02-tenant-guardrails/
```

`alice` works in tenant-a and `bob` in tenant-b, simulated with impersonation
(`kubectl --as alice`). They get a custom `tenant-developer` role, **not** the
built-in `edit`. `edit` includes NetworkPolicies, and a tenant with that
right could write `egress: 0.0.0.0/0` and bypass the internet allowlist.
Quotas and LimitRanges stop one tenant from eating the workers.

```bash
kubectl --as alice auth can-i --list -n tenant-a
kubectl --as alice get pods -n tenant-b          # Forbidden
```

### 03 · Tenant network baselines

```bash
kubectl apply -f 03-tenant-isolation/
```

One [`CiliumClusterwideNetworkPolicy` per tenant](./03-tenant-isolation/tenant-a.yaml),
selected by the namespace label. Once a pod is selected, only what's listed
is allowed:

| | tenant-a | tenant-b |
|---|---|---|
| ingress | tenant a; the platform's collector (metrics, profiles) | tenant b; the platform's collector |
| egress | tenant a, CoreDNS (own names), its own trace receiver, `example.com:443` | tenant b, CoreDNS (own names), its own trace receiver |
| explicit **deny** | every other tenant, both ways | every other tenant, both ways |

The deny rules are the safety net. In Cilium, deny beats allow, so no allow
rule added later can connect the tenants. Step 05 proves it.

### 04 · Workloads, deployed by the tenants themselves

```bash
kubectl --as alice apply -f 04-demo-apps/tenant-a.yaml
kubectl --as bob   apply -f 04-demo-apps/tenant-b.yaml
```

Each tenant gets:

| Workload | What it is | Used for |
|---|---|---|
| `web` | nginx answering `hello from tenant-X` | network tests |
| `frontend` → `backend` | [podinfo](https://github.com/stefanprodan/podinfo), `/echo` on the frontend calls the backend | all four signals, one trace across two services |
| `client` | netshoot: calls `web`, then `frontend` every 5s (some slow, some errors) | traffic, and the verify scripts exec into it |

podinfo produces everything the observability half needs: JSON logs with a
`trace_id`, Prometheus metrics and pprof profiles on `:9898`, and OTLP traces
sent to the tenant's **own** receiver (`otlp-tenant-X`). Two pod annotations
opt it in to the platform's collector:

```yaml
prometheus.io/scrape: "true"            # metrics
profiles.grafana.com/scrape: "true"     # profiles
```

The container name equals the OpenTelemetry `service.name`, which is how
Grafana later jumps from a span to that service's logs and profile. Deploying
as alice/bob proves the RBAC and Pod Security setup is usable, not just
strict. Tenant b also gets a NodePort (`:30082`) to test "going around via
the node".

### 05 · Prove the network isolation

```bash
./05-verify-network.sh
```

27 checks, each stating what must happen, then the flows Cilium dropped
(from Hubble). Highlights:

```
PASS  tenant-a -> tenant-b web via pod IP
PASS  tenant-a -> tenant-b via NodePort 192.168.122.11:30082
PASS  tenant-a gets NXDOMAIN for web.tenant-b
PASS  tenant-a -> https://example.com (allowlisted)
PASS  tenant-b -> https://example.com (no internet)
PASS  PSA rejects a hostNetwork pod
PASS  'sneaky' namespace claiming tenant=a
PASS  tenant-a -> tenant-b pod IP, rogue allows in place     ← deny beats allow
```

That last check applies two "mistake" policies that explicitly allow
traffic between tenant-a and tenant-b, confirms it is still dropped, then removes them.

### 06 · The backends: Loki, Mimir, Tempo, Pyroscope

```bash
./06-observability-backends/install.sh
```

All four run as a single binary, and all four are multi-tenant the same way:
every push and every query must name its tenant in the `X-Scope-OrgID`
header, and each tenant's data is stored and queried separately.

| Backend | Signal | Tenancy switch | Installed from |
|---|---|---|---|
| Loki 3.6 | logs | `auth_enabled: true` | [`loki-values.yaml`](./06-observability-backends/loki-values.yaml) |
| Mimir 3.2 | metrics | `multitenancy_enabled: true` | [`mimir.yaml`](./06-observability-backends/mimir.yaml) (plain manifest) |
| Tempo 3.0 | traces | `multitenancyEnabled: true` | [`tempo-values.yaml`](./06-observability-backends/tempo-values.yaml) |
| Pyroscope 2.3 | profiles | `-auth.multitenancy-enabled=true` | [`pyroscope-values.yaml`](./06-observability-backends/pyroscope-values.yaml) |

Chart defaults that don't belong in a multi-tenant cluster are switched off:

- **Loki's rules sidecar** watches ConfigMaps in *every* namespace and ships a
  ClusterRole that can read every Secret.
- **Pyroscope's bundled Alloy** comes with the same kind of cluster-wide
  Secret access. Our collector (step 08) does that job.

**Tempo's metrics generator** turns each tenant's spans into service-graph and
RED metrics, and writes them to Mimir *under the same tenant*, which powers the
service map in Grafana. Mimir has no small chart (only the full microservices
setup), so it's a plain StatefulSet. It runs from its data volume so the root
filesystem can stay read-only.

### 07 · The read gateway

```bash
./07-read-gateway/install.sh
```

**None of the four backends authenticates `X-Scope-OrgID`.** It's a claim.
The read gateway turns it into an identity, the same way on every backend. It's
a kgateway `Gateway` called `obs-gateway` in `observability`, so the script
first installs the Gateway API CRDs (unless something already manages them) and
kgateway. The ingress in step 12 uses the same controller.

The tenant comes from an **API key**. Each tenant has one, stored in the
`obs-gateway-keys` Secret under the tenant's name. A `TrafficPolicy` on the
Gateway ([`gateway.yaml`](./07-read-gateway/gateway.yaml)) checks the key and
writes the name it belongs to into the header:

```yaml
apiKeyAuth:
  secretRef:
    name: obs-gateway-keys       # entries: tenant-a, tenant-b, platform
  keySources:
    - header: X-Api-Key
  clientIdHeader: X-Scope-OrgID  # the key's owner; replaces whatever the client sent
  forwardCredential: false       # the key never reaches the backends
```

Envoy *sets* the header, so a caller with tenant-a's key who also sends
`X-Scope-OrgID: tenant-b` still lands in tenant-a. One listener per backend, on
the backend's own port, with one `HTTPRoute` each:

| Listener | Backend | Forwarded (read APIs only) | Refused with 403 |
|---|---|---|---|
| 3100 | Loki | `/loki/api/v1/*` | push, delete |
| 8080 | Mimir | `/prometheus/api/v1/*` | |
| 3200 | Tempo | `/api/*` | the overrides API |
| 4040 | Pyroscope | `/querier.v1.QuerierService/*` | |

Anything else gets 404, including every push path, and a missing or unknown key
gets 401. Envoy normalizes paths before routing, so tricks like
`/loki/api/v1/%70ush` or `/loki/api/v1//push` still hit the 403. Queries may
run for 300 s (Envoy's default is 15 s), and Loki's live tail stays open. The
access log shows who asked for what:

```bash
kubectl -n observability logs deploy/obs-gateway | grep tenant=
# :3100 tenant=tenant-a "GET /loki/api/v1/labels" 200 675
```

Keys are generated once into `../.state/soft-tenancy/credentials.env`
(gitignored, mode 600). Re-running the script is safe. If an older version of
this lab left its nginx gateway behind, the script removes it.

### 08 · The collectors

```bash
./08-collectors/install.sh
```

**Alloy pulls every signal it can**, so tenants never choose their tenant ID.
One Alloy per node reads container log files from disk, and scrapes
`/metrics` and `/debug/pprof` from pods that opted in. The tenant always comes
from the namespace name. In [`alloy-values.yaml`](./08-collectors/alloy-values.yaml)
each tenant is one block:

```alloy
tenant_pipeline "tenant_a" {
  id              = "tenant-a"
  keep            = "tenant-a(-.+)?"          // namespaces that are tenant a
  log_targets     = discovery.relabel.logs.output
  metric_targets  = discovery.relabel.metrics.output
  profile_targets = discovery.relabel.profiles.output
}
// ...and a "platform" block for everything that isn't a tenant
```

**Traces are the one signal apps must push.** Instead of letting them push
straight to Tempo (and pick any tenant), each tenant gets its own small OTLP
receiver ([`otlp-receivers.yaml`](./08-collectors/otlp-receivers.yaml)). The
receiver sets `X-Scope-OrgID` from its own configuration, and Cilium lets only
that tenant's pods reach it. Whatever a tenant sends lands in its own tenant.

The Alloy chart's default ClusterRole (every Secret, `pods/log`, and more) is
replaced with `pods: get/list/watch`, which is all this collector needs.

### 09 · Grafana, one org per tenant

```bash
./09-grafana/install.sh
```

Installs Grafana, then [`setup-orgs.sh`](./09-grafana/setup-orgs.sh) creates
the orgs through the API (Grafana can't provision orgs or users from files).
Each org gets **four data sources**, all sending that tenant's gateway key
(`X-Api-Key`, stored encrypted in the data source, never shown to the org's users):

| Org | User (role) | Loki, Mimir, Tempo, Pyroscope use the key of |
|---|---|---|
| Tenant A | alice (Editor) | `tenant-a` |
| Tenant B | bob (Editor) | `tenant-b` |
| Platform | ops (Editor) | `platform` (kube-system, observability, ...) |
| Main Org | nobody | no data sources, because new users land here by default |

The data sources of an org are linked to each other, and only to each other:

- a **span** opens its logs, its metrics, and its service's CPU profile
- a **log line** with a `trace_id` opens that trace
- the **service map** comes from the metrics Tempo generated

Users are **Editors, never org Admins**. An org Admin can add data sources,
including one pointed at another tenant. The script prints the passwords:

```bash
kubectl -n observability port-forward svc/grafana 3000:80
# http://localhost:3000 → log in as alice → Explore → Tempo → Search → open a trace
```

### 10 · Lock down the observability namespace

Every backend is multi-tenant now, but not *safe* yet. Watch why:

```bash
./10-observability-lockdown/attack-demo.sh
```

```
  read tenant-b's logs     : {"status":"success","data":["tenant-b"]}
  read tenant-b's metrics  : {"status":"success","data":["tenant-b"]}
  read tenant-b's traces   : 5 traces
  read tenant-b's profiles : {"names":["tenant-b"]}
  forge a log into tenant-a: HTTP 204, accepted
```

A pod in `default` (no policy there) claims to be tenant-b and reads all of
its telemetry, then claims to be tenant-a and **injects a forged log line**.
Tenant pods can't do this (step 03), but "only tenants are blocked" isn't
enough. Lock it down and run it again:

```bash
kubectl apply -f 10-observability-lockdown/policies.yaml
./10-observability-lockdown/attack-demo.sh          # every line now says BLOCKED
```

[`policies.yaml`](./10-observability-lockdown/policies.yaml): default deny for
the namespace, and each component may talk only to its neighbour:

- Alloy reaches Loki, Mimir and Pyroscope, and an **L7 rule** lets it only
  `POST` to their push endpoints. A compromised collector can't read anyone's data.
- Only the tenant OTLP receivers reach Tempo's OTLP port, and each receiver
  accepts only its own tenant's pods.
- Only the read gateway's proxy reaches the query APIs, only Grafana reaches
  the gateway, and Grafana can't reach the backends directly or the internet.
  The proxy may also reach the kgateway controller, for its configuration.

In Grafana (as alice), the forged line from the first run is still there:
`{forged="true"}`. That's the integrity half of the problem.

### 11 · Prove the observability isolation

```bash
./11-verify-observability.sh
```

58 checks across all four signals. Highlights:

```
PASS  metrics:  tenant-a sees only tenant-a
PASS  traces:   tenant-b gets nothing for it                 ← tenant-a's trace id
PASS  profiles: tenant-a claiming tenant-b                   ← the key wins over the header
PASS  a tenant-a log line's trace_id opens in Tempo
PASS  service graph frontend -> backend (tenant-a)
PASS  tenant-a -> tenant-b's trace receiver                  ← dropped
PASS  alice can't use bob's tempo data source
PASS  Alloy identity: Mimir query -> 403                     ← Envoy L7 rule
```

### 12 · Ingress with kgateway

```bash
./12-kgateway-ingress/install.sh
kubectl --as alice apply -f 12-kgateway-ingress/route-tenant-a.yaml
kubectl --as bob   apply -f 12-kgateway-ingress/route-tenant-b.yaml
```

kgateway is already installed (step 07; the script re-applies it, so step 12
also works on its own). It creates **one Gateway per tenant** plus one for the
platform, all in `kgateway-system`:

| Gateway | Listener hostname | Accepts routes from | NodePort (lab) | Its proxy may reach |
|---|---|---|---|---|
| `tenant-a` | `*.tenant-a.lab` | namespaces with `tenant: a` | 30180 | tenant a only |
| `tenant-b` | `*.tenant-b.lab` | namespaces with `tenant: b` | 30181 | tenant b only |
| `platform` | `grafana.platform.lab` | namespaces with `role: platform` | 30182 | Grafana only |

**Why not one shared Gateway?** Its Envoy proxy would need a way into every
tenant, so Cilium could no longer tell tenant-a's traffic from tenant-b's on
that hop. And kgateway's `Backend` resource (types `Static` and
`DynamicForwardProxy`) can point a route at *any* host. On a shared proxy, one
RBAC slip turns the ingress into a bridge between tenants. With a proxy per
tenant, [`network-policies.yaml`](./12-kgateway-ingress/network-policies.yaml)
pins each proxy to its own tenant on the network, whatever routes exist.

Three layers, again:

- **Listener:** `allowedRoutes` only accepts HTTPRoutes from that tenant's
  namespaces, so bob can't attach a route that steals `web.tenant-a.lab`.
- **RBAC:** tenants may create `HTTPRoute`s, nothing else. No
  `ReferenceGrant` (a data path into your services), no Gateways, and no
  kgateway `Backend`s or policies ([`rbac.yaml`](./12-kgateway-ingress/rbac.yaml)).
- **Cilium:** each proxy's egress is its own tenant, the kgateway controller
  and DNS. Each tenant's ingress now also allows exactly its own proxy.

Grafana moves behind the platform gateway: its policy admits only that proxy.
Tenant pods still can't reach any gateway (their baseline has no egress to
`kgateway-system`). Inside the cluster they use service names.

```bash
curl -H 'Host: web.tenant-a.lab' http://192.168.122.11:30180/        # hello from tenant-a
curl -H 'Host: grafana.platform.lab' http://192.168.122.11:30182/api/health
```

In production, drop the `GatewayParameters` NodePort override and let each
Gateway get its own LoadBalancer address.

### 13 · Prove the ingress isolation

```bash
./13-verify-ingress.sh
```

```
PASS  web.tenant-a.lab on tenant-a's gateway
PASS  tenant-a's gateway won't serve web.tenant-b.lab
PASS  bob's route on tenant-a's gateway is rejected       ← listener allowedRoutes
PASS  bob's route can't use tenant-a's service            ← no ReferenceGrant
PASS  bob can't create kgateway Backends                  ← RBAC
PASS  control: Static Backend via tenant-a's gateway
PASS  rogue: tenant-b's proxy -> tenant-a pod IP          ← Cilium drops it
```

The last pair simulates the worst case: an admin (or a slipped RBAC rule)
creates a kgateway `Backend` that points tenant-b's gateway straight at a
tenant-a pod. The control proves such a Backend works in general. The rogue
one still gets nothing, because tenant-b's proxy has no network path to
tenant a.

---

## Exercises: break it on purpose

1. **See the REFUSED problem.** Set `dnsRejectResponseCode: refused` in
   `00-cilium-dns/cilium-dns-values.yaml` and re-run step 00. From tenant-a,
   `curl https://example.com` now fails, although it's allowlisted, while
   `dig example.com` still works (dig ignores the search path). Put `nameError` back.
2. **Remove the safety net.** Delete the `ingressDeny` block from
   `03-tenant-isolation/tenant-b.yaml`, re-apply it and re-run step 05. The
   "rogue allows" check now fails, which is exactly why the deny rules exist.
3. **Give alice the built-in `edit` role.** Bind `edit` instead of
   `tenant-developer`, then as alice create a NetworkPolicy with egress
   `0.0.0.0/0`. Tenant-a can now query `1.1.1.1` for DNS and reach any IP, so the
   allowlist is gone. Cross-tenant traffic stays blocked (deny beats allow).
   Revert the binding.
4. **Make alice a Grafana org Admin**, then have her add a Mimir data source
   pointing at the gateway as `tenant-b`. She doesn't have tenant-b's
   key. Pointing it straight at `mimir:8080` with a spoofed header gets
   dropped by Grafana's egress policy. Two layers, each enough on its own.
5. **Onboard tenant-c.** Namespace (the guard tells you what's missing), copy
   the CCNP, add a `tenant_pipeline "tenant_c"` block to
   `08-collectors/alloy-values.yaml`, an `otlp-tenant-c` receiver, a line in
   `09-grafana/setup-orgs.sh`, and a gateway key: an `OBS_KEY_TENANT_C` in
   `lib.sh`'s `CRED_VARS` and a `tenant-c` entry in `07-read-gateway/install.sh`.
6. **Watch it live** with Hubble:
   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace tenant-a --protocol dns -f
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED -f
   ```
   (`ds/cilium` picks one agent, so you only see flows on that node.)
7. **Try to send traces as someone else.** From tenant-a's client pod, send a
   span to `otlp-tenant-b` (Cilium drops it), then to tenant-a's own receiver
   with `X-Scope-OrgID: tenant-b` set (it lands in tenant-a anyway: the receiver
   stamps its own tenant).

## What soft tenancy does NOT protect against

Be honest about the boundary before calling it production-ready:

- **Shared kernel.** A container escape on a node reaches every tenant's pods
  on that node. Stronger options: tenant-dedicated nodes (taints plus
  nodeSelectors), sandboxed runtimes (gVisor, Kata), or separate clusters.
- **Shared CoreDNS and Cilium agent.** A tenant flooding DNS degrades DNS for
  everyone. Every tenant DNS query also passes through the cilium-agent's DNS
  proxy, so an agent restart or upgrade briefly interrupts tenant DNS.
- **Grafana holds every tenant's gateway key.** A compromised Grafana
  crosses tenants. If that's unacceptable, run one Grafana per tenant (still
  in `observability`, never in the tenant's namespace).
- **Node resources.** Quotas cap CPU and memory, not disk IO or network bandwidth.
- **Data at rest.** Each backend keeps tenants in separate directories (or
  object prefixes), not separately encrypted.
- **Shared backends.** One tenant's heavy queries or ingest can slow the others.
  Per-tenant limits help (Loki's `runtimeConfig`, Mimir's `limits`), but they
  cap, they don't isolate.
- **Platform access.** Cluster admins, `kubectl port-forward`/`exec` into
  `observability`, and the unauthenticated Hubble UI see everything.
- **DNS patterns cover the `tenant-X` namespace only.** A tenant with a second
  namespace (`tenant-a-dev`) needs `*.tenant-a-dev.svc.cluster.local` added.
- **One kgateway controller configures every proxy.** A bug or compromise in
  the controller affects every tenant's ingress and the read gateway. The
  proxies are separate; the control plane is not.

## Layout

```
soft-tenancy/
├── lib.sh                          # shared helpers, pinned chart versions, test harness
├── 00-cilium-dns/                  # NXDOMAIN for blocked names (HelmChartConfig on cp1)
├── 01-namespaces/                  # tenant-a, tenant-b, observability + admission guard
├── 02-tenant-guardrails/           # RBAC (alice, bob), quotas, limit ranges
├── 03-tenant-isolation/            # one CiliumClusterwideNetworkPolicy per tenant
├── 04-demo-apps/                   # web + client per tenant
├── 05-verify-network.sh
├── 06-observability-backends/      # Loki, Mimir, Tempo, Pyroscope (values / manifest) + install.sh
├── 07-read-gateway/                # kgateway: API key → X-Scope-OrgID, one listener per backend
├── 08-collectors/                  # Alloy DaemonSet (per-tenant pipelines) + per-tenant OTLP receivers
├── 09-grafana/                     # values.yaml, install.sh, setup-orgs.sh (4 linked data sources per org)
├── 10-observability-lockdown/      # policies.yaml + attack-demo.sh
├── 11-verify-observability.sh
├── 12-kgateway-ingress/            # one kgateway Gateway per tenant, proxy policies, routes
├── 13-verify-ingress.sh
├── 99-cleanup.sh                   # --all also deletes the generated credentials
├── soft-tenancy-lab-walkthrough.docx  # this README as a Word file, with diagrams
├── soft-multi-tenancy-guide.docx   # cluster-agnostic step-by-step guide (Word)
└── confluence/                     # six team pages (Word), diagrams (SVG + PNG), paste instructions

```

## Troubleshooting

**Step 05: "tenant-a gets NXDOMAIN" fails, or `example.com` fails from tenant-a.**
Step 00 didn't take. Check
`kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.tofqdns-dns-reject-response-code}'`
and look for `nameError`.

**Grafana shows "no data" for alice.** Give it a minute after step 08:
metrics are scraped every 30s, and profiles need about a minute to become
queryable. Then check the path piece by piece: `kubectl -n observability logs ds/alloy`
(logs, metrics, profiles), `kubectl -n observability logs deploy/otlp-tenant-a` (traces),
the read gateway's access log (`kubectl -n observability logs deploy/obs-gateway | grep tenant=`),
then `./11-verify-observability.sh`.

**Grafana's data sources answer 401.** The keys in the data sources don't match
the `obs-gateway-keys` Secret, for example after the credentials file was
recreated. Re-run `./07-read-gateway/install.sh`, then `./09-grafana/setup-orgs.sh`.

**The read gateway isn't `Programmed`, or a backend answers 404 for everything.**
`kubectl -n observability describe gateway obs-gateway`, then check that the
routes and the policy are attached:
`kubectl -n observability get httproute,trafficpolicy,listenerpolicy -o wide`
and `kubectl -n observability describe trafficpolicy obs-gateway-tenant`.

**The service map is empty.** It's built from metrics Tempo generates from
spans, a minute or two after traces arrive. Check
`traces_service_graph_request_total` in the tenant's Mimir data source.

**After step 10, something in observability stopped working.** Find the drop:
`kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace observability --verdict DROPPED`.
Run it against each cilium pod, since each agent only sees its own node.

**A Gateway isn't `Programmed`, or a route isn't accepted.**
`kubectl -n kgateway-system get gateway` and
`kubectl -n tenant-a describe httproute web` show the reason. A route on the
wrong Gateway reports `NotAllowedByListeners`.

**The gateway answers 503 (upstream connect error).** The proxy was dropped on
its way to the backend. Check its egress:
`kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --from-label gateway.networking.k8s.io/gateway-name=tenant-a`.

**Start over:** `./99-cleanup.sh` (add `--all` to also forget the keys and passwords).
