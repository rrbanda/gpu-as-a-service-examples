#!/usr/bin/env bash
# RHOAI 3.5 Ch 8 verification expects:
#   oc get nodes --show-labels | grep nvidia.com/device-plugin.config
#
# Labels existing GPU nodes with the same profile key used in
# time-slicing-config (a10g) and ClusterPolicy devicePlugin.config.default.
set -euo pipefail

PROFILE="${PROFILE:-a10g}"

nodes="$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}')"
if [[ -z "${nodes}" ]]; then
  echo "No nodes with label nvidia.com/gpu.present=true found" >&2
  exit 1
fi

for node in ${nodes}; do
  echo "Labeling ${node} with nvidia.com/device-plugin.config=${PROFILE}"
  oc label node "${node}" "nvidia.com/device-plugin.config=${PROFILE}" --overwrite
done

echo
echo "Verification (RHOAI 3.5):"
oc get nodes --show-labels | grep nvidia.com/device-plugin.config || true
