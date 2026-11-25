# instant-rke2-lab

A self-contained **RKE2 + Cilium** Kubernetes lab that runs on a single Linux
workstation in three KVM/libvirt VMs — without touching your host network or
your LAN.

One control-plane node, two workers, a NAT'd `virbr0` so the cluster is
invisible to the rest of your network, and a single `make all` from cold metal
to a working `kubectl get nodes`. Prefer one VM? `make solo` builds the same
cluster as a single node — see [Single VM: `make solo`](#single-vm-make-solo).

```
                ┌──────────────────────────────────────────────┐
                │           Linux workstation (host)           │
                │                                              │
                │   host NIC ── 192.168.x.x      (your LAN)    │
                │   virbr0   ── 192.168.122.1/24 (libvirt NAT) │
                │      │                                       │
                │      ├── cp1     192.168.122.11   server     │
                │      ├── worker1 192.168.122.12   agent      │
                │      └── worker2 192.168.122.13   agent      │
                │                                              │
                │   kubectl ──► https://192.168.122.11:6443    │
                └──────────────────────────────────────────────┘
```

## What you get

- **RKE2** (Rancher's hardened upstream Kubernetes) from the `stable` channel,
  pinned to one exact version for every node
- **Cilium** as the CNI with `kubeProxyReplacement: true` — kube-proxy is
  replaced by Cilium's eBPF datapath
- **Hubble** + Hubble UI for flow visibility
- 3 Ubuntu 24.04 VMs provisioned by cloud-init, static IPs on `virbr0`
- A kubeconfig on the host that talks to the API server through `virbr0`
- A few examples to run slinky on `slinky-lab` folder

## Requirements

- A Linux host running Ubuntu 24.04 or 26.04 (the host-prep script uses `apt`)
- CPU with hardware virtualization (`vmx` / `svm`) and `/dev/kvm` present
- ~50 GiB free disk, ~40 GiB free RAM at the default sizing
- `sudo` access — `make prereqs` installs packages and configures libvirt

### What `make prereqs` installs

Only what the raw cluster needs. The optional labs' tools are in
`make extras` (below) and are never installed by `make all`.

| Package / tool                  | Source                    | Used by                                             |
| ------------------------------- | ------------------------- | --------------------------------------------------- |
| `curl`, `ca-certificates`, `gnupg` | apt                    | image download, kubectl apt repo key                |
| `gettext-base` (`envsubst`)     | apt                       | Cilium manifest rendering (`make cluster`)          |
| `openssh-client`                | apt                       | `ssh-keygen`, `ssh`/`scp` to the VMs                |
| `acl` (`setfacl`)               | apt                       | lets QEMU reach `vms/` under a `0750` home          |
| `qemu-system-x86`               | apt                       | the KVM hypervisor                                  |
| `qemu-utils` (`qemu-img`)       | apt                       | backing-file qcow2 disks (`make vms`)               |
| `libvirt-daemon-system`, `libvirt-clients` | apt            | `libvirtd`, `virsh`                                 |
| `libvirt-daemon-config-network` | apt                       | the default NAT network (`virbr0`)                  |
| `virtinst` (`virt-install`)     | apt                       | creating the VMs                                    |
| `cloud-image-utils` (`cloud-localds`), `genisoimage` | apt  | cloud-init seed ISOs                                |
| `kubectl`                       | pkgs.k8s.io (`KUBECTL_REPO_CHANNEL`) | `make verify`, `make status`              |

### Optional: `make extras` (soft-tenancy, slinky, generic)

Not part of `make all`. Run it only if you want the optional labs:

| Package / tool | Source                                       | Used by                     |
| -------------- | -------------------------------------------- | --------------------------- |
| `jq`           | apt                                          | soft-tenancy, generic       |
| `helm`         | get.helm.sh, sha256-checked (`HELM_VERSION`) | soft-tenancy, slinky, generic |

The generic lab also needs `python3` and `docker`; install those yourself.

Before installing anything, the script checks that apt has every package
name, so a missing name stops it with a clear error instead of leaving a
half-prepared host.

### What was missing or wrong before (fixed Nov 2026)

- **`qemu-kvm` no longer exists on Ubuntu 26.04.** It was in the same
  `apt-get install` as everything else, so that one name failed the whole
  install: `virt-install`, `cloud-localds`, libvirt and `kubectl` were never
  installed. Replaced by `qemu-system-x86`.
- **`qemu-utils` was not listed.** `qemu-img` came in only as a side
  dependency. It's now installed explicitly.
- **`libvirt-daemon-config-network` was not listed.** The script's fallback
  for a missing `default` network only printed "install
  libvirt-daemon-config-network". It's now installed up front.
- **`openssh-client` was not listed.** `ssh-keygen`, `ssh` and `scp` were
  assumed to be on the host already.
- **`helm` was never installed.** soft-tenancy and generic stopped with
  "helm not installed", and slinky piped an unpinned script from the helm
  `main` branch into bash. The opt-in `make extras` now installs a pinned,
  checksummed release, and all three labs point to it. `jq` moved there too,
  since only the optional labs use it on the host.
- **QEMU couldn't read the VM disks under `$HOME`.** Ubuntu creates home
  directories as `0750`, so `libvirt-qemu` couldn't reach `vms/` in a repo
  cloned there. `make prereqs` now grants search-only ACLs (`acl` package)
  on the parent directories.
- **`bridge-utils` was removed.** Nothing in the lab uses `brctl`; the
  network is libvirt's NAT bridge.

## Quickstart

```bash
git clone https://github.com/MarcelloMorettoni/instant-rke2-lab.git
cd instant-rke2-lab
make all
```

That runs, in order:

| Step              | What it does                                              | Touches                         |
| ----------------- | --------------------------------------------------------- | ------------------------------- |
| `make prereqs`    | Install KVM/libvirt/kubectl, libvirt storage pool, ssh key | host (apt + groups + libvirtd + ACLs) |
| `make image`      | Download the Ubuntu 24.04 cloud image                      | `images/`                       |
| `make vms`        | Create + boot 3 VMs via cloud-init, wait for SSH           | libvirt domains                 |
| `make cluster`    | Install RKE2 server + Cilium, then 2 RKE2 agents           | VMs only                        |
| `make kubeconfig` | Pull kubeconfig and rewrite the server URL                 | `.state/kubeconfig`             |
| `make verify`     | `kubectl get nodes / pods` from the host                   | read-only                       |

When it's done:

```bash
export KUBECONFIG=$PWD/.state/kubeconfig
kubectl get nodes -o wide
kubectl -n kube-system get pods
```

## Single VM: `make solo`

```bash
make solo
```

Same steps as `make all`, same RKE2 + Cilium setup, but **one VM** that is the
control plane and runs every workload:

|                 | `make all` (multi)                    | `make solo`                     |
| --------------- | ------------------------------------- | ------------------------------- |
| VMs             | cp1 .11, worker1 .12, worker2 .13     | solo `192.168.122.10`           |
| Size            | 4+6+6 vCPU, 8+16+16 GiB, 60+80+80 GB  | up to 16 vCPU / 40 GiB, 200 GB (sized to the host, below) |
| Pods per node   | 110 (kubelet default)                 | 200 (`KUBELET_MAX_PODS`)        |
| API server      | `https://192.168.122.11:6443`         | `https://192.168.122.10:6443`   |
| SSH             | `make ssh-cp1`, `ssh-w1`, `ssh-w2`    | `make ssh-solo` (or `make ssh`) |

RKE2 servers take workloads by default, so nothing is tainted. Cilium's
operator already runs one replica. The pod limit is raised because one node
now carries the whole cluster (the full Kubeflow platform is ~50 deployments,
plus jobs and pipeline steps);
200 stays inside the /24 Cilium gives each node.

**Size.** The solo VM is as big as the multi lab's total, but never bigger
than the host: vCPUs = the host's CPU count (max 16), RAM = host RAM minus
8 GiB for the host itself (max 40 GiB). A 14-CPU / 30 GiB laptop gets
14 vCPU / ~22 GiB, which is enough for the full Kubeflow platform (~12 GiB).
Override either for one build:

```bash
SOLO_VCPUS=8 SOLO_MEM_MIB=16384 make solo
```

Why not just 40 GiB everywhere: QEMU reserves guest RAM up front, and Linux
refuses a single allocation larger than RAM + swap — the VM fails to start
with `cannot set up guest memory 'pc.ram': Cannot allocate memory`. The
three multi VMs don't hit this because each one is 16 GiB or less.
`make vms` now checks this before calling virt-install.

No branch or separate config is needed: `TOPOLOGY` in
[`config.env`](./config.env) picks the VM list, and `make solo` just runs
`TOPOLOGY=solo make all`.

**The choice is remembered.** `make vms` writes it to `.state/topology`; every
later step reads it, so `make cluster`, `verify`, `status`, `ssh`, `destroy`
and even a plain `make all` act on the solo VM without being told. Asking for
the other topology while one is built stops with an error — switch with:

```bash
make destroy && make all     # solo → multi
make destroy && make solo    # multi → solo
```

`make destroy` always removes what is actually built and clears
`.state/topology`.

The add-ons run unchanged. `slinky/` spreads its two slurmd pods across
nodes only as a preference, so on solo both land on the one VM (the
multi-node examples still run, just not across machines). `soft-tenancy/` and
Kubeflow (`~/kubeflow`, which reads the lab's VM list) don't depend on the
node count.

## SSH keys

The lab uses a **dedicated SSH keypair** that lives only on your machine — it
is never committed and never leaves the host.

- On first `make prereqs`, an `ed25519` keypair is generated at
  `.state/ssh_key` (private) and `.state/ssh_key.pub` (public).
- The public key is injected into each VM via cloud-init so `ubuntu@<vm-ip>`
  works without a password.
- `.state/` is in `.gitignore` — pushing the repo will never publish the key.
- `make destroy` does not delete the keypair. Wipe `.state/` if you want a
  fully clean slate.

**Want to use your own key instead?** Drop it in place before running
`make vms`:

```bash
cp ~/.ssh/id_ed25519      .state/ssh_key
cp ~/.ssh/id_ed25519.pub  .state/ssh_key.pub
chmod 600 .state/ssh_key
```

Any key type that OpenSSH supports works (`ed25519`, `rsa`, `ecdsa`). If
`.state/ssh_key` already exists, `make prereqs` won't overwrite it.

> Heads up: if you re-run `make vms` after changing the key, the existing VMs
> still trust the *previous* public key (cloud-init only runs on first boot).
> Either run `make destroy && make all`, or `ssh-copy-id` the new key in
> manually.

## Tunables

All knobs live in [`config.env`](./config.env). Edit before `make all`. Common
changes:

```bash
# Bigger workers
VM_LIST=(
  "cp1     4  8192  60 192.168.122.11 server"
  "worker1 8 24576 100 192.168.122.12 agent"
  "worker2 8 24576 100 192.168.122.13 agent"
)

# Pin a specific RKE2 version instead of "stable"
RKE2_VERSION="v1.35.10+rke2r1"

# Match kubectl's apt channel to your cluster's minor
KUBECTL_REPO_CHANNEL="v1.35"
```

The repo is self-contained — clone it anywhere and it works. VM disks default
to `vms/` inside the repo. If you want them on a different mount point (e.g. a
fast NVMe), set `VM_DIR` in `config.env` before running `make all`.

## Operations

```bash
make status              # libvirt + node status
make ssh                 # ssh into the control plane (cp1, or solo); NODE=worker1 for another
make ssh-cp1             # ssh into the control plane
make ssh-w1 / ssh-w2     # ssh into a worker
make ssh-solo            # ssh into the solo VM
make destroy             # delete the VMs, disks, kubeconfig, node-token
make clean               # destroy + storage pool, images/, vms/, .state/ (asks first)
make all                 # rebuild
```

To reach the API server from another machine on your LAN, expose
`192.168.122.11:6443` (`.10` for solo) via your host with an iptables/nftables DNAT, or switch
`LIBVIRT_NETWORK` to a bridge. The lab ships NAT-only by default so it doesn't
collide with your home/office network.

## How it works

### Networking

The VMs attach to libvirt's **default NAT network** (`virbr0`,
192.168.122.0/24). Each VM gets a static address via cloud-init's
`network-config v2` so the bootstrap can hardcode them. Outbound traffic is
masqueraded through the host. Nothing on your LAN sees these VMs.

### Storage

A libvirt **storage pool** is registered at `vms/`, which keeps AppArmor and
libvirt's path policies happy. Each VM uses a backing-file qcow2 on top of the
immutable cloud image, so disks start tiny and grow on write.

### RKE2 + Cilium

The control plane is configured with:

- `cni: cilium` — RKE2 ships the bundled Cilium chart
- `disable-kube-proxy: true` — kube-proxy is replaced by Cilium's eBPF
- `tls-san` includes the host LAN IP so external `kubectl` can be wired up

The Cilium chart is customized via a `HelmChartConfig`
([`manifests/rke2-cilium-config.yaml`](./manifests/rke2-cilium-config.yaml))
that's uploaded to `/var/lib/rancher/rke2/server/manifests/` *before*
`rke2-server` starts. RKE2's built-in Helm controller picks it up on first
reconcile and sets:

- `kubeProxyReplacement: true`
- `bpf.masquerade: true`
- `ipam.mode: kubernetes`
- `socketLB.hostNamespaceOnly: true`, `cni.exclusive: false` — required for
  Istio sidecars (e.g. Kubeflow) next to kube-proxy replacement; see
  [Cilium's Istio guide](https://docs.cilium.io/en/latest/network/servicemesh/istio/)
- Hubble + Hubble UI on

The control plane writes its node-token; the bootstrap script reads it and
joins the two agents. The agents inherit the same Cilium config from the
cluster — no per-agent CNI work.

### Cloud-init

Each VM gets a NoCloud seed ISO with:

- Hostname, the `ubuntu` user with the lab's generated SSH pubkey
- Static IP via `network-config v2` matched against `en*`
- `swapoff`, `br_netfilter`, `ip_forward` — Kubernetes preconditions
- Password auth disabled

## Repository layout

```
.
├── Makefile                # all the entry points
├── config.env              # tunables (TOPOLOGY, sizes, IPs, RKE2 channel, Cilium flags)
├── scripts/
│   ├── lib.sh              # logging, ssh wrappers, sudo detection
│   ├── 00-host-prep.sh
│   ├── 05-extras.sh        # optional: helm + jq for the add-on labs
│   ├── 10-fetch-image.sh
│   ├── 20-create-vms.sh
│   ├── 30-bootstrap-rke2.sh
│   ├── 40-fetch-kubeconfig.sh
│   ├── 50-verify.sh
│   ├── 99-destroy.sh
│   ├── 99-clean.sh         # destroy + pool, images/, vms/, .state/
│   └── ssh-node.sh         # interactive ssh to a VM by name (make ssh*)
├── manifests/
│   └── rke2-cilium-config.yaml   # Cilium HelmChartConfig template
├── slinky/                       # optional: SLURM-on-Kubernetes examples (run manually)
├── soft-tenancy/                 # optional: two isolated tenants + per-tenant logs (step by step)
└── .state/                       # generated, gitignored: ssh_key, kubeconfig, node-token, topology
```

## Troubleshooting

**`/dev/kvm` not present.** Enable AMD-V / Intel VT-x in BIOS.

**`make prereqs` fails with "No apt candidate for: …".** A package name
doesn't exist on your Ubuntu release (or `universe` is disabled). The script
checks every name before installing so nothing is half-installed.

**VM fails to start: `Could not open '…/disk.qcow2': Permission denied`.**
QEMU runs as `libvirt-qemu` and can't traverse a `0750` home directory.
`make prereqs` grants it search-only access (`setfacl -m u:libvirt-qemu:x`)
on each parent of `vms/` and `images/`; re-run it if you moved the repo.

**`make cluster` fails with `curl: (22) … 404` after "using stable as
release".** RKE2's installer looks the channel up at `update.rke2.io`; when
that service answers 404 it silently treats the word `stable` as a version
and asks GitHub for `/download/stable/…`. `make cluster` now resolves the
version on the host first and, if `update.rke2.io` doesn't answer, takes the
newest GitHub release of the `KUBECTL_REPO_CHANNEL` minor (e.g. `v1.35`). The
same exact version goes to the server and every agent. To skip the lookup,
set `RKE2_VERSION` in `config.env`. Re-running `make cluster` after this
error is safe.

**`virt-install` permission denied** — you're not yet in the `libvirt` group.
Either re-login after `make prereqs` or let the script keep falling back to
`sudo` (`lib.sh` detects this automatically).

**A VM never reaches SSH.** `sudo virsh console <name>` to watch boot output.
Most often cloud-init couldn't reach an apt mirror through NAT — check
`ip route` on the host and `systemctl status libvirtd`.

**`make cluster` hangs at "Waiting for cp1 to be Ready".** RKE2 + Cilium
image pulls can take a few minutes on a first run. SSH in (`make ssh-cp1`)
and tail `sudo journalctl -fu rke2-server`. The "D-Bus connection terminated"
warning during `systemctl enable --now rke2-server` is cosmetic.

**Which teardown?**

| Command        | Removes                                                                 | Keeps                                   | Next `make all` |
| -------------- | ----------------------------------------------------------------------- | --------------------------------------- | --------------- |
| `make destroy` | VMs + disks, `.state/kubeconfig`, `.state/node-token`                    | cloud image, SSH key, storage pool, host setup | skips the image download |
| `make clean`   | all of the above + storage pool `rke2-lab`, `images/`, `vms/`, `.state/` (SSH key, soft-tenancy credentials) | host packages, groups, libvirt network, ACLs | starts from nothing |

`make clean` asks for confirmation; `make clean YES=1` skips the prompt.

**Tear down completely**, including packages and groups:

```bash
make clean YES=1
sudo apt purge qemu-system-x86 libvirt-daemon-system libvirt-clients libvirt-daemon-config-network virtinst cloud-image-utils kubectl
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /usr/local/bin/helm            # only if you ran `make extras`
sudo deluser $USER libvirt && sudo deluser $USER kvm
```

## Optional: Slinky (SLURM on Kubernetes)

The `./slinky/` folder contains a self-contained [Slinky](https://github.com/SlinkyProject/slurm-operator)
installation — SchedMD's SLURM operator for Kubernetes — along with scheduling
and MPI job examples targeting the two worker nodes (on `make solo` both
slurmd pods share the one VM).

It is **not part of `make all`**. Once your cluster is up, install it manually:

```bash
make extras           # helm + jq on the host (once)
cd slinky
./install.sh          # deploys slurm-operator + a 2-node SLURM cluster
./scripts/submit.sh examples/01-hello.sbatch
```

See [`slinky/README.md`](./slinky/README.md) for the full walkthrough.

## Optional: Soft multi-tenancy (Cilium + Loki + Grafana)

The `./soft-tenancy/` folder is a step-by-step exercise. Two tenants,
`tenant-a` and `tenant-b`, share the cluster but can't reach each other
(Cilium cluster-wide policies with explicit deny, filtered DNS, Pod Security
`restricted`, an admission guard). Each tenant logs into Grafana and sees
only its own logs (Loki multi-tenancy, an authenticating read gateway, one
Grafana org per tenant). Verify scripts after each half prove it, including
what happens when someone makes a mistake.

Like Slinky, it's **not part of `make all`**:

```bash
make extras                   # helm + jq on the host (once)
cd soft-tenancy
./00-cilium-dns/apply.sh      # then follow README.md, steps 01 → 11
```

See [`soft-tenancy/README.md`](./soft-tenancy/README.md) for the design and walkthrough.

## Security note

This is a **lab**. The control plane writes its kubeconfig at mode `0644` so
the host can grab it; cloud-init disables password auth but the SSH key lives
unencrypted in `.state/ssh_key`; Cilium runs with permissive defaults and
Hubble UI is unauthenticated. Don't expose any of this to a network you don't
fully trust.

## License

Add your preferred license here (e.g. MIT, Apache-2.0).
