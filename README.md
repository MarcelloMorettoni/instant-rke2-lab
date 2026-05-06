# instant-rke2-lab

A self-contained **RKE2 + Cilium** Kubernetes lab that runs on a single Linux
workstation in three KVM/libvirt VMs — without touching your host network or
your LAN.

One control-plane node, two workers, a NAT'd `virbr0` so the cluster is
invisible to the rest of your network, and a single `make all` from cold metal
to a working `kubectl get nodes`.

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

- **RKE2** (Rancher's hardened upstream Kubernetes) on the `stable` channel
- **Cilium** as the CNI with `kubeProxyReplacement: true` — kube-proxy is
  replaced by Cilium's eBPF datapath
- **Hubble** + Hubble UI for flow visibility
- 3 Ubuntu 24.04 VMs provisioned by cloud-init, static IPs on `virbr0`
- A kubeconfig on the host that talks to the API server through `virbr0`
- A few examples to run slinky on `slinky-lab` folder

## Requirements

- A Linux host (developed on Ubuntu 24.04, kernel 6.x)
- CPU with hardware virtualization (`vmx` / `svm`) and `/dev/kvm` present
- ~50 GiB free disk, ~40 GiB free RAM at the default sizing
- `sudo` access — `make prereqs` installs packages and configures libvirt

## Quickstart

```bash
git clone https://github.com/MarcelloMorettoni/instant-rke2-lab.git
cd instant-rke2-lab
make all
```

That runs, in order:

| Step              | What it does                                              | Touches                         |
| ----------------- | --------------------------------------------------------- | ------------------------------- |
| `make prereqs`    | Install KVM/libvirt/kubectl, libvirt storage pool, ssh key | host (apt + groups + libvirtd) |
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
RKE2_VERSION="v1.35.4+rke2r1"

# Match kubectl's apt channel to your cluster's minor
KUBECTL_REPO_CHANNEL="v1.35"
```

The repo is self-contained — clone it anywhere and it works. VM disks default
to `vms/` inside the repo. If you want them on a different mount point (e.g. a
fast NVMe), set `VM_DIR` in `config.env` before running `make all`.

## Operations

```bash
make status              # libvirt + node status
make ssh-cp1             # ssh into the control plane
make ssh-w1 / ssh-w2     # ssh into a worker
make destroy             # rip the lab down (keeps libvirt/kubectl/groups)
make all                 # rebuild from scratch
```

To reach the API server from another machine on your LAN, expose
`192.168.122.11:6443` via your host with an iptables/nftables DNAT, or switch
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
├── config.env              # tunables (sizes, IPs, RKE2 channel, Cilium flags)
├── scripts/
│   ├── lib.sh              # logging, ssh wrappers, sudo detection
│   ├── 00-host-prep.sh
│   ├── 10-fetch-image.sh
│   ├── 20-create-vms.sh
│   ├── 30-bootstrap-rke2.sh
│   ├── 40-fetch-kubeconfig.sh
│   ├── 50-verify.sh
│   └── 99-destroy.sh
├── manifests/
│   └── rke2-cilium-config.yaml   # Cilium HelmChartConfig template
├── slinky/                       # optional: SLURM-on-Kubernetes examples (run manually)
└── .state/                       # generated, gitignored: ssh_key, kubeconfig, node-token
```

## Troubleshooting

**`/dev/kvm` not present.** Enable AMD-V / Intel VT-x in BIOS.

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

**Tear down completely**, including packages and groups:

```bash
make destroy
sudo virsh pool-destroy rke2-lab && sudo virsh pool-undefine rke2-lab
sudo apt purge qemu-kvm libvirt-daemon-system libvirt-clients virtinst cloud-image-utils
sudo deluser $USER libvirt && sudo deluser $USER kvm
```

## Optional: Slinky (SLURM on Kubernetes)

The `./slinky/` folder contains a self-contained [Slinky](https://github.com/SlinkyProject/slurm-operator)
installation — SchedMD's SLURM operator for Kubernetes — along with scheduling
and MPI job examples targeting the two worker nodes.

It is **not part of `make all`**. Once your cluster is up, install it manually:

```bash
cd slinky
./install.sh          # deploys slurm-operator + a 2-node SLURM cluster
./scripts/submit.sh examples/01-hello.sbatch
```

See [`slinky/README.md`](./slinky/README.md) for the full walkthrough.

## Security note

This is a **lab**. The control plane writes its kubeconfig at mode `0644` so
the host can grab it; cloud-init disables password auth but the SSH key lives
unencrypted in `.state/ssh_key`; Cilium runs with permissive defaults and
Hubble UI is unauthenticated. Don't expose any of this to a network you don't
fully trust.

## License

Add your preferred license here (e.g. MIT, Apache-2.0).
