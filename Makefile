SHELL := /usr/bin/env bash
S := scripts

.PHONY: help all solo prereqs extras image vms cluster kubeconfig verify destroy clean status \
        ssh ssh-cp1 ssh-w1 ssh-w2 ssh-solo soft-tenancy soft-tenancy-verify soft-tenancy-clean \
        generic-render generic-validate generic-pipeline-test

help:
	@echo "instant-rke2-lab — RKE2 + Cilium on libvirt/KVM"
	@echo
	@echo "  make all         End-to-end: prereqs → image → vms → cluster → kubeconfig → verify"
	@echo "  make solo        The same with ONE VM (control plane + workloads) instead of three"
	@echo "  make prereqs     Install KVM/libvirt/kubectl, set up storage pool & SSH key"
	@echo "  make image       Download Ubuntu 24.04 cloud image"
	@echo "  make vms         Create + boot the VMs via cloud-init (3, or 1 for solo)"
	@echo "  make cluster     Bootstrap RKE2 server, agents, and Cilium"
	@echo "  make kubeconfig  Pull kubeconfig to .state/kubeconfig and print it"
	@echo "  make verify      kubectl get nodes / pods / cilium"
	@echo "  make destroy     Tear down VMs, disks, kubeconfig (keeps image + SSH key for a fast rebuild)"
	@echo "  make clean       destroy + storage pool, images/, vms/, .state/ (asks; YES=1 skips)"
	@echo "  make status      Show libvirt + node status"
	@echo "  make ssh         SSH to the control plane (NODE=worker1 for another VM)"
	@echo "  make ssh-cp1 / ssh-w1 / ssh-w2 / ssh-solo   SSH to a VM by name"
	@echo
	@echo
	@echo "  make soft-tenancy         Soft multi-tenancy lab: tenants a, b, c; Cilium isolation (a -> c only),"
	@echo "                            Grafana stack per tenant, kgateway. Grafana logins: password test-tenant"
	@echo "  make soft-tenancy-verify  Re-run the network, observability and ingress checks"
	@echo "  make soft-tenancy-clean   Remove everything soft-tenancy created"
	@echo
	@echo "  make generic-render        Production AKS Loki design (./generic): render tenants.yaml"
	@echo "  make generic-validate      Offline checks: charts, Loki/OTel configs, CRD schemas, alerts, Terraform"
	@echo "  make generic-pipeline-test OTel agent → gateway → Loki in Docker (tenancy, masking, spoofing)"
	@echo
	@echo "  make extras               helm + jq on the host, for the optional labs below (not in 'make all')"
	@echo
	@echo "  Optional extras: see ./slinky/ for SLURM-on-Kubernetes examples (run manually)"

all: prereqs image vms cluster kubeconfig verify

# One VM (control plane + workloads) instead of three. Same steps as `all`;
# the topology is saved in .state/topology, so destroy/verify/status/ssh and
# a later `make all` follow it.
solo:
	TOPOLOGY=solo $(MAKE) all

prereqs:
	$(S)/00-host-prep.sh

# Optional: tools for soft-tenancy/, slinky/, generic/. Not part of `all`.
extras:
	$(S)/05-extras.sh

image:
	$(S)/10-fetch-image.sh

vms:
	$(S)/20-create-vms.sh

cluster:
	$(S)/30-bootstrap-rke2.sh

kubeconfig:
	$(S)/40-fetch-kubeconfig.sh --print

verify:
	$(S)/50-verify.sh

destroy:
	$(S)/99-destroy.sh

clean:
	$(S)/99-clean.sh

status:
	@sudo virsh list --all
	@echo
	@if [ -f .state/kubeconfig ]; then \
	  KUBECONFIG=$$PWD/.state/kubeconfig kubectl get nodes -o wide; \
	else \
	  echo '(no kubeconfig yet — run "make kubeconfig")'; \
	fi

ssh:
	@$(S)/ssh-node.sh $(NODE)

ssh-cp1:
	@$(S)/ssh-node.sh cp1

ssh-w1:
	@$(S)/ssh-node.sh worker1

ssh-w2:
	@$(S)/ssh-node.sh worker2

ssh-solo:
	@$(S)/ssh-node.sh solo

# Soft multi-tenancy lab (soft-tenancy/). Needs the cluster from `make all`.
soft-tenancy:
	soft-tenancy/up.sh

soft-tenancy-verify:
	soft-tenancy/05-verify-network.sh
	soft-tenancy/11-verify-observability.sh
	soft-tenancy/13-verify-ingress.sh

soft-tenancy-clean:
	soft-tenancy/99-cleanup.sh

generic-render:
	python3 generic/scripts/render-tenants.py

generic-validate:
	generic/scripts/validate.sh

generic-pipeline-test:
	generic/scripts/pipeline-test.sh
