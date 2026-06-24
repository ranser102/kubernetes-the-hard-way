# Module 17 — LLMOps Infrastructure Clean Run

This module provisions the KTHW infrastructure directly in the shape expected by
the LLMOps workload from module 16.

Use it instead of `scripts/01-prereq/provision-infra01.sh` when you want a fresh
cluster for Ollama + Open WebUI.

## What Changes

| Node | Default machine type | Default boot disk |
|------|----------------------|-------------------|
| `server` | `e2-small` | `20GB` |
| `node-0` | `e2-standard-4` | `100GB` |
| `node-1` | `e2-standard-4` | `100GB` |

The larger worker boot disks are the GCP persistent disk equivalent of increasing
an EBS volume. They give room for container images and Ollama model data stored
through the `hostPath` PV in `scripts/16-LLMops/ollama.yaml`.

## Scripts

Before running the full deployment, make sure the jumpbox/node binaries are
downloaded and organized:

```bash
./scripts/02-jumpbox/install-cli-tools-macbook-m2.sh
```

`deploy-all.sh` checks for these files before it creates or deletes VMs.

```bash
# Infrastructure only: VPC, firewall, static IP, server, workers
./scripts/17-LLMops-infrastructure/provision-llmops-infra.sh

# Kubernetes only: run modules 03 through 12 after infrastructure exists
./scripts/17-LLMops-infrastructure/bootstrap-k8s.sh

# Full cluster: infrastructure + Kubernetes provisioning
./scripts/17-LLMops-infrastructure/deploy-all.sh
```

`deploy-all.sh` is the master script for a clean LLMOps-ready Kubernetes cluster.
It stops before module 16, so Ollama + Open WebUI remain a separate workload
deployment step.

By default the infrastructure step is a clean run: it deletes and recreates
`server`, `node-0`, and `node-1` so stale machine types or disk sizes do not
survive.

Network, subnet, and firewall rules are reused when present. The static IP is
recreated by default during clean runs.

## Common Overrides

```bash
# Larger worker disks for more local model storage
WORKER_BOOT_DISK_SIZE=150GB \
  ./scripts/17-LLMops-infrastructure/deploy-all.sh

# Larger workers
WORKER_MACHINE_TYPE=e2-standard-8 \
  ./scripts/17-LLMops-infrastructure/deploy-all.sh

# Non-destructive mode: keep existing VMs and create only missing resources
CLEAN_RUN=false \
  ./scripts/17-LLMops-infrastructure/deploy-all.sh

# Skip verification or smoke tests during Kubernetes bootstrap
RUN_VERIFY=false RUN_SMOKE_TEST=false \
  ./scripts/17-LLMops-infrastructure/deploy-all.sh
```

## Follow-Up LLMOps Deploy

After `deploy-all.sh` finishes, deploy the LLMOps workload:

```bash
./scripts/16-LLMops/deploy-llmops.sh
```

Module 15 is no longer required for this path because the workers are already
created with the LLMOps machine type and larger disks.
