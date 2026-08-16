# Contributing a New Use Case

## Workflow

1. **Copy the template:**

```bash
cp -r _template/ my-use-case-name/
cd my-use-case-name/
```

2. **Add your manifests** under `manifests/`, organized by component (e.g., `manifests/kueue/`, `manifests/serving/`).

3. **Update `kustomization.yaml`** to list your manifests. Include `../common` as a resource if your use case needs the shared ResourceFlavors:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../common
  - manifests/my-component/my-resource.yaml
```

4. **Add overlays** under `overlays/` if the use case has deployment variants (e.g., different model servers, different GPU configurations).

5. **Fill in `README.md`** — follow the template sections. Include: What This Solves table, architecture diagram, prerequisites, quick start with `oc apply -k`, file structure, customization table, and references.

6. **Fill in `GUIDE.md`** — step-by-step walkthrough with inline YAML, `oc apply` commands, verification commands, and known gaps.

7. **Add a row** to the Use Cases table in the root `README.md`.

8. **Test on a cluster** before submitting.

## Naming Conventions

- **Directories:** lowercase kebab-case (e.g., `multi-tenant-gpu-sharing`, `batch-training-scheduler`)
- **Manifest files:** descriptive kebab-case matching the resource (e.g., `clusterqueue-batch.yaml`, `inferenceservice-llama-70b.yaml`)
- **Kustomize overlays:** named after the variant they represent (e.g., `overlays/vllm/`, `overlays/llm-d/`, `overlays/single-node/`)

## Submission Checklist

Before opening a pull request, verify:

- [ ] Directory follows the standard layout (`README.md`, `GUIDE.md`, `kustomization.yaml`, `manifests/`)
- [ ] `kustomization.yaml` is valid — `oc kustomize .` produces the expected output
- [ ] If overlays exist, each one builds cleanly — `oc kustomize overlays/<variant>/`
- [ ] `README.md` has all sections: What This Solves, Architecture, Prerequisites, Quick Start, File Structure, Customization, References
- [ ] `GUIDE.md` walks through every manifest with inline YAML, apply commands, and verification
- [ ] Known gaps and caveats are documented
- [ ] Root `README.md` Use Cases table has been updated with a new row
- [ ] Tested on a real OpenShift cluster with the stated prerequisites
- [ ] No hardcoded secrets, tokens, or cluster-specific values in committed manifests
