# Shared Resources

Cluster-scoped Kubernetes resources that are reused across multiple use cases. This directory is a Kustomize base — use cases include it via `resources: [../common]` in their `kustomization.yaml`.

## Contents

| Path | Resource | Description |
|------|----------|-------------|
| `kueue/resource-flavors.yaml` | `ResourceFlavor` | GPU tier definitions (A100, H100, H200) mapped to NFD node labels |

## Customization

Update `nvidia.com/gpu.product` values in `kueue/resource-flavors.yaml` to match the actual NFD labels on your cluster:

```bash
oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.product}'
```

## How Use Cases Reference These

Each use case's `kustomization.yaml` includes the shared base:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../common
  - manifests/kueue/cluster-queues-strict.yaml
  # ... use-case-specific manifests
```

Apply with:

```bash
oc apply -k <use-case-directory>/
```

Since these are cluster-scoped resources, applying them multiple times is safe — `oc apply` is idempotent.
