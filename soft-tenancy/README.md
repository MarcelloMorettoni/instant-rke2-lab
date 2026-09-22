# Soft tenancy on the lab

Two tenants share the cluster, `tenant-a` and `tenant-b`. The goals:

- They **cannot talk to each other**: not by service name, pod IP or NodePort,
  and not even by DNS lookup.
- Each tenant **logs into Grafana and sees only its own logs**.
- The isolation **holds when someone makes a mistake**: a sloppy allow policy,
  a spoofed header, an over-privileged Grafana user.

"Soft" tenancy means one cluster, one kernel, shared nodes, with isolation
enforced by policy. The [limits](#what-soft-tenancy-does-not-protect-against)
section covers what that does *not* give you.

## The design

```
tenant-a pods ──✗── tenant-b pods           Cilium CCNP: both directions denied (deny beats allow)
     │                    │
     │ DNS *.tenant-a     │ DNS *.tenant-b   ← Cilium DNS proxy filters names; anything else is NXDOMAIN
     └──► CoreDNS (kube-system, shared) ◄────┘

     │ stdout → /var/log/pods on the node    (tenants have no network path to observability)
     ▼
observability (platform-only namespace, locked down in step 10)
  Alloy DaemonSet ── namespace → tenant ID ──POST /push only (L7)──► Loki
  Grafana
    Org "Tenant A" → data source, gateway user tenant-a ─┐
    Org "Tenant B" → data source, gateway user tenant-b ─┼─► loki-gateway ──► Loki
    Org "Platform" → data source, gateway user platform ─┘   X-Scope-OrgID = authenticated user
                                                             (whatever the client sent is overwritten)
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
| Namespaces | name ↔ label pairing | ValidatingAdmissionPolicy (step 01) |
| Log write path | namespace name | Alloy maps `tenant-X[-*]` → Loki tenant `tenant-X` (step 08) |
| Log read path | gateway username | nginx sets `X-Scope-OrgID` from basic auth (step 07) |
| Grafana | org membership | one org per tenant, users are Editors, never Admins (step 09) |

## What gets deployed

| Component | How | Namespace |
|---|---|---|
| Admission guard, RBAC, quotas | plain YAML | cluster / tenants |
| Tenant network baselines | `CiliumClusterwideNetworkPolicy` | cluster-wide |
| Demo apps (nginx `web` + netshoot `client`) | plain YAML, applied *as the tenant user* | `tenant-a`, `tenant-b` |
| Loki 3.6 (single binary, `auth_enabled`) | `grafana/loki` 7.3.0 | `observability` |
| Loki read gateway (nginx) | plain YAML | `observability` |
| Alloy 1.19 (DaemonSet) | `grafana/alloy` 1.12.1 | `observability` |
| Grafana 13.2 | `grafana-community/grafana` 13.2.5 | `observability` |

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
| ingress | tenant a | tenant b |
| egress | tenant a, CoreDNS (own names), `example.com:443` | tenant b, CoreDNS (own names) |
| explicit **deny** | every other tenant, both ways | every other tenant, both ways |

The deny rules are the safety net. In Cilium, deny beats allow, so no allow
rule added later can connect the tenants. Step 05 proves it.

### 04 · Demo apps, deployed by the tenants themselves

```bash
kubectl --as alice apply -f 04-demo-apps/tenant-a.yaml
kubectl --as bob   apply -f 04-demo-apps/tenant-b.yaml
```

Each tenant gets `web` (nginx answering `hello from tenant-X`) and `client`
(netshoot, curls `web` every 10s and logs the answer). Deploying as
alice/bob proves the RBAC and Pod Security setup is usable, not just strict.
Tenant b also gets a NodePort (`:30082`) to test "going around via the node".

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
tenant-a ↔ tenant-b, confirms the traffic is still dropped, then removes them.

### 06 · Loki (multi-tenant)

```bash
./06-loki/install.sh
```

[`values.yaml`](./06-loki/values.yaml): single binary, `auth_enabled: true`,
`multi_tenant_queries_enabled: false`, per-tenant ingestion limits. It also
turns off two chart defaults that don't belong here: the rules sidecar, which
watches ConfigMaps in *every* namespace and comes with a ClusterRole that can
read every Secret, and the chart's gateway (step 07 replaces it).

### 07 · The read gateway

```bash
./07-loki-gateway/install.sh
```

**Loki doesn't authenticate `X-Scope-OrgID`.** It's a claim. The gateway
([`gateway.yaml`](./07-loki-gateway/gateway.yaml)) turns it into an identity:

```nginx
auth_basic_user_file /etc/nginx/auth/htpasswd;   # users: tenant-a, tenant-b, platform
proxy_set_header X-Scope-OrgID $remote_user;     # replaces whatever the client sent
```

The gateway only serves reads (push and delete return 403). Passwords are
generated once into `../.state/soft-tenancy/credentials.env` (gitignored, mode 600).

### 08 · Alloy

```bash
./08-alloy/install.sh
```

One Alloy per node reads `/var/log/pods` from disk. **Tenants push nothing**,
so they can't pick, forge or skip their tenant ID. The tenancy decision is
visible in [`values.yaml`](./08-alloy/values.yaml):

```alloy
stage.match {
  selector = "{namespace=~\"tenant-a(-.+)?\"}"
  stage.tenant { value = "tenant-a" }
}
// ... anything unmatched falls back to tenant "platform", never to a tenant
```

The chart's default ClusterRole (every Secret, `pods/log`, and more) is
replaced with `pods: get/list/watch`, which is all file-based shipping needs.

### 09 · Grafana, one org per tenant

```bash
./09-grafana/install.sh
```

Installs Grafana, then [`setup-orgs.sh`](./09-grafana/setup-orgs.sh) creates
the orgs through the API (Grafana can't provision orgs or users from files):

| Org | User (role) | Loki data source authenticates as |
|---|---|---|
| Tenant A | alice (Editor) | `tenant-a` |
| Tenant B | bob (Editor) | `tenant-b` |
| Platform | ops (Editor) | `platform` (kube-system, observability, ...) |
| Main Org | nobody | no data sources, because new users land here by default |

Users are **Editors, never org Admins**. An org Admin can add data sources,
including one pointed at another tenant. The script prints the passwords:

```bash
kubectl -n observability port-forward svc/grafana 3000:80
# http://localhost:3000 → log in as alice, open Explore → {namespace=~".+"}
```

### 10 · Lock down the observability namespace

Loki is multi-tenant now, but not *safe* yet. Watch why:

```bash
./10-observability-lockdown/attack-demo.sh
```

```
  read  tenant-b's logs : {"status":"success","data":["tenant-b"]}
  forge into tenant-a   : HTTP 204, accepted
```

A pod in `default` (no policy there) claims to be tenant-b and reads its
logs, then claims to be tenant-a and **injects a forged log line**. Tenant
pods can't do this (step 03), but "only tenants are blocked" isn't enough.
Lock it down and run it again:

```bash
kubectl apply -f 10-observability-lockdown/policies.yaml
./10-observability-lockdown/attack-demo.sh          # both lines now say BLOCKED
```

[`policies.yaml`](./10-observability-lockdown/policies.yaml): default deny for
the namespace, and each component may talk only to its neighbour:

- Only Alloy reaches Loki's push endpoint. An **L7 rule** means even Alloy can
  only `POST /loki/api/v1/push`, so a compromised log shipper can't read logs.
- Only the gateway reaches Loki's query endpoints.
- Only Grafana reaches the gateway, and Grafana can't reach Loki directly or
  the internet.

In Grafana (as alice), the forged line from the first run is still there:
`{forged="true"}`. That's the integrity half of the problem.

### 11 · Prove the logging isolation

```bash
./11-verify-logs.sh
```

```
PASS  alice sees tenant-a, and only tenant-a
PASS  alice can't pick 'Tenant B' via header
PASS  alice can't create a data source
PASS  tenant-a claiming X-Scope-OrgID: tenant-b          ← gateway returns tenant-a's data
PASS  pod in 'default' -> Loki (the attack)
PASS  Alloy identity: reading from Loki -> 403           ← Envoy L7 rule
```

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
4. **Make alice a Grafana org Admin**, then have her add a Loki data source
   pointing at the gateway as `tenant-b`. She doesn't have tenant-b's
   password. Pointing it straight at `loki:3100` with a spoofed header gets
   dropped by Grafana's egress policy. Two layers, each enough on its own.
5. **Onboard tenant-c.** Namespace (the guard tells you what's missing),
   copy the CCNP, add an Alloy `stage.match` block, add a line to
   `09-grafana/setup-orgs.sh`, and a gateway user in `07-loki-gateway/install.sh`.
6. **Watch it live** with Hubble:
   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace tenant-a --protocol dns -f
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED -f
   ```
   (`ds/cilium` picks one agent, so you only see flows on that node.)

## What soft tenancy does NOT protect against

Be honest about the boundary before calling it production-ready:

- **Shared kernel.** A container escape on a node reaches every tenant's pods
  on that node. Stronger options: tenant-dedicated nodes (taints plus
  nodeSelectors), sandboxed runtimes (gVisor, Kata), or separate clusters.
- **Shared CoreDNS and Cilium agent.** A tenant flooding DNS degrades DNS for
  everyone. Every tenant DNS query also passes through the cilium-agent's DNS
  proxy, so an agent restart or upgrade briefly interrupts tenant DNS.
- **Grafana holds every tenant's gateway password.** A compromised Grafana
  crosses tenants. If that's unacceptable, run one Grafana per tenant (still
  in `observability`, never in the tenant's namespace).
- **Node resources.** Quotas cap CPU and memory, not disk IO or network bandwidth.
- **Loki at rest.** Tenants are separate directories on one volume, not
  separately encrypted.
- **Platform access.** Cluster admins, `kubectl port-forward`/`exec` into
  `observability`, and the unauthenticated Hubble UI see everything.
- **DNS patterns cover the `tenant-X` namespace only.** A tenant with a second
  namespace (`tenant-a-dev`) needs `*.tenant-a-dev.svc.cluster.local` added.

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
├── 06-loki/                        # values.yaml + install.sh
├── 07-loki-gateway/                # nginx: basic auth → X-Scope-OrgID
├── 08-alloy/                       # values.yaml (tenant mapping) + install.sh
├── 09-grafana/                     # values.yaml, install.sh, setup-orgs.sh
├── 10-observability-lockdown/      # policies.yaml + attack-demo.sh
├── 11-verify-logs.sh
└── 99-cleanup.sh                   # --all also deletes the generated credentials
```

## Troubleshooting

**Step 05: "tenant-a gets NXDOMAIN" fails, or `example.com` fails from tenant-a.**
Step 00 didn't take. Check
`kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.tofqdns-dns-reject-response-code}'`
and look for `nameError`.

**Grafana shows "no data" for alice.** Give Alloy a minute after step 08. Then
check the path piece by piece: `kubectl -n observability logs ds/alloy`, then
the gateway log (`tenant=... status`), then `./11-verify-logs.sh`.

**The loki-gateway pod crashes with `host not found in upstream`.** nginx
resolves `loki` at startup, so step 06 must run before step 07.

**After step 10, something in observability stopped working.** Find the drop:
`kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace observability --verdict DROPPED`.
Run it against each cilium pod, since each agent only sees its own node.

**Start over:** `./99-cleanup.sh` (add `--all` to also forget the passwords).
