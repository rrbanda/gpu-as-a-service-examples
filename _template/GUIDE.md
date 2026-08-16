# <Use Case Name> — Implementation Guide

> **Scenario:** Describe the real-world scenario this guide walks through.

> **Platform:** Red Hat OpenShift AI 3.4 · *(list key components)*

---

## Architecture Overview

*(Include Mermaid diagrams showing cluster layout, data flow, and component hierarchy.)*

---

## Step 0 — Prerequisites

Before starting, confirm all platform components are in place.

### Operators Required

| Operator | Namespace | Purpose |
|----------|-----------|---------|
| Red Hat OpenShift AI 3.4+ | `redhat-ods-operator` | Core AI platform |
| *(add others)* | | |

### Verify Cluster State

```bash
# Add verification commands here
```

---

## Step 1 — *(First Setup Step)*

*(Describe what this step does and why.)*

```yaml
# Include the manifest inline
```

Apply:

```bash
oc apply -f manifests/<component>/<manifest>.yaml
```

Verify:

```bash
# Verification command
```

---

## Apply Everything at Once

To apply all resources (shared base + this use case) in one command:

```bash
oc apply -k manifests/base/
```

To preview first:

```bash
oc apply -k manifests/base/ --dry-run=server
```

---

## Step N — Verify End-to-End

### Component Verification

```bash
# Verification commands
```

### Endpoint Verification

```bash
# Test commands
```

---

## Known Gaps and Caveats

### *(Gap Name)*

**Status:** *(GA / Developer Preview / Tech Preview / Not available)*

**Impact:** *(What this means for users.)*

**Mitigation:** *(Workaround if any.)*

---

## Quick Reference: Component Responsibilities

| Component | Question It Answers | Scope |
|-----------|---------------------|-------|
| **Component** | What does it decide? | Cluster / Namespace / Workload |

---

## Summary

| Requirement | Status | Mechanism |
|-------------|--------|-----------|
| *Requirement* | **Supported (GA)** | How |
