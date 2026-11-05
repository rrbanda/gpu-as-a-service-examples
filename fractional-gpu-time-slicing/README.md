# GPU Time Slicing with vLLM (RHOAI 3.5)

Enable **NVIDIA GPU time slicing** per [Red Hat OpenShift AI 3.5 — Chapter 8: Enable GPU time slicing](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_accelerators/about-gpu-time-slicing_accelerators), then pack **two vLLM servers** onto one physical GPU.

> RHOAI product term is **GPU time slicing**, not “fractional GPU.” Time slicing shares processing time across workloads. Unlike MIG, it provides **no memory or fault isolation**.

## What the RHOAI 3.5 docs say (Chapter 8)

GPU time slicing lets multiple workloads share one physical GPU by dividing processing time into short alternating slots. The NVIDIA GPU Operator applies this from a `time-slicing-config` ConfigMap.

Documented considerations:

- **Memory sharing:** all workloads share GPU memory; one high-memory workload can impact others
- **No strict isolation:** unlike MIG
- **GPU compatibility:** supported on specific NVIDIA GPUs
- **OOM risk:** increasing `replicas` increases Out of Memory risk

## Validated hardware

| Item | Value |
|---|---|
| GPU | NVIDIA A10G (~23 GB) — **not MIG-capable** |
| Time-slicing profile key | `a10g` (same role as `tesla-t4` in the RHOAI T4 example) |
| Replicas per physical GPU | `2` |
| Model | `Qwen/Qwen2.5-0.5B-Instruct` via `vllm serve` |

## Prerequisites (from RHOAI 3.5 Ch 8)

- Logged in to OpenShift with `cluster-admin`
- NVIDIA GPU Operator installed and configured
- Nodes with NVIDIA GPUs that support time slicing
- OpenShift CLI (`oc`)

## Apply — RHOAI 3.5 Chapter 8 procedure

### Step 1 — Create `time-slicing-config` ConfigMap

Create ConfigMap `time-slicing-config` in the GPU Operator namespace (`nvidia-gpu-operator`):

```bash
oc apply -f manifests/operator/time-slicing-config.yaml
```

Profile shape matches the RHOAI T4 example (`version`, `flags.migStrategy`, `sharing.timeSlicing`, `renameByDefault`, `failRequestsGreaterThanOne`, `resources[].name`, `resources[].replicas`), with:

- profile key `a10g` (instead of `tesla-t4`)
- `replicas: 2` (docs allow changing this; higher values increase OOM risk)

### Step 2 — Update `gpu-cluster-policy` devicePlugin config

```bash
oc patch clusterpolicy gpu-cluster-policy --type=merge \
  -p "$(cat manifests/operator/clusterpolicy-deviceplugin-patch.json)"
```

This sets (RHOAI-documented fields):

```yaml
spec:
  devicePlugin:
    config:
      name: time-slicing-config
      default: a10g
```

### Step 3 — Label MachineSet / nodes with the profile key

RHOAI requires label:

```yaml
nvidia.com/device-plugin.config: a10g
```

**If MachineSets exist** (OpenShift Machine API):

```bash
# List MachineSets
oc get machineset -n openshift-machine-api

# Patch the GPU MachineSet (replace NAME)
oc patch machineset NAME -n openshift-machine-api --type=merge \
  -p '{"spec":{"template":{"spec":{"metadata":{"labels":{"nvidia.com/device-plugin.config":"a10g"}}}}}}'
```

MachineSet YAML shape from RHOAI 3.5:

```yaml
spec:
  template:
    spec:
      metadata:
        labels:
          nvidia.com/device-plugin.config: a10g
```

**If no MachineSets** (some lab / managed layouts): label existing GPU nodes directly so the RHOAI verification command succeeds:

```bash
./manifests/operator/label-gpu-nodes.sh
# equivalent:
# oc label node <gpu-node> nvidia.com/device-plugin.config=a10g --overwrite
```

### Verification (exact RHOAI 3.5 commands)

```bash
oc get configmap time-slicing-config -n nvidia-gpu-operator -o yaml
oc get clusterpolicy gpu-cluster-policy -o yaml
oc get nodes --show-labels | grep nvidia.com/device-plugin.config
```

Also confirm time slicing is active:

```bash
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns=NAME:.metadata.name,PRODUCT:.metadata.labels.nvidia\\.com/gpu\\.product,PLUGINCFG:.metadata.labels.nvidia\\.com/device-plugin\\.config,REPLICAS:.metadata.labels.nvidia\\.com/gpu\\.replicas,STRATEGY:.metadata.labels.nvidia\\.com/gpu\\.sharing-strategy,ALLOC:.status.allocatable.nvidia\\.com/gpu
```

Expect: `PLUGINCFG=a10g`, `REPLICAS=2`, `STRATEGY=time-slicing`, `ALLOC=2` per physical GPU.

RHOAI note: if workloads do not appear to share the GPU, verify the NVIDIA device plugin is running and the correct labels are applied.

## Workload demo — two vLLM servers on one GPU

Chapter 8 configures **operator-level sharing**. These Deployments demonstrate the resulting capacity: two pods each request `nvidia.com/gpu: 1` and schedule on the same physical GPU.

```bash
oc apply -k manifests/workloads
oc rollout status deploy/vllm-qwen-a -n fractional-gpu-demo --timeout=600s
oc rollout status deploy/vllm-qwen-b -n fractional-gpu-demo --timeout=600s
oc get pods -n fractional-gpu-demo -o wide
```

| Deployment | Runtime | Model |
|---|---|---|
| `vllm-qwen-a` | `vllm serve` (`vllm/vllm-openai:v0.32.0`) | `Qwen/Qwen2.5-0.5B-Instruct` |
| `vllm-qwen-b` | same | same |

`--gpu-memory-utilization 0.35` keeps each server within shared A10G memory (docs: all workloads share GPU memory).

### Inference check (no credentials)

```bash
oc exec -n fractional-gpu-demo deploy/vllm-qwen-a -- \
  curl -sS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":24}'

oc exec -n fractional-gpu-demo deploy/vllm-qwen-b -- \
  curl -sS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":24}'
```

## Success criteria

- [ ] ConfigMap `time-slicing-config` exists in `nvidia-gpu-operator` with profile `a10g`
- [ ] ClusterPolicy `devicePlugin.config.name=time-slicing-config` and `default=a10g`
- [ ] Nodes show label `nvidia.com/device-plugin.config=a10g` (RHOAI verification)
- [ ] Nodes show `nvidia.com/gpu.sharing-strategy=time-slicing` and `nvidia.com/gpu.replicas=2`
- [ ] Both vLLM pods Ready; preferably on the same node
- [ ] Each pod still requests `nvidia.com/gpu: 1` (time slicing is operator-side oversubscription)
- [ ] Both `/v1/chat/completions` succeed

## Scope notes (accurate vs RHOAI)

| Topic | Accurate statement |
|---|---|
| Time slicing vs MIG | Time slicing = shared memory, no fault isolation. MIG = hardware isolation (A100/H100/A30). A10G is not MIG-capable. |
| Resource name | Pods still request `nvidia.com/gpu: 1`. There is no `nvidia.com/gpu: 0.5` API. |
| `failRequestsGreaterThanOne` | Set to `false` to match the RHOAI 3.5 ConfigMap example. |
| Workload packaging | Ch 8 does not prescribe InferenceService. These Deployments prove shared capacity. RHOAI dashboard serving can additionally use Hardware Profiles + ServingRuntimes after time slicing is enabled. |
| Secrets | Manifests contain no cluster URLs, passwords, tokens, or pull secrets. Public HF model only. |

## Cleanup

```bash
oc delete -k manifests/workloads
# Optional: remove node labels / revert ClusterPolicy devicePlugin.config / delete ConfigMap
```

## Platform reference

- RHOAI 3.5 Enable GPU time slicing: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_accelerators/about-gpu-time-slicing_accelerators
