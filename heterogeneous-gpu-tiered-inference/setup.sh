#!/usr/bin/env bash
#
# Heterogeneous GPU Tiered Inference — Quick Setup
#
# Applies all Kueue, RHOAI, and model-serving manifests in the correct order.
# Run this after completing the prerequisites in GUIDE.md (Step 0).
#
# Usage:
#   ./setup.sh                 # Apply everything (Kueue + RHOAI + vLLM models)
#   ./setup.sh --with-llm-d    # Apply Kueue + RHOAI + llm-d models instead of vLLM
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"

echo "=== Step 0: Activate Kueue in RHOAI ==="
oc patch datasciencecluster default-dsc \
  --type='merge' \
  -p '{"spec":{"components":{"kueue":{"managementState":"Unmanaged"}}}}' \
  -n redhat-ods-operator

oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type merge \
  -p '{"spec":{"dashboardConfig":{"disableKueue":false}}}'

echo "=== Step 1: ResourceFlavors ==="
oc apply -f "$MANIFESTS/kueue/resource-flavors.yaml"

echo "=== Step 2: ClusterQueues (strict tier pinning) ==="
oc apply -f "$MANIFESTS/kueue/cluster-queues-strict.yaml"

echo "=== Step 3: Label namespaces and create LocalQueues ==="
oc create namespace team-a --dry-run=client -o yaml | oc apply -f -
oc create namespace team-b --dry-run=client -o yaml | oc apply -f -
oc label namespace team-a kueue.openshift.io/managed=true --overwrite
oc label namespace team-b kueue.openshift.io/managed=true --overwrite
oc apply -f "$MANIFESTS/kueue/local-queues.yaml"

echo "=== Step 4: Hardware Profiles ==="
oc apply -f "$MANIFESTS/rhoai/hardware-profiles.yaml"

if [[ "${1:-}" == "--with-llm-d" ]]; then
  echo "=== Step 7: Deploy models with llm-d ==="
  oc apply -f "$MANIFESTS/llm-d/llmisvc-8b-a100.yaml"
  oc apply -f "$MANIFESTS/llm-d/llmisvc-70b-h100-tp.yaml"
else
  echo "=== Steps 5-6: Deploy models with vLLM ==="
  oc apply -f "$MANIFESTS/vllm/inferenceservice-8b-a100.yaml"
  oc apply -f "$MANIFESTS/vllm/inferenceservice-70b-h100-tp.yaml"
fi

echo ""
echo "=== Verification ==="
echo "ResourceFlavors:"
oc get resourceflavors
echo ""
echo "ClusterQueues:"
oc get clusterqueues
echo ""
echo "LocalQueues:"
oc get localqueues -A
echo ""
echo "Done. See GUIDE.md Step 8 for full verification commands."
