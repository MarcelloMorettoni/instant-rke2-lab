# 09 · Helm charts and environments

The whole platform installs as **two Helm releases**, driven by **one folder per environment**.

| Chart | Release / namespace | Contains | Why separate |
|---|---|---|---|
| [`charts/log-platform-operators`](../charts/log-platform-operators) | `log-platform-operators` in `kgateway-system` | Gateway API v1.6.1 + kgateway v2.4.5 CRDs (`crds/`), the kgateway controller, External Secrets Operator 2.11.0, and namespace `loki` | Cluster-level operators and their CRDs. A single release can't install CRDs and use them at the same time. |
| [`charts/log-platform`](../charts/log-platform) | `log-platform` in **`loki`** | Loki 7.3.0, the OTel agent + OTel gateway (collector chart 0.173.1), Grafana 13.2.5, plus every platform object: namespaces, priority classes, storage class, NetworkPolicies, read gateway and per-tenant views, Grafana ingress, External Secrets, org mapping, grafana-sync, PodMonitors | Everything that belongs to the log platform |

- Dependencies are **vendored** (`charts/*/charts/*.tgz`), so installs work without internet
  access to chart repositories.
- To publish both charts to the bank's registry:
  ```bash
  helm package charts/log-platform
  helm push log-platform-0.1.0.tgz oci://<acr>/charts
  ```

## Environment folder

```text
environments/
  example/                  copy to environments/<env>/
    values.yaml             every environment-specific value, for BOTH charts
    cluster.env             KUBE_CONTEXT: install.sh refuses any other cluster
    overlays.txt            optional overlays, one per line (e.g. test-cluster.yaml)
    terraform.yaml          optional: `terraform output -raw environment_values`
    generated-images.yaml   GENERATED from global.imageRegistry (scripts/render-images.py)
  overlays/
    test-cluster.yaml       no dedicated node pools, small sizes
    no-zones.yaml           cluster without availability zones
```

Values are applied in this order: chart defaults, `values.yaml`, `terraform.yaml`, the
overlays, `generated-images.yaml`, then `rendered/values-tenants.yaml` (the tenants).

## Image registry: one setting

```yaml
# environments/<env>/values.yaml
global:
  imageRegistry: myproxy.bank.internal:5000
```

Every image becomes `<imageRegistry>/<upstream path>:<tag>`. With the setting above,
`scripts/images.sh <env>` prints:

```text
myproxy.bank.internal:5000/external-secrets/external-secrets:v2.11.0
myproxy.bank.internal:5000/grafana/grafana:13.2.2-distroless
myproxy.bank.internal:5000/grafana/loki:3.6.11
myproxy.bank.internal:5000/grafana/rollout-operator:v0.38.0
myproxy.bank.internal:5000/kgateway-dev/kgateway:v2.4.5
myproxy.bank.internal:5000/library/memcached:1.6.39-alpine
myproxy.bank.internal:5000/library/python:3.13-alpine
myproxy.bank.internal:5000/otel/opentelemetry-collector-contrib:0.160.0
myproxy.bank.internal:5000/prom/memcached-exporter:v0.15.4
myproxy.bank.internal:5000/kgateway-dev/envoy-wrapper:v2.4.5
```

How the one setting reaches every image:
- **Most charts** (Loki, Memcached, the collectors, Grafana, and this chart's own templates)
  read `global.imageRegistry` directly.
- **Three charts don't**: Loki's rollout-operator, kgateway, and External Secrets.
  `scripts/render-images.py <env>` writes their fields into `generated-images.yaml`.
  `install.sh` runs it on every install, so after changing the registry you only re-run
  the install.

Other things to know:
- Upstream paths are kept, including images from other registries: `kgateway-dev/...` comes
  from cr.kgateway.dev and `external-secrets/...` from ghcr.io. Configure the proxy to
  serve each upstream under those paths.
- `library/` is used for Docker Hub "official" images (memcached, python).
- Empty `imageRegistry` = pull from the upstream registries.
- If the proxy needs credentials, add `imagePullSecrets` per chart, or better, configure
  AKS to authenticate to it (kubelet identity / ACR connected registry).

## Sign-in provider

```yaml
auth:
  provider: entra        # entra | keycloak | oidc | disabled (mock: alice, bob, carol + admin)
  admin:                 # a local admin in EVERY mode (server admin, every tenant)
    user: admin
    password: change-me-now   # initial only; change it at first login
  mock:
    password: change-me-now   # initial password of the mock users
```

**The local admin exists in every mode, with the default password `change-me-now` until
someone changes it.** Change it right after the install. `helm install` NOTES and
`smoke-test.sh` warn while it's still the default.

The settings each provider needs, the Keycloak client setup, and the mock users are in
[02 · Sign-in to Grafana](02-tenancy-and-access.md#sign-in-to-grafana-authprovider). The
chart refuses to render if a provider's required settings are missing.

## Commands

```bash
# once per environment
cp -r environments/example environments/test
$EDITOR environments/test/values.yaml environments/test/cluster.env
echo test-cluster.yaml >> environments/test/overlays.txt      # a test cluster without dedicated pools
terraform -chdir=infra/terraform output -raw environment_values > environments/test/terraform.yaml

# every install / upgrade / tenant change
scripts/install.sh test

# only check (no cluster needed)
scripts/validate.sh test
scripts/images.sh test          # the image list for the proxy team
```

What `install.sh <env>` does:

| Step | Action |
|---|---|
| 00 | Render the tenants and images |
| 10 | `helm upgrade --install log-platform-operators` (`kgateway-system`); it also creates namespace `loki` |
| 20 | Create the missing read-gateway keys in Key Vault |
| 30 | `helm upgrade --install log-platform` (`loki`); restart Grafana if the org mapping changed |
| 40 | Run grafana-sync once, now |
| 50 | Smoke test |

To resume from a step: `scripts/install.sh test 30`.

### Plain Helm, or GitOps (Argo CD / Flux)

All inputs are files. There are no post-renderers and no `--set`, so the same values work in
Argo CD `valueFiles` or a Flux `HelmRelease`:

```bash
python3 scripts/render-tenants.py && python3 scripts/render-images.py test   # commit the results
helm upgrade --install log-platform-operators charts/log-platform-operators -n kgateway-system --create-namespace \
  -f environments/test/values.yaml -f environments/test/terraform.yaml -f environments/test/generated-images.yaml
helm upgrade --install log-platform charts/log-platform -n loki \
  -f environments/test/values.yaml -f environments/test/terraform.yaml \
  -f environments/overlays/test-cluster.yaml \
  -f environments/test/generated-images.yaml -f rendered/values-tenants.yaml
```

Things to know:
- **The platform release must be in namespace `loki`**: Loki's rollout-operator only works
  in its release namespace. The chart fails with a clear message otherwise.
- **CRDs** in `charts/log-platform-operators/crds/` are installed once and never upgraded by
  Helm. Upgrade them with `kubectl apply --server-side -f charts/log-platform-operators/crds/`.
- The chart **refuses to render** without the rendered tenants, `global.clusterName`,
  `keyVault.url`, the storage account, the API server CIDRs (when policies are on), or the
  Grafana hostname (when ingress is on).
- **grafana-sync** is a CronJob (every 10 min): it creates the Grafana orgs and keeps each
  org's data source key current after rotations. It never deletes orgs.

## Validated

`scripts/validate.sh` checks the charts' real output. It renders both charts (the environment,
and also with the test-cluster overlay), then:
- loads the Loki config and every tenant's limits into Loki 3.6.11;
- loads both collector configs into `otelcol-contrib` 0.160.0;
- validates all 33 custom resources against their CRD schemas;
- renders every `auth.provider`, and checks that each missing setting is refused;
- runs `promtool` on the alerts;
- runs Terraform `validate` and `test`.

The test-cluster overlay was also checked by inspecting the rendered pods: none requires the
dedicated node pool, and the ingesters stay pinned to their zones.

`scripts/auth-test.sh` starts the chart's Grafana image with each provider's rendered
settings and accounts, and runs the real `grafana-sync` code against it (36 checks):
- **Every mode**: `admin` / `change-me-now` signs in, is server admin, and is Admin of the
  platform org. The password form is at `/login?disableAutoLogin=true`, and the sync runs as
  its own automation account.
- **`entra` and `keycloak`**: Grafana redirects to the right endpoint with the client ID,
  PKCE and scopes.
- **`disabled`**:
  - alice, bob and carol (`change-me-now`) are each in exactly their org, and can't read
    another org's data source;
  - passwords changed by the admin and by alice survive the next sync run;
  - the sync keeps working after the admin changed its password.

What needs a real identity provider: a real login, and the check that group membership in the
token maps to the right org.
