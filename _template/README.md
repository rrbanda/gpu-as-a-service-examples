# <Use Case Name>

One-sentence summary of what this use case demonstrates.

## What This Solves

| Requirement | Status | Mechanism |
|-------------|--------|-----------|
| *Requirement 1* | **Supported (GA)** / **Partially Supported** / **Gap** | How it works |
| *Requirement 2* | ... | ... |

## Architecture

```mermaid
flowchart LR
    A["Component A"] --> B["Component B"]
    B --> C["Component C"]
```

## Prerequisites

- OpenShift Container Platform **4.19.9+**
- Red Hat OpenShift AI **3.4+**
- *(List additional operators or components specific to this use case)*

> See also the [shared prerequisites](../README.md#shared-prerequisites) that apply to all use cases.

## Quick Start

```bash
# Preview what will be applied
oc apply -k manifests/base/ --dry-run=server

# Apply all resources
oc apply -k manifests/base/
```

## File Structure

```
manifests/
  base/
    kustomization.yaml         # Composes ../common + component directories
  overlays/                    # Deployment variants (optional)
    <variant>/
      kustomization.yaml
  <component>/
    kustomization.yaml
    <manifest>.yaml            # Description
GUIDE.md                       # Full step-by-step implementation guide
```

## Customization

| Value | Where | What to Change |
|-------|-------|----------------|
| *value* | `<file>` | Description |

## Full Guide

See **[GUIDE.md](GUIDE.md)** for the complete step-by-step walkthrough with architecture diagrams, design decisions, verification commands, and known gaps.

## References

- [Link to relevant documentation](https://example.com)
