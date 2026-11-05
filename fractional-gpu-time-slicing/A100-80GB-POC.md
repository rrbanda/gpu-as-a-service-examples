# PoC guide: 2× A100 80GB — what to prove (and what not to)

**Hardware assumed:** 2× NVIDIA A100 80GB (160 GB total HBM)  
**Validated pattern in this repo:** time slicing + small vLLM servers (see [README.md](README.md) / [EVIDENCE.md](EVIDENCE.md) on A10G).  
**This page:** sizing and procedure for an **A100-80GB** start PoC — checked against public vLLM/NVIDIA guidance before publish.

## Memory facts (must get right)

| Fact | Value | Implication |
|---|---|---|
| Llama-class **70B BF16/FP16 weights** | ~**140 GB** | Does not fit on 1× A100 80GB |
| **TP=2** on 2× A100 80GB | ~70 GB weights **per GPU** | Leaves ~**10 GB/GPU** for KV cache + overhead — **tight** |
| **TP=4** on 4× A100 80GB | ~35 GB weights per GPU | Comfortable KV headroom (typical recommendation) |
| Time slicing `replicas: 2` | 2 **scheduling slots** per GPU | **Not** “50% reserved memory” per pod |
| Two full 70B copies on 2× A100 | ~280 GB weights | **Impossible** on 160 GB |

Sources for the 70B / TP sizing: public vLLM deployment guidance (weights ≈ 70B × 2 bytes; TP=2 is minimum/tight on 2×80GB; TP=4 preferred for concurrency).

## Decision: two separate PoC tracks

Do **not** combine 70B serving and time-sliced packing on the same two cards.

```text
Track A — Prove GPU time slicing (packing)
  Use SMALL models only
  Enable time slicing replicas: 2 on the A100 pool
  Run 2–4 small vLLM pods (same or different models)

Track B — Prove 70B on 2× A100 80GB
  Disable time slicing on that pool (dedicated GPUs)
  One vLLM server with --tensor-parallel-size 2
  Expect limited concurrency / short context unless quantized
```

| Requested idea | Viable on 2× A100 80GB? |
|---|---|
| 4 pods × “50% GPU” each running **70B** | **No** |
| Time-slice so **two** 70B services share the 2 cards | **No** (memory) |
| Time-slice **small** models, 2 pods per A100 | **Yes** (Track A) |
| One **70B TP=2** dedicated on both cards | **Yes, tight** (Track B) |
| A100 **MIG** for medium models with isolation | **Yes** (optional; separate from Ch 8 time slicing) |

---

## Track A — How to prove time slicing on 2× A100 80GB

Same RHOAI 3.5 Chapter 8 procedure as this repo, with an **A100 profile key**.

### A1. Operator config (admin)

Create/adapt ConfigMap profile (example `a100-80gb`, `replicas: 2` ≈ two slots per card → “half scheduling share,” **not** half VRAM guaranteed):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: nvidia-gpu-operator
data:
  a100-80gb: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
          - name: nvidia.com/gpu
            replicas: 2
```

Patch ClusterPolicy:

```json
{
  "spec": {
    "devicePlugin": {
      "config": {
        "name": "time-slicing-config",
        "default": "a100-80gb"
      }
    }
  }
}
```

Label GPU MachineSet/nodes:

```text
nvidia.com/device-plugin.config=a100-80gb
```

### A2. Verify (RHOAI Ch 8)

```bash
oc get configmap time-slicing-config -n nvidia-gpu-operator -o yaml
oc get clusterpolicy gpu-cluster-policy -o yaml
oc get nodes --show-labels | grep nvidia.com/device-plugin.config

oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns=NAME:.metadata.name,PRODUCT:.metadata.labels.nvidia\\.com/gpu\\.product,PLUGINCFG:.metadata.labels.nvidia\\.com/device-plugin\\.config,REPLICAS:.metadata.labels.nvidia\\.com/gpu\\.replicas,STRATEGY:.metadata.labels.nvidia\\.com/gpu\\.sharing-strategy,ALLOC:.status.allocatable.nvidia\\.com/gpu
```

Expect on **each** A100 node: `REPLICAS=2`, `STRATEGY=time-slicing`, `ALLOC=2`  
(2 physical GPUs → **4** schedulable `nvidia.com/gpu` slots cluster-wide.)

### A3. Workloads (small models only)

Reuse this repo’s pattern ([manifests/workloads](manifests/workloads)):

- 2 Deployments (same or **different** small models)
- Each: `nvidia.com/gpu: "1"`
- Each: `--gpu-memory-utilization 0.35` (app memory cap so two fit on one card)
- Confirm both pods Ready on the **same** A100 node when packing is the goal

**Pass criteria:** two (or four) small vLLM pods Running; chat completions succeed; optional: both on one node.

**Do not** substitute Llama-70B into these manifests for Track A.

---

## Track B — How to run one 70B on 2× A100 80GB (dedicated)

### B1. Pool must be exclusive

- **No** time slicing on the nodes used for 70B (`sharing-strategy=none`, `replicas=1`)
- One Ray/vLLM process owns **both** GPUs via tensor parallel

### B2. Serving shape

```text
vllm serve <70B-model> \
  --tensor-parallel-size 2 \
  --dtype bfloat16 \
  --gpu-memory-utilization 0.90   # often need high; still KV-limited
  --max-model-len <conservative>  # keep short until stable
```

Pod/Job must request **`nvidia.com/gpu: "2"`** (or two GPU devices visible to one multi-GPU container), not four half-GPU pods.

### B3. Expectations (accurate)

- **Minimum** hardware for BF16 70B weights on A100-80GB class: **2 GPUs**
- Concurrent users / long context will be **limited** vs TP=4
- Quantization (AWQ/GPTQ/FP8 where supported) improves headroom — treat as a separate config choice
- This track **proves 70B hosting**, not GPU packing

**Pass criteria:** `/v1/models` + a short completion succeed; `nvidia-smi` shows both GPUs in use by the same server; no second large model scheduled on those GPUs.

---

## What “50%” means (correct language)

| Phrase | Correct meaning |
|---|---|
| Time slicing `replicas: 2` | Up to **2 pods** can be **scheduled** per physical GPU |
| `--gpu-memory-utilization 0.35` | That **process** aims to use ~35% of **visible** GPU memory |
| “50% of an A100 for 70B” | **Not** a supported way to run 70B; weights alone need most of a multi-GPU footprint |

---

## Optional: A100 MIG (isolation, not 70B packing)

A100 supports MIG (hardware memory/compute partitions). Example 80GB profiles include `1g.10gb`, `2g.20gb`, `3g.40gb`, `7g.80gb`.

- Good for **multiple medium/small** models with isolation
- **Not** a path to multiple 70B instances on 2 cards
- MIG instance ≈ dedicated mini-GPU; NCCL/TP across MIG instances is constrained — **70B TP still wants full GPUs**
- Reconfiguring MIG typically requires GPU reset / node disruption

Use MIG as a **third** conversation (QoS isolation), not as “50% 70B.”

---

## Recommended start-PoC order

1. **Track A** on the 2× A100 pool with small models (fast proof of RHOAI Ch 8 time slicing)  
2. **Track B** on a **dedicated** interpretation of those same 2 GPUs (or a second node pool) for one 70B TP=2  
3. Do **not** claim Track A proves 70B density; do **not** claim Track B proves sharing  

## References

- RHOAI 3.5 Enable GPU time slicing: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_accelerators/about-gpu-time-slicing_accelerators  
- NVIDIA GPU Operator time slicing: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html  
- NVIDIA MIG user guide (A100 profiles): https://docs.nvidia.com/datacenter/tesla/mig-user-guide/  
