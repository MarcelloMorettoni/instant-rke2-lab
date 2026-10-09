# Cilium POC: tenant isolation on a default-deny cluster, with kgateway

Two tenants share a cluster: `tenant-cilium-a` and `tenant-cilium-b`, each with
one workload. The cluster already denies all traffic by default (a Cilium
policy), and kgateway is the front door. The POC opens exactly what the
tenants need, and makes sure the path between them can never be opened by
mistake.

## What we want to achieve

1. **tenant-cilium-a cannot reach tenant-cilium-b, and the other way round.**
   Not by Service name, not by pod IP, not by a detour through the gateway.
2. **Each tenant works inside its own namespace**, and both apps are
   **reachable from outside through kgateway**.
3. **The isolation survives mistakes.** An allow added later by someone
   else can't open the path between the tenants.
4. **Every blocked connection is visible**, with its reason, and we can show
   what Cilium actually programmed into the kernel.

Done means this matrix (`./matrix.sh` prints it):

| from | to | result |
|---|---|---|
| tenant-cilium-a | `app.tenant-cilium-a` (own namespace) | allowed |
| tenant-cilium-a | `app.tenant-cilium-b` | **blocked** |
| tenant-cilium-b | `app.tenant-cilium-b` (own namespace) | allowed |
| tenant-cilium-b | `app.tenant-cilium-a` | **blocked** |
| you, via kgateway | `tenant-cilium-a.poc.lab`, `tenant-cilium-b.poc.lab` | allowed |
| a tenant, via kgateway | the other tenant's host | **blocked** |

## The design

The cluster starts closed, so every step **adds an allow** for one specific
path. Step 05 is the only one that adds denies.

```
                        kgateway-system
  you ──────────► [ kgateway proxy "cilium-poc" ] ──► tenant-cilium-a.poc.lab ──► app (2 pods)
  (port-forward)      ▲ xDS :9977 from the        └─► tenant-cilium-b.poc.lab ──► app (2 pods)
                      │ kgateway controller

  tenant-cilium-a ──✗──► tenant-cilium-b    never allowed (default deny), then denied (step 05)
  tenant-cilium-a ──✗──► the proxy          tenants' egress doesn't include it: no detour
```

| Step | Policy (`CiliumNetworkPolicy`) | Where | Allows / denies |
|---|---|---|---|
| 02 | `allow-own-namespace` | each tenant | **in:** node probes :8080, own pods. **out:** own pods, CoreDNS :53 |
| 03 | `cilium-poc-gateway` | kgateway-system | the proxy. **in:** node probes. **out:** CoreDNS, controller :9977, both apps :8080 |
| 03 | `cilium-poc-xds` | kgateway-system | the controller accepts this proxy on :9977 (adds an allow, changes nothing else) |
| 03 | `from-gateway` | each tenant | **in:** the proxy on :8080 |
| 04 | `mistake-allow-*` | both tenants | demo only: a→b, as someone's mistake |
| 05 | `deny-other-tenant` | each tenant | **deny** in and out with the other tenant. A deny beats any allow |

**Why the proxy label is trusted.** kgateway labels its proxy pods
`gateway.networking.k8s.io/gateway-name=<Gateway>`. The policies match that
label *and* the namespace `kgateway-system`, where only the platform can create
pods. A tenant can't pass itself off as the gateway.

## What's in this folder

| Path | What |
|---|---|
| `manifests/00-namespaces.yaml` | `tenant-cilium-a`, `tenant-cilium-b` (restricted Pod Security) |
| `manifests/01-workloads.yaml` | `app` in each: nginx answering `hello from tenant-cilium-x`, 2 replicas, Service on port 80 |
| `manifests/02-allow-own-namespace.yaml` | Probes, own namespace, DNS |
| `manifests/03-gateway.yaml` | Gateway `cilium-poc` (ClusterIP only), one HTTPRoute per tenant, and the gateway path's allows |
| `manifests/04-mistake-allow.yaml` | Demo only: a mistaken allow from a to b |
| `manifests/05-guardrail-deny.yaml` | Explicit deny between the tenants |
| `matrix.sh` | Who can reach whom right now, plus the latest Hubble drops. Read-only |
| `slides/` | The two slides, as a standalone HTML deck and as PNGs |

## Before you start

The manifests target a cluster that already has:

- **Cilium with default deny**, for traffic both in and out. The POC only adds
  allows on top of it. If the cluster's deny-all uses explicit *deny* rules
  (`ingressDeny`/`egressDeny`) that cover these namespaces, nothing here can
  override them; you'd need an exception from whoever owns that policy.
- **kgateway v2.x**: GatewayClass `kgateway`, controller in `kgateway-system`
  with the label `kgateway: kgateway`, and the Gateway API v1 CRDs.
- **CoreDNS** labelled `k8s-app=kube-dns` in `kube-system`. If pods resolve
  through NodeLocal DNSCache, see the note in `02-allow-own-namespace.yaml`.
- The image `docker.io/nginxinc/nginx-unprivileged:1.31-alpine`. Mirror it if
  the cluster can't pull from Docker Hub.
- Rights to create namespaces, CiliumNetworkPolicies (in the two tenants and in
  `kgateway-system`), and a Gateway plus GatewayParameters in `kgateway-system`.
- **Hubble** (optional), to show the drops.

The namespaces carry `tenant: cilium` so the lab's namespace guard
(`../soft-tenancy/01-namespaces/namespace-guard.yaml`) accepts them. The POC's
policies don't use that label.

Nothing is exposed outside the cluster: the proxy Service is ClusterIP, and you
reach it with `kubectl port-forward`, which goes through the kubelet rather than
the pod network.

## Run it

Run the commands from this folder, with your usual kubectl context. On the
lab, run `export KUBECONFIG=$PWD/../.state/kubeconfig` first. Give each policy
about 3 seconds to reach every node before running `./matrix.sh`.

**00 · Namespaces**

```bash
kubectl apply -f manifests/00-namespaces.yaml
```

**01 · Workloads.** Under default deny the pods start, but they can't talk to
anyone, not even DNS. If the cluster also polices traffic from the node
(`allow-localhost=policy`, see [the black box](#inside-the-black-box)), they
also stay `0/1` Ready, because the kubelet's probe is blocked.

```bash
kubectl apply -f manifests/01-workloads.yaml
```
```bash
for ns in tenant-cilium-a tenant-cilium-b; do kubectl get pods -n $ns -o wide; done
```
```bash
./matrix.sh
```

**02 · Allow each namespace to talk to itself.** The pods turn Ready and
same-namespace calls work. The other tenant is never mentioned, so it stays
unreachable.

```bash
kubectl apply -f manifests/02-allow-own-namespace.yaml
```
```bash
kubectl -n tenant-cilium-a rollout status deploy/app && kubectl -n tenant-cilium-b rollout status deploy/app
```
```bash
./matrix.sh
```

**03 · Open the front door.** The proxy can fetch its config and reach both
apps, and both apps accept it. The tenants still can't reach the proxy, so
there's no detour.

```bash
kubectl apply -f manifests/03-gateway.yaml
```
```bash
kubectl -n kgateway-system wait --for=condition=Programmed gateway/cilium-poc --timeout=180s
```
```bash
./matrix.sh
```

If the wait times out but
`kubectl -n kgateway-system get pods -l gateway.networking.k8s.io/gateway-name=cilium-poc`
shows the proxy Running and Ready, carry on.

**04 · A mistake.** Someone allows a → b on both ends. It works, which shows
that default deny alone only holds until someone adds an allow.

```bash
kubectl apply -f manifests/04-mistake-allow.yaml
```
```bash
./matrix.sh
```

**05 · The guardrail.** Explicit denies between the tenants. The mistake is
still in place, and it no longer opens anything.

```bash
kubectl apply -f manifests/05-guardrail-deny.yaml
```
```bash
./matrix.sh
```

Then remove the mistake:

```bash
kubectl delete -f manifests/04-mistake-allow.yaml
```

### What `./matrix.sh` should print

| from → to | 01 | 02 | 03 | 04 | 05 |
|---|---|---|---|---|---|
| a → `app.tenant-cilium-a` | blocked | allowed | allowed | allowed | allowed |
| a → `app.tenant-cilium-b` | blocked | blocked | blocked | **allowed** (the mistake) | **blocked** |
| b → `app.tenant-cilium-b` | blocked | allowed | allowed | allowed | allowed |
| b → `app.tenant-cilium-a` | blocked | blocked | blocked | blocked | blocked |
| you → gateway → `tenant-cilium-a.poc.lab` | n/a | n/a | allowed | allowed | allowed |
| you → gateway → `tenant-cilium-b.poc.lab` | n/a | n/a | allowed | allowed | allowed |
| a → gateway → `tenant-cilium-b.poc.lab` | n/a | n/a | blocked | blocked | blocked |
| b → gateway → `tenant-cilium-a.poc.lab` | n/a | n/a | blocked | blocked | blocked |

"Blocked" means curl gave up after 3 seconds: Cilium dropped the packets, so
nothing came back. "n/a": the gateway doesn't exist yet, and the script skips
those rows.

## Inside the black box

These commands show what Cilium does with the policies.

- **`cilium-dbg`** is the command-line tool inside every Cilium agent pod
  (it was called `cilium` before Cilium 1.15). It needs nothing installed on
  your machine. Each agent only knows the pods on its own node, so first
  pick a pod and find the agent next to it.
- **`cilium`** is the Cilium CLI you install on your machine. It's optional and
  used in section 0 only.

**Pick a pod to look at.** Use the *calling* tenant for drops: with default
deny on outgoing traffic, a packet is dropped as it leaves the caller.

```bash
NS=tenant-cilium-a
POD=$(kubectl -n $NS get pod -l app=app -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name)
EP=$(kubectl -n $NS get ciliumendpoint $POD -o jsonpath='{.status.id}')
ID=$(kubectl -n $NS get ciliumendpoint $POD -o jsonpath='{.status.identity.id}')
cdbg() { kubectl -n kube-system exec $AGENT -c cilium-agent -- cilium-dbg "$@"; }
echo "pod=$POD node=$NODE agent=$AGENT endpoint=$EP identity=$ID"
```

**0. How the cluster enforces default deny.**

With the Cilium CLI:

```bash
cilium status
```
```bash
cilium config view | grep -E '^(enable-policy|allow-localhost) '
```

Without it:

```bash
kubectl -n kube-system get configmap cilium-config -o jsonpath='enable-policy={.data.enable-policy} allow-localhost={.data.allow-localhost}{"\n"}'
```

- `enable-policy=always`: every pod is in default deny, policy or not.
- `enable-policy=default`: a cluster-wide policy creates the default deny.
- `allow-localhost=policy`: even the node's own health checks need an allow
  (step 02 has one). Empty or `auto`: the node can always reach its pods.

**1. Identities: who is who.** Each pod gets a number derived from its labels
and namespace. Both pods of a tenant share one number; the other tenant has a
different one. Policies are about these numbers, never IP addresses.

```bash
for ns in tenant-cilium-a tenant-cilium-b; do kubectl get ciliumendpoints -n $ns; done
```
```bash
cdbg identity get $ID
```

**2. Endpoints: is policy enforced on this pod?** Look at the two
`POLICY ENFORCEMENT` columns. `Enabled` in both directions means default deny
applies to that pod.

```bash
cdbg endpoint list
```

**3. Which identities each rule matches right now.** This is the translation
from "this namespace" and "the gateway proxy" to concrete numbers.

```bash
cdbg policy selectors
```

**4. What the kernel enforces.** This is the pod's eBPF policy map: one row per
identity and port that's allowed or denied, in each direction, with byte and
packet counters. After step 05, look for the `Deny` rows naming the other
tenant's identity.

```bash
cdbg bpf policy get $EP
```

**5. Watch drops live.** Run this in one terminal:

```bash
cdbg monitor --type drop
```

In a second terminal, try the forbidden call:

```bash
kubectl -n tenant-cilium-a exec deploy/app -- curl -s -m 3 http://app.tenant-cilium-b
```

Each drop reads `Policy denied`, with the source and destination identity
numbers (`identity X->Y`). For every decision, allowed ones included, use:

```bash
cdbg monitor --type policy-verdict
```

**6. The flow log, with reasons (Hubble).** This is live, for the pods on that
node:

```bash
kubectl -n kube-system exec $AGENT -c cilium-agent -- hubble observe -f --namespace tenant-cilium-a --namespace tenant-cilium-b
```

And the drops from every node in the last 10 minutes:

```bash
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do kubectl -n kube-system exec $p -c cilium-agent -- hubble observe --verdict DROPPED --since 10m --namespace tenant-cilium-a --namespace tenant-cilium-b -o compact; done
```

With the Cilium and Hubble CLIs on your machine, `cilium hubble port-forward`
followed by `hubble observe` gives the same view for the whole cluster at once.

**7. Where a Service name ends up.** Cilium swaps the Service IP for a pod IP
(no kube-proxy) before policy looks at the packet; then policy sees identities.

```bash
cdbg service list | grep -A3 "$(kubectl -n tenant-cilium-b get svc app -o jsonpath='{.spec.clusterIP}')"
```

## Roll back and clean up

To undo one step, delete its file, for example
`kubectl delete -f manifests/05-guardrail-deny.yaml`.

To remove everything the POC created, including its two policies and Gateway in
`kgateway-system`:

```bash
kubectl delete -f manifests/ --ignore-not-found
```

## Slides

[`slides/cilium-poc-slides.html`](slides/cilium-poc-slides.html) works in any
browser, offline included (fonts fall back to Arial and Courier New). Keys:
right arrow, space or click for next, left arrow for back, `N` for speaker
notes, `F` for full screen. Print to PDF gives one slide per page.

The same slides as images, to paste into another deck or a wiki page:

1. **The main components.** Cilium Operator and Hubble Relay run once per
   cluster; Agent, CNI plugin, Envoy and Hubble server run on every node, on
   top of the eBPF datapath. kgateway is drawn beside them: it is not part of
   Cilium.

   ![Cilium's main components](slides/01-cilium-components.png)

2. **Closed by default, opened on purpose.** This POC: default deny, the three
   steps that open exactly what's needed, and the guardrail.

   ![Tenant isolation on a default-deny cluster with kgateway](slides/02-namespace-isolation-kgateway.png)

## Going further

- **Label-driven onboarding.** A Kyverno `generate` rule can stamp steps 02 and
  05 into any namespace labelled, say, `isolation.lab/mode: strict`. A small
  Helm chart per tenant namespace does the same without a new controller.
- **One Gateway per tenant.** With one shared proxy, Cilium can't tell tenant
  a's gateway traffic from tenant b's on that hop (`../soft-tenancy`, step 12).
- **DNS filtering.** The other tenant's names return NXDOMAIN
  (`../soft-tenancy`, steps 00 and 03).

## Checked so far

The custom resources validate against the Cilium, Gateway API v1.6.1 and
kgateway v2.4.5 CRD schemas, using `generic/scripts/validate-crs.py`. The POC
has not been run on a cluster yet.
