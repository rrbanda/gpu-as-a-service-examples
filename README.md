# GPU as a Service — Examples

Reference implementations for GPU-as-a-Service patterns on Red Hat OpenShift AI.

Each directory contains a self-contained use case with YAML manifests, a setup script, and a step-by-step guide.

## Use Cases

| Use Case | Description | Platform |
|----------|-------------|----------|
| [Heterogeneous GPU Tiered Inference](heterogeneous-gpu-tiered-inference/) | Pin models to GPU tiers (A100/H100/H200) in a mixed-GPU cluster using Kueue ResourceFlavors, Hardware Profiles, vLLM tensor parallelism, and llm-d intelligent routing | RHOAI 3.4, RHBoK, vLLM, llm-d |

## How to Use

Each use case directory follows a consistent structure:

```
<use-case>/
  README.md       # Overview, prerequisites, quick start
  GUIDE.md        # Full step-by-step implementation guide
  setup.sh        # One-command setup (after prerequisites)
  manifests/      # All Kubernetes/OpenShift YAML manifests
```

1. Pick a use case directory
2. Read the `README.md` for prerequisites
3. Customize the manifests for your cluster (GPU labels, namespaces, quotas)
4. Run `./setup.sh` or follow `GUIDE.md` step by step

## License

Apache-2.0
