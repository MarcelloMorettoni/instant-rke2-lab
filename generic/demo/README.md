# Log flow demo: the whole platform in one namespace, for learning

The multi-tenant log platform (`generic/charts`) at toy size, in **one namespace,
`observability`**. Three tenants, each with an app that logs, plus a web
**demonstrator** that shows what happens to their logs at every hop:

```
tenant-a/b/c apps ─► OTel agent (every node) ─► Kafka ─► OTel gateway ─► Loki distributors ─► ingesters (3 zones) ─► object storage
                                                                                 ▲
Grafana (local users) ─► read gateway (kgateway) ─► query frontend ─► scheduler ─► queriers ─► index gateways
Loki ruler ─► metrics store ◄─ tenant guard ◄─ read gateway
```

- **Same components and data path as production**:
  - the OTel agent and gateway run the production configs (`generic/collector/*.yaml`);
  - the read gateway has the same views and keys;
  - Loki is distributed, with zone-aware ingesters, index gateways, a ruler and caches;
  - grafana-sync is the same script.
- **Built for a cluster that already runs kgateway and Cilium with default deny**:
  - the demo adds a Gateway, routes and policies to your kgateway; it installs no controller;
  - every flow it needs is allowed by a CiliumNetworkPolicy, shipped in the same step as the
    component it opens.
- **Toy-sized and simplified** (not for production):
  - one namespace;
  - Kafka without TLS/SCRAM;
  - keys derived from a seed, and local Grafana passwords;
  - SeaweedFS as the S3 store;
  - one or two replicas of most things.

## What you need

- A Kubernetes cluster with **3 nodes** (about 4 vCPU and 8 GiB each). The demo requests
  roughly 2 CPU, 9 GiB of memory and 40 GiB of persistent volumes (default storage class).
- **kgateway already installed**, with the Gateway API CRDs. The chart was validated against
  kgateway v2.4.5 (it uses `GatewayParameters`, `TrafficPolicy` with `apiKeyAuth`,
  `ListenerPolicy`, `DirectResponse`). Set these in the values if yours differ:
  - `readGateway.gatewayClassName` (default `kgateway`);
  - `readGateway.controllerNamespace` (default `kgateway-system`);
  - `readGateway.controllerLabels` (default `kgateway: kgateway`).
- **Cilium**, with default deny. The policies cover:
  - DNS (to `kube-dns` in `kube-system`; change `network.dns` if yours differs, and set
    `network.dns.cidrs` if pods resolve through NodeLocal DNSCache);
  - the API server (`kube-apiserver` entity) and kubelet probes (`host` entity);
  - every flow between the demo's pods.
- `kubectl` and, for the Helm way, `helm` 3.
- Images from Docker Hub and quay.io, or a proxy:
  [`chart/values-proxy.example.yaml`](chart/values-proxy.example.yaml) sets one registry for
  all of them.
- No Azure, no identity provider. Zones are logical (zone-a/b/c); no zone labels are needed.

## Install it

### Step by step (for a session with the team)

[`steps/`](steps/README.md) has one manifest per step, in install order. Each file's header
says what it adds and how to know it's ready. The walkthrough applies them and waits:

```bash
generic/demo/walkthrough.sh --context <your-test-cluster> --pause
```

- `--pause` stops before each step, so you can explain what is about to appear.
- `--context` is required and must be the current kubectl context: the script never guesses
  the cluster.

| Step | What appears |
|---|---|
| 00 | Strimzi's CRDs (kgateway's and the Gateway API's are already on the cluster) |
| 01 | Namespace `observability` (privileged Pod Security: the agent reads `/var/log/pods`) |
| 02 | The Strimzi operator (runs Kafka) |
| 03 | Object storage: SeaweedFS (S3) and its buckets |
| 04 | Kafka: 3 nodes, topic `otel-logs` (6 partitions, 3 replicas), HTTP bridge |
| 05 | Loki, distributed: 2 distributors, 6 ingesters (2 per zone), 2 frontends, 2 schedulers, 3 queriers, 2 index gateways, compactor, ruler, caches |
| 06 | OpenTelemetry: the agent on every node, the gateway (2 pods, one consumer group) |
| 07 | Read gateway on your kgateway: one view + key per tenant (and `platform` for admin); metrics store + tenant guard; a policy in the kgateway controller's namespace so the Envoy pods get their config |
| 08 | Grafana, and grafana-sync: one org per tenant, data sources, local users |
| 09 | The demonstrator |
| 10 | The tenants: `tenant-a` (payments), `tenant-b` (orders), `tenant-c` (inventory), each logging from the start |

Each step brings its own CiliumNetworkPolicies, so it works the moment it's applied.

By hand, the same thing: `kubectl apply --server-side -f steps/00-crds/`, then
`kubectl apply -f steps/NN-*.yaml` in order (every object names its namespace), with the
`# wait:` commands from each header. Resume with `--from 05`, remove it all with `--delete`.
The walkthrough first checks that kgateway (its GatewayClass and CRDs) and Cilium are there.

### With Helm (one command)

```bash
kubectl create namespace observability
kubectl label namespace observability pod-security.kubernetes.io/enforce=privileged
helm upgrade --install log-flow-demo generic/demo/chart -n observability --wait --timeout 20m
```

Same objects as the steps (they are rendered from this chart by `render-steps.py`).

## Use it

```bash
kubectl -n observability port-forward svc/log-flow-demonstrator 8080:8080   # http://localhost:8080
kubectl -n observability port-forward svc/grafana 3000:80                   # http://localhost:3000
```

**The demonstrator** has three parts:

1. **The platform.** Every component, its pods and nodes, and live lines per second per tenant.
2. **Generate workload and watch it flow.** Pick a tenant and how hard its app should log
   (lines/s, for how long, via stdout or OTLP). One column per hop, refreshed every 3 s from
   each component's own metrics:
   - the agents;
   - Kafka's partitions (rate, leader, lag);
   - the gateway pods and the partitions each one owns;
   - the distributors (coloured by tenant);
   - the ingesters by zone;
   - chunks flushed to object storage;
   - the ruler's recorded rate per tenant, about a minute behind.
3. **Follow one line, step by step.** Sends one traced line from the tenant's app and confirms
   each hop from the component itself:
   - the agent on the app's node;
   - the Kafka partition, offset and leader;
   - the gateway pod that owns that partition;
   - the distributors;
   - the 3 ingesters, one per zone, that got the new stream;
   - the query fan-out (frontend, scheduler, the queriers that pulled work, ingesters asked);
   - isolation (other tenants see nothing; admin sees it; a wrong key gets 401);
   - the chunk in object storage;
   - the ruler's recorded series.

**Grafana** has local users, all with the password `change-me-now`:

| User | Sees |
|---|---|
| `admin` | every tenant (org `platform`) |
| `tenant-a` / `tenant-b` / `tenant-c` | only their own org |

In Explore → data source **Loki**, try `{service_name="payments"}` as tenant-a. The card
numbers and IBANs in the app's lines arrive masked. Data source **Log metrics (recorded)**
has `obs:log_lines:rate1m` and `obs:log_errors:rate1m`.

## A 20-minute session with the team

1. **The platform:** walk the three lanes of part 1. Open a few boxes: one agent per node,
   ingesters labelled zone-a/b/c.
2. **Generate workload:** start tenant-b at 200 lines/s.
   - Its colour grows at the gateways and distributors.
   - The Kafka partitions it lands on speed up, and each partition is consumed by exactly one
     gateway pod.
   - Every ingester zone takes pushes.
   - A minute later, the ruler's number for tenant-b rises.
3. **Follow one line** as tenant-a, and read the cards in order. The first eight take seconds;
   object storage and the ruler take 1-3 minutes, which is a good moment for questions.
4. **Grafana:**
   - sign in as tenant-a and find the line (`{service_name="trace-<id>"}`);
   - sign in as tenant-b: nothing;
   - sign in as admin: everything.

## The network policies (Cilium, default deny)

Each step adds the allows its components need, and nothing more:

| Step | Policy | Allows |
|---|---|---|
| 02 | `strimzi-cluster-operator` | → API server, → the Kafka cluster's pods |
| 03 | `seaweedfs`, `seaweedfs-buckets` | Loki, the bucket Job and the demonstrator → S3 :8333 |
| 04 | `kafka`, `kafka-bridge` | Kafka pods ↔ each other (any port); OTel agents, gateways and the bridge → :9092; operator → all; demonstrator → exporter :9404 and bridge :8080 |
| 05 | `loki`, `loki-distributor-from-otel-gateway`, `loki-query-frontend-from-read-gateway`, `rollout-operator` | Loki ↔ Loki (any port), → S3, ruler → metrics store; **only the OTel gateways push** (distributors :3100); **only the read gateway queries** (frontends :3100); API server → rollout-operator webhooks :8443 |
| 06 | `otel-agent`, `otel-gateway` | tenants' pods → agent :4317/:4318; agent → API server, Kafka; gateway → Kafka, distributors |
| 07 | `read-gateway`, `tenant-guard`, `metrics-store`, and `observability-read-gateway-xds` in the kgateway controller's namespace | Grafana and demonstrator → Envoy :8080; Envoy → frontends, guard, controller xDS :9977; guard → store :9090 |
| 08 | `grafana`, `grafana-sync` | grafana-sync → Grafana :3000; Grafana → read gateway |
| 09 | `log-flow-demonstrator` | → API server, this namespace's pods (each allows it in on its own ports), tenants' apps :8080 |
| 10 | one per tenant namespace | demonstrator → app :8080; app → the agent :4317/:4318 |

Every policy also allows DNS and kubelet probes (`host`). People reach Grafana and the
demonstrator with `kubectl port-forward`, which goes through the kubelet, not the pod
network. A tenant pod can reach nothing in `observability` but its node's agent.

## When something is stuck

| Symptom | Look at |
|---|---|
| Anything times out | dropped traffic: `hubble observe -n observability --verdict DROPPED` (or `-n tenant-a`) names the flow; compare with the table above |
| The Gateway never gets `Programmed` | the Envoy pods can't reach the kgateway controller (:9977): check `readGateway.controllerNamespace` / `controllerLabels`, and that `observability-read-gateway-xds` exists in that namespace |
| Ingester pods can't be evicted (node drain hangs) | the API server can't reach the rollout-operator's webhooks: see `network.webhookFromEntities` |
| Kafka not Ready | `kubectl -n observability get kafka,kafkanodepool,pods -l strimzi.io/cluster=logs`; the PVCs need a default storage class; dropped flows between the Kafka pods (Hubble) |
| Loki pods Pending | `kubectl -n observability describe pod <pod>`: usually CPU/memory or volumes |
| No logs at all | the agent: `kubectl -n observability logs ds/otel-agent`; the gateways: `kubectl -n observability logs sts/otel-gateway` |
| Grafana has no orgs | `kubectl -n observability logs job/grafana-sync-now` (it retries until Grafana and the gateway are up) |
| A demonstrator step fails | the card says which component didn't confirm; its pod's logs say why |

## How it's verified

- `scripts/validate.sh` renders the chart and checks that `steps/` matches it. It loads Loki's
  and both collectors' configs into the real binaries and checks every custom resource
  against its CRD.
- [`test-demonstrator.sh`](test-demonstrator.sh) runs the demonstrator end to end in Docker:
  - real Kafka, the Strimzi bridge and kafka_exporter;
  - the collectors with this chart's rendered configs;
  - Loki with its rules, SeaweedFS, Prometheus and the tenant guard;
  - the tenant app.

  It traces a line through all 10 steps, then generates workload and checks it at every
  hop (20 checks). The Kubernetes API and the read gateway are stand-ins there; on a real
  cluster they are the real ones.
