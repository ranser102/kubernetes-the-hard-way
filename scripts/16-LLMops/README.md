# Module 16 — LLMOps (Ollama + Open WebUI)

## Topology

| Workload    | Node   | Why |
|-------------|--------|-----|
| Ollama      | node-0 | Models on hostPath PV; needs CPU/RAM/disk |
| Open WebUI  | node-1 | ~2 GB image; keeps node-0 boot disk free |

Internal VPC IPs (static): `node-0` = `10.240.0.20`, `node-1` = `10.240.0.21`

## Connectivity (node-1 → node-0)

We do **not** rely on cross-node pod routing (`10.200.x` → `10.200.x`) or CoreDNS.

Instead, Open WebUI reaches Ollama over the **VPC network**:

```
Open WebUI pod (node-1, 10.200.1.x)
  → http://10.240.0.20:31434   (node-0 internal IP + NodePort)
  → kube-proxy on node-0
  → Ollama pod (node-0, 10.200.0.x)
```

Manifest settings:

- `ollama.yaml` — Service `ollama-service` is **NodePort** `31434`
- `open-webui.yaml` — `OLLAMA_BASE_URL=http://10.240.0.20:31434`, pinned to **node-1**

No extra GCP firewall rule is needed: the internal rule already allows all TCP between `10.240.0.0/24` and `10.200.0.0/16`.

### Why not ClusterIP?

ClusterIP and pod IPs route through the pod CIDR (`10.200.0.0/16`). After a node stop/start (e.g. machine-type resize), static pod routes from [configure-pod-routes.sh](../11-pod-routes/configure-pod-routes.sh) may exist but **pod-to-pod traffic can still fail** (`No route to host` / connection timeout). VPC routing between node internal IPs continues to work.

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

Or use `./scripts/16-LLMops/deploy-llmops.sh` (update it if env/NodePort defaults drift from the manifests).

## Verify Ollama connectivity

From node-1 host (VPC + NodePort — should work today):

```bash
ssh root@node-1 "curl -s http://10.240.0.20:31434/api/tags"
```

From Open WebUI pod:

```bash
kubectl exec deploy/open-webui -- python3 -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://10.240.0.20:31434/api/tags').read()))
"
```

Suspected causes when pod routing fails after reboot: missing static routes **or** worker sysctl not restored. Re-run [configure-pod-routes.sh](../11-pod-routes/configure-pod-routes.sh) — it now applies both routes and sysctl on workers.

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

## TODO — Verify cross-node pod connectivity

LLMOps currently uses **NodePort + VPC IP** (works without pod routing). After sysctl + routes are applied, confirm pod CIDR routing so you can optionally switch back to ClusterIP later.

- [ ] Run `./scripts/11-pod-routes/configure-pod-routes.sh` (routes + sysctl)
- [ ] Run `./scripts/11-pod-routes/verify-pod-routes.sh`
- [ ] Confirm cross-node pod reachability:

  ```bash
  OLLAMA_IP=$(kubectl get pod -l app=ollama -o jsonpath='{.items[0].status.podIP}')

  ssh root@node-1 "curl -s --connect-timeout 5 http://${OLLAMA_IP}:11434/api/tags"

  kubectl exec deploy/open-webui -- python3 -c "
  import urllib.request
  urllib.request.urlopen('http://${OLLAMA_IP}:11434/api/tags', timeout=10)
  print('pod-to-pod OK')
  "
  ```

- [ ] If pod routing works, optionally simplify back to ClusterIP:
  - `OLLAMA_BASE_URL=http://10.0.0.207:11434` (or `http://ollama-service:11434` once CoreDNS is installed)
  - Ollama Service type back to `ClusterIP`
