# Module 16 — LLMOps (Ollama + Open WebUI)

## Topology

| Workload    | Node   | Why |
|-------------|--------|-----|
| Ollama      | node-0 | Models on hostPath PV; needs CPU/RAM/disk |
| Open WebUI  | node-1 | ~2 GB image; keeps node-0 boot disk free |

Internal VPC IPs (static): `node-0` = `10.240.0.20`, `node-1` = `10.240.0.21`

Ollama stores model data in a `70Gi` hostPath PV on `node-0`. This assumes the
LLMOps infrastructure path from module 17, where worker boot disks default to
`100GB`. If you use smaller workers, reduce the PV/PVC size in `ollama.yaml`.

## Connectivity

This KTHW cluster does not run CoreDNS, so Open WebUI cannot use the
`ollama-service` DNS name.

Instead, Ollama uses a fixed ClusterIP from the service CIDR (`10.0.0.0/24`),
and Open WebUI connects to that IP directly:

```
Open WebUI pod (node-1, 10.200.1.x)
  → http://10.0.0.207:11434   (ollama-service ClusterIP)
  → kube-proxy
  → Ollama pod (node-0, 10.200.0.x)
```

Manifest settings:

- `ollama.yaml` — Service `ollama-service` is **ClusterIP** `10.0.0.207`
- `open-webui.yaml` — `OLLAMA_BASE_URL=http://10.0.0.207:11434`, pinned to **node-1**

No NodePort or extra external firewall rule is needed for Ollama.

## Deploy

```bash
# Pre-pull images (recommended — first pull can take 30+ min)
ssh root@node-0 "crictl pull ollama/ollama:latest"
ssh root@node-1 "crictl pull ghcr.io/open-webui/open-webui:main"

kubectl apply -f scripts/16-LLMops/ollama.yaml
kubectl wait --for=condition=Ready pod -l app=ollama --timeout=300s

kubectl exec deploy/ollama -- ollama pull llama3.2

kubectl apply -f scripts/16-LLMops/open-webui.yaml
kubectl wait --for=condition=Ready pod -l app=open-webui --timeout=300s

kubectl port-forward svc/open-webui 8080:8080
# → http://localhost:8080
```

Or use `./scripts/16-LLMops/deploy-llmops.sh`.

## Verify Ollama connectivity

From Open WebUI pod:

```bash
kubectl exec deploy/open-webui -- python3 -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://10.0.0.207:11434/api/tags').read()))
"
```

From node-1 host:

```bash
ssh root@node-1 "curl -s http://10.0.0.207:11434/api/tags"
```

If this fails, rerun [configure-pod-routes.sh](../11-pod-routes/configure-pod-routes.sh)
and [verify-cross-node-pods.sh](../11-pod-routes/verify-cross-node-pods.sh).

## Node sysctl (cross-node pod routing)

After the module 15 resize/reboot, pod-to-pod traffic failed even when `ip route` entries looked correct. These sysctl settings on **node-0** and **node-1** fix forwarding:

| Parameter | Value | Why |
|-----------|-------|-----|
| `net.ipv4.ip_forward` | `1` | Nodes must forward packets between pod subnet and VPC interface |
| `net.ipv4.conf.all.rp_filter` | `2` | Loose mode — allows asymmetric paths for routed pod traffic |
| `net.ipv4.conf.default.rp_filter` | `2` | Same, for new interfaces |

Applied live and persisted to `/etc/sysctl.d/kubernetes.conf`:

```bash
# Manual fix (what we applied on the nodes — live only until reboot unless persisted)
for node in node-0 node-1; do
  ssh -i ~/.ssh/google_compute_engine root@${node} "
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.conf.all.rp_filter=2
    sysctl -w net.ipv4.conf.default.rp_filter=2
  "
done

# Preferred — routes + sysctl together, idempotent, persisted across reboots
./scripts/11-pod-routes/configure-pod-routes.sh
```

Verify on a worker:

```bash
ssh root@node-0 "sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter"
```

## Verify Cross-Node Pod Connectivity

LLMOps uses ClusterIP, so cross-node pod networking must work.

```bash
./scripts/11-pod-routes/configure-pod-routes.sh
./scripts/11-pod-routes/verify-pod-routes.sh
./scripts/11-pod-routes/verify-cross-node-pods.sh
```

You can also test Ollama's direct Pod IP:

```bash
OLLAMA_IP=$(kubectl get pod -l app=ollama -o jsonpath='{.items[0].status.podIP}')
ssh root@node-1 "curl -s --connect-timeout 5 http://${OLLAMA_IP}:11434/api/tags"
```

If CoreDNS is added later, `OLLAMA_BASE_URL` can be changed to
`http://ollama-service:11434`.
