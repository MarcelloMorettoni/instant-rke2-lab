SHELL := /usr/bin/env bash
S := scripts

.PHONY: help all prereqs image vms cluster kubeconfig verify destroy status \
        ssh-cp1 ssh-w1 ssh-w2 slinky slinky-uninstall

help:
	@echo "Slinky — RKE2 + Cilium lab on libvirt/KVM"
	@echo
	@echo "  make all         End-to-end: prereqs → image → vms → cluster → kubeconfig → verify"
	@echo "  make prereqs     Install KVM/libvirt/kubectl, set up storage pool & SSH key"
	@echo "  make image       Download Ubuntu 24.04 cloud image"
	@echo "  make vms         Create + boot 3 VMs via cloud-init"
	@echo "  make cluster     Bootstrap RKE2 server, agents, and Cilium"
	@echo "  make kubeconfig  Pull kubeconfig to .state/kubeconfig and print it"
	@echo "  make verify      kubectl get nodes / pods / cilium"
	@echo "  make destroy     Tear down VMs, disks, and lab state"
	@echo "  make status      Show libvirt + node status"
	@echo "  make ssh-cp1 / ssh-w1 / ssh-w2   SSH to a VM"

all: prereqs image vms cluster kubeconfig verify

prereqs:
	$(S)/00-host-prep.sh

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

slinky:
	cd slinky && ./install.sh

slinky-uninstall:
	cd slinky && ./uninstall.sh
