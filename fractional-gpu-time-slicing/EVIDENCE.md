# Validation Evidence — GPU Time Slicing + dual vLLM

**Captured:** 2026-11-05 (re-verified live)  
**Scope:** RHOAI 3.5 Chapter 8 time slicing + two `vllm serve` pods packing onto one A10G  
**Sanitization:** No cluster API URLs, console URLs, passwords, tokens, kubeconfigs, or customer/account names.

## 1. Operator config (RHOAI Ch 8)

ConfigMap profile key and ClusterPolicy device plugin binding:

```text
time-slicing-config keys: a10g
ClusterPolicy devicePlugin.config: {"default":"a10g","name":"time-slicing-config"}
```

Profile body (from live ConfigMap `a10g`):

```yaml
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

## 2. Node labels / capacity (RHOAI verification)

```text
NAME             PLUGINCFG   REPLICAS   STRATEGY       ALLOC
<node-gpu-1>     a10g        2          time-slicing   2
<node-gpu-2>     a10g        2          time-slicing   2
```

Also confirmed live:

- `nvidia.com/device-plugin.config=a10g` (RHOAI Ch 8 verification grep)
- `nvidia.com/gpu.sharing-strategy=time-slicing`
- `nvidia.com/gpu.replicas=2`
- `nvidia.com/gpu.product=NVIDIA-A10G-SHARED`
- `nvidia.com/mig.capable=false`

## 3. Workload packing — same physical GPU

Both servers Ready, each requesting `nvidia.com/gpu: 1`, scheduled on the **same** GPU node:

```text
NAME           READY   STATUS    GPU_LIMIT   SAME_NODE
vllm-qwen-a    1/1     Running   1           yes
vllm-qwen-b    1/1     Running   1           yes
```

Without time slicing (`ALLOC=1`), the second pod could not share that card. With `replicas: 2` / `ALLOC=2`, both run concurrently on one A10G.

## 4. Inference smoke test (both vLLM servers)

Request (identical to both pods):

```bash
curl -sS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":24}'
```

**vllm-qwen-a** response (excerpt):

```json
{
  "object": "chat.completion",
  "model": "Qwen/Qwen2.5-0.5B-Instruct",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "system_fingerprint": "vllm-0.32.0-6a297bbb"
}
```

**vllm-qwen-b** response (excerpt):

```json
{
  "object": "chat.completion",
  "model": "Qwen/Qwen2.5-0.5B-Instruct",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "system_fingerprint": "vllm-0.32.0-6a297bbb"
}
```

## 5. Pass / fail summary

| Check | Result |
|---|---|
| ConfigMap `time-slicing-config` / profile `a10g` | Pass |
| ClusterPolicy `name=time-slicing-config`, `default=a10g` | Pass |
| Node label `nvidia.com/device-plugin.config=a10g` | Pass |
| `sharing-strategy=time-slicing`, `replicas=2`, `ALLOC=2` | Pass |
| Two vLLM pods Ready on same node | Pass |
| Chat completion on server A | Pass |
| Chat completion on server B | Pass |
