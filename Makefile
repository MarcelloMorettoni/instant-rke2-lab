SHELL := /usr/bin/env bash
S := scripts

.PHONY: help all prereqs extras image vms cluster kubeconfig verify destroy clean status \
        gpu-host gpu-host-undo gpu remote-bundle \
        ssh-cp1 ssh-w1 ssh-w2 soft-tenancy soft-tenancy-verify soft-tenancy-clean \
        generic-render generic-validate generic-pipeline-test

help:
	@echo "instant-rke2-lab — RKE2 + Cilium on libvirt/KVM"
	@echo
	@echo "  make all         End-to-end: prereqs → image → vms → cluster → kubeconfig → verify"
	@echo "                   (with GPU_PCI set: also gpu-host before vms, gpu at the end)"
	@echo "  make prereqs     Install KVM/libvirt/kubectl, set up storage pool & SSH key"
	@echo "  make image       Download Ubuntu 24.04 cloud image"
	@echo "  make vms         Create + boot 3 VMs via cloud-init"
	@echo "  make cluster     Bootstrap RKE2 server, agents, and Cilium"
	@echo "  make kubeconfig  Pull kubeconfig to .state/kubeconfig and print it"
	@echo "  make verify      kubectl get nodes / pods / cilium"
	@echo "  make destroy     Tear down VMs, disks, kubeconfig (keeps image + SSH key for a fast rebuild)"
	@echo "  make clean       destroy + storage pool, images/, vms/, .state/ (asks; YES=1 skips)"
	@echo "  make status      Show libvirt + node status"
	@echo "  make ssh-cp1 / ssh-w1 / ssh-w2   SSH to a VM"
	@echo
	@echo
	@echo "  make gpu-host      GPU passthrough host prep: IOMMU, GPU → vfio-pci (GPU_PCI in config.env)"
	@echo "  make gpu           NVIDIA GPU Operator in the cluster + CUDA smoke test"
	@echo "  make gpu-host-undo Give the GPU back to the host (after make destroy)"
	@echo "  make remote-bundle kubeconfig + ssh config for using a lab on this server from another machine"
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

all: prereqs
	$(S)/15-gpu-host.sh --if-enabled
	$(MAKE) image vms cluster kubeconfig verify
	$(S)/60-gpu-operator.sh --if-enabled

prereqs:
	$(S)/00-host-prep.sh

gpu-host:
	$(S)/15-gpu-host.sh

gpu-host-undo:
	$(S)/15-gpu-host.sh --undo

gpu:
	$(S)/60-gpu-operator.sh

remote-bundle:
	$(S)/45-remote-bundle.sh

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

ssh-cp1:
	@ssh -i .state/ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@192.168.122.11

ssh-w1:
	@ssh -i .state/ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@192.168.122.12

ssh-w2:
	@ssh -i .state/ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@192.168.122.13

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
