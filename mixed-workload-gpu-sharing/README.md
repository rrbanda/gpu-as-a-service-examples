# PoC: GPU Sharing and Inference Optimization with Kueue and llm-d

## Use Case Summary

On a shared multi-tenant GPU cluster, multiple teams run a mix of long-running inference services and batch training or fine-tuning jobs on the same pool of GPUs. The same model servers may also handle both interactive and batch inference requests. The platform must ensure that:

- Inference services receive GPUs with priority over batch training and fine-tuning
- Idle GPU capacity is never stranded — it is automatically utilized by batch workloads
- When a team needs their GPUs back, capacity is reclaimed without manual intervention
- Inference requests are routed to the optimal replica based on queue depth and cache state, avoiding terminating pods and maximizing KV cache and prefix cache reuse
- Interactive inference latency is protected when batch inference shares the same model servers
- No manual intervention is required for GPU allocation, request routing, or request prioritization


## Business Problem

GPU infrastructure is expensive. In a multi-team environment, three forms of waste occur:

1. **Contention waste:** A batch training job holds GPUs that an inference service needs. The inference service sits Pending until training finishes — which could be hours. Someone must manually identify and stop the training job.

2. **Idle waste:** A team's allocated GPUs sit unused while another team is GPU-starved. There is no mechanism to temporarily share idle capacity and reclaim it when needed.

3. **Routing waste:** When GPUs are reallocated (preemption, rolling updates, scaling), Kubernetes routes requests randomly — including to pods that are terminating or not yet ready. This causes failed requests during transitions. Even during steady state, random routing ignores GPU-side state: a pod that already has the prompt cached in its KV cache can serve the request significantly faster than one that must recompute the prefill from scratch.

4. **Consolidation waste:** Interactive and batch inference workloads are deployed on separate GPU pools because there is no mechanism to prioritize interactive requests over batch. This doubles infrastructure cost while leaving each pool underutilized.

Kueue addresses problems 1 and 2 through priority-based preemption and elastic quota sharing. llm-d's Endpoint Picker addresses problem 3 through inference-aware routing (queue-depth scoring, prefix-cache affinity). llm-d's Flow Control addresses problem 4 through priority-based request queuing and saturation detection. All three operate on platform policy with zero manual intervention.


## Environment

- OpenShift Container Platform 4.20+
- Red Hat OpenShift AI 3.5
- Red Hat Build of Kueue (RHBoK) 1.4.1
- GPU pool: minimum 4 GPUs (e.g., 2× A100-80GB nodes, 2 GPUs each)
- Two tenants: Team A (ML Engineering — inference) and Team B (Data Science — training)


## Kueue Configuration

### Priority Classes

Two WorkloadPriorityClasses establish the preemption hierarchy:

```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: WorkloadPriorityClass
metadata:
  name: serving-critical
value: 1000
description: "Long-running inference serving — highest priority"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: WorkloadPriorityClass
metadata:
  name: batch-normal
value: 100
description: "Batch training — preemptible by serving workloads"
```

### Cohort and ClusterQueues

Both teams share a cohort. Each team receives 2 GPU nominal quota. Elastic borrowing is enabled. Reclaim targets only lower-priority workloads.

```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-a-queue
spec:
  cohortName: gpu-fleet
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: LowerPriority
  resourceGroups:
  - coveredResources: ["nvidia.com/gpu"]
    flavors:
    - name: gpu-a100
      resources:
      - name: "nvidia.com/gpu"
        nominalQuota: 2
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: team-b-queue
spec:
  cohortName: gpu-fleet
  preemption:
    withinClusterQueue: LowerPriority
    reclaimWithinCohort: LowerPriority
  resourceGroups:
  - coveredResources: ["nvidia.com/gpu"]
    flavors:
    - name: gpu-a100
      resources:
      - name: "nvidia.com/gpu"
        nominalQuota: 2
```

### Serving Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-serving
  labels:
    kueue.x-k8s.io/queue-name: team-a-lq
    kueue.x-k8s.io/priority-class: serving-critical
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: vllm-serving
        kueue.x-k8s.io/queue-name: team-a-lq
        kueue.x-k8s.io/priority-class: serving-critical
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        command: ["sh", "-c"]
        args:
        - exec vllm serve meta-llama/Llama-3.1-8B-Instruct --shutdown-timeout 45
        resources:
          requests:
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sleep", "15"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vllm-serving-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: vllm-serving
```

### Batch Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: training-job
  labels:
    kueue.x-k8s.io/queue-name: team-b-lq
    kueue.x-k8s.io/priority-class: batch-normal
spec:
  suspend: true
  template:
    metadata:
      labels:
        kueue.x-k8s.io/queue-name: team-b-lq
        kueue.x-k8s.io/priority-class: batch-normal
    spec:
      restartPolicy: Never
      containers:
      - name: training
        image: nvcr.io/nvidia/pytorch:24.05-py3
        command: ["python3", "-c"]
        args:
        - |
          import torch, time
          device = torch.device('cuda')
          print(f'Training on {torch.cuda.get_device_name(0)}')
          t = torch.randn(4096, 4096, device=device)
          for step in range(100000):
              t = t @ t.T
              if step % 1000 == 0:
                  print(f'Step {step}')
          print('Training complete')
        resources:
          requests:
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
```


## PoC Scenarios and Acceptance Criteria

### Scenario 1: Baseline — Both Teams Admitted from Their Own Quota

**Setup:** No workloads running. 4 GPUs available.

**Steps:**
1. Team A deploys the inference service (1 replica, 1 GPU)
2. Team B submits a training job (1 GPU)

**Acceptance Criteria:**
- [ ] Team A's inference pod transitions from SchedulingGated to Running
- [ ] Team B's training pod transitions from SchedulingGated to Running
- [ ] `oc get workloads -A` shows both workloads in Admitted state
- [ ] 2 of 4 GPUs consumed. 2 GPUs idle.

**What this validates:** Kueue admission gating works for both Deployments (plain-pod integration) and Jobs. Each team consumes quota from their own ClusterQueue.


### Scenario 2: Elastic Borrowing — Idle GPUs Utilized Automatically

**Prerequisite:** Scenario 1 complete. Team A using 1 GPU, Team B using 1 GPU. 2 GPUs idle (1 from each team's quota).

**Steps:**
1. Team B submits a second training job (1 GPU)

**Acceptance Criteria:**
- [ ] Team B's second training job is admitted using borrowed capacity from Team A's idle quota
- [ ] `oc describe clusterqueue team-b-queue` shows usage exceeding nominalQuota (borrowing active)
- [ ] 3 of 4 GPUs in use. Team A's idle GPU is productively utilized by Team B.

**What this validates:** Elastic quota sharing within a cohort. Idle GPUs from one team are automatically available to other teams' workloads. No manual reassignment required.


### Scenario 3: Priority Preemption — Inference Reclaims GPUs from Training

**Prerequisite:** Scenario 2 complete. Team A using 1 GPU (inference), Team B using 2 GPUs (training — 1 from own quota, 1 borrowed). 3 GPUs in use.

**Steps:**
1. Team A scales the inference Deployment to 2 replicas: `oc scale deployment/vllm-serving --replicas=2`

**Acceptance Criteria:**
- [ ] Team B's training job on borrowed quota is preempted (pod terminated)
- [ ] Team A's second inference pod transitions from SchedulingGated to Running
- [ ] Time from scale command to second inference pod Ready: record this value
- [ ] `oc get events` shows a Kueue preemption event for Team B's training workload
- [ ] Team A's first inference pod remained Running throughout (unaffected)

**What this validates:** Priority-based preemption. Serving workloads (priority 1000) receive GPUs by preempting lower-priority batch workloads (priority 100) on borrowed quota. No manual intervention. The existing inference replica is unaffected.


### Scenario 4: Live Traffic During Preemption — Inference Availability

**Prerequisite:** Scenario 3 complete. Team A running 2 inference replicas.

**Steps:**
1. Start a continuous inference request loop against the vLLM endpoint (e.g., curl in a loop or a load generator)
2. Observe that requests are balanced across both replicas
3. Simulate preemption of 1 replica: submit a higher-priority workload on Team A's queue, or scale down to 1 and back to 2

**Acceptance Criteria:**
- [ ] During the transition (1 replica terminating, replacement loading), inference requests continue succeeding on the surviving replica
- [ ] No 503 errors observed during the preemption window (with 2 replicas)
- [ ] After the replacement pod is Ready, traffic is served by both replicas again

**What this validates:** Inference availability during GPU reallocation. With 2+ replicas, the graceful drain pattern (preStop + shutdown-timeout) ensures serving traffic is maintained throughout.


### Scenario 5: Automatic Batch Re-admission — Training Resumes

**Prerequisite:** Scenario 3 complete. Team B's training job was preempted and is in SchedulingGated state.

**Steps:**
1. Team A scales inference back to 1 replica: `oc scale deployment/vllm-serving --replicas=1`

**Acceptance Criteria:**
- [ ] 1 GPU freed by Team A's scale-down
- [ ] Team B's pending training job is automatically admitted by Kueue (SchedulingGated → Running)
- [ ] Time from scale-down to training pod Running: record this value (expected <60s)
- [ ] No manual resubmission of the training job required

**What this validates:** Automatic workload re-admission. When GPU capacity becomes available, pending workloads are admitted from the queue in priority order. Teams do not need to monitor and resubmit.


### Scenario 6: Maximum Fleet Utilization — Every GPU Productive

**Prerequisite:** Scenario 5 complete. Team A running 1 inference replica (1 GPU on own quota), Team B running 1 training job (1 GPU on own quota). 2 GPUs idle (Team A has 1 idle nominal, Team B has 1 idle nominal).

**Steps:**
1. Team B submits 3 additional training jobs

**Acceptance Criteria:**
- [ ] 2 of the 3 new training jobs are admitted: 1 from Team B's own idle quota, 1 borrowed from Team A's idle quota
- [ ] Fourth training job (3rd new submission) remains SchedulingGated (no quota available)
- [ ] All 4 GPUs are in use: 1 inference (Team A own) + 2 training (Team B own quota) + 1 training (Team B borrowed from Team A)
- [ ] GPU utilization is 100% across the fleet

**What this validates:** Maximum utilization. Every GPU in the fleet is productive. Idle capacity from any team is automatically used by batch workloads. The fleet operates at full capacity without over-provisioning.


### Scenario 7: Quota Reclaim — Team Gets Guaranteed GPUs Back

**Prerequisite:** Scenario 6 complete. All 4 GPUs in use. Team A: 1 GPU (inference, own quota). Team B: 3 GPUs (2 training on own quota + 1 training borrowed from Team A).

**Steps:**
1. Team A scales inference to 2 replicas: `oc scale deployment/vllm-serving --replicas=2`

**Acceptance Criteria:**
- [ ] Kueue preempts Team B's training job on borrowed quota (the 1 job using Team A's lent capacity)
- [ ] Team A's second inference replica is admitted and starts on the reclaimed GPU
- [ ] Time from scale command to preemption to inference Ready: record this value
- [ ] Team B's 2 training jobs on their own nominal quota continue running (unaffected)
- [ ] Final state: Team A using 2 GPUs (own quota), Team B using 2 GPUs (own quota), no borrowing

**What this validates:** Targeted reclaim. Kueue preempts only the borrowed workload needed to satisfy the reclaim request. Workloads on nominal quota are unaffected. Each team ends up using exactly their guaranteed allocation.


### Scenario 8: Rolling Update — Model Upgrade Under Kueue Management

**Prerequisite:** Team A running 1 inference replica, using 1 GPU.

**Steps:**
1. Trigger a rolling update: `oc rollout restart deployment/vllm-serving`

**Acceptance Criteria:**
- [ ] With maxSurge: 0, maxUnavailable: 1: old pod terminates, new pod is admitted from freed quota
- [ ] Rollout completes successfully: `oc rollout status deployment/vllm-serving` shows complete
- [ ] Time from rollout start to new pod Ready: record this value
- [ ] No SchedulingGated deadlock occurs

**What this validates:** Kueue-managed rolling updates for serving Deployments. The recommended strategy (maxSurge: 0, maxUnavailable: 1) completes without deadlock on a GPU-constrained cluster.


## Success Criteria Summary

| # | Scenario | Key Metric |
|---|----------|------------|
| 1 | Both teams admitted | Both workloads in Admitted state |
| 2 | Elastic borrowing | Team B borrows Team A's idle GPU |
| 3 | Priority preemption | Inference pod Ready after preempting batch — record time |
| 4 | Live traffic continuity | Zero 503 errors during preemption with 2 replicas |
| 5 | Automatic re-admission | Training resumes in <60s after GPU freed |
| 6 | Maximum utilization | 4/4 GPUs in use across both teams |
| 7 | Targeted reclaim | Borrowed batch preempted, 2 nominal workloads unaffected — record time |
| 8 | Rolling update | Completes with no deadlock — record time |


## Measurements to Collect

For each scenario that involves a state transition, record:

- **T0:** Command issued (scale, submit, rollout)
- **T1:** Preemption event timestamp (if applicable)
- **T2:** New pod SchedulingGate removed (admitted)
- **T3:** New pod container started
- **T4:** New pod Ready (model loaded, readiness probe passing)
- **T5:** First successful inference request on new pod

Key derived metrics:
- **Preemption-to-Ready:** T4 - T1 (how long a preempted GPU is unavailable before the replacement is serving)
- **Reclaim latency:** T2 - T0 (how quickly Kueue makes the preemption decision and admits the replacement)
- **Model load time:** T4 - T3 (how long the model takes to load — independent of Kueue)


---

## Phase 2: Inference-Aware Routing with llm-d

Phase 1 validates GPU admission, quota, and preemption using Kueue alone. Phase 2 deploys the model using LLMInferenceService (which creates the llm-d inference gateway, EPP, and InferencePool automatically) and re-runs Scenario 4 to validate improved inference availability during GPU reallocation.

### Why llm-d

Kueue decides **which pods get GPUs**. llm-d decides **which pod gets each request**. They operate at different layers and are complementary.

| Concern | Without llm-d | With llm-d (EPP) |
|---------|--------------|-------------------|
| **Request routing during pod termination** | Random (probabilistic) via kube-proxy iptables rules; requests can hit a terminating pod until EndpointSlice propagation completes | EPP watches pod readiness directly (shorter propagation path than the EndpointSlice → kube-proxy chain) and deprioritizes endpoints by queue-depth scoring, reducing the window during which requests reach a draining pod |
| **Requests arriving when no replica is Ready** | 503 — nothing to queue them | With Flow Control enabled, EPP buffers requests in-memory up to a configurable TTL (default 60s). If queue fills or TTL expires before a replica is Ready, the request is rejected with 503. Queues are in-memory only and lost on EPP restart |
| **Multi-replica load balancing** | Random (probabilistic) | KV cache affinity + queue depth aware — composite scoring routes to the replica most likely to serve fast |
| **Prefix-cache-aware routing** | None | Prefix-cache scoring routes requests with similar prompt prefixes to the same replica, converting redundant prefill into cache lookups and reducing time-to-first-token. This is the default behavior in RHOAI 3.5 (included in the 4-scorer default configuration). |


### llm-d Setup via LLMInferenceService

In RHOAI 3.5, LLMInferenceService creates the InferencePool, HTTPRoute, and EPP automatically. Leave `route`, `gateway`, and `scheduler` as empty `{}` to use auto-created defaults, or provide explicit configuration as needed.

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: vllm-serving
  namespace: team-a
spec:
  replicas: 2
  model:
    uri: hf://meta-llama/Llama-3.1-8B-Instruct
    name: meta-llama/Llama-3.1-8B-Instruct
  router:
    route: {}
    gateway: {}
    scheduler: {}
    template:
      containers:
      - name: main
        resources:
          limits:
            cpu: "4"
            memory: 32Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: "2"
            memory: 16Gi
            nvidia.com/gpu: "1"
```

With `scheduler: {}`, RHOAI 3.5 applies the default 4-scorer configuration automatically:
- `queue-scorer` (weight 2) — distributes load by queue depth
- `kv-cache-utilization-scorer` (weight 2) — routes to replicas with available KV cache capacity
- `prefix-cache-scorer` (weight 3) — routes similar prompts to the same replica for cache reuse
- `no-hit-lru-scorer` (weight 2) — LRU tiebreaker when no cache hit is found

Flow Control is not enabled in this configuration — that is added in Phase 3.


### Scenario 9: Inference Continuity During Preemption — With llm-d

**Prerequisite:** Phase 1 Scenario 3 complete (Kueue quota and preemption validated). Team A's model deployed via LLMInferenceService with 2 replicas behind the llm-d gateway. Continuous load generator running against the gateway endpoint.

**Steps:**
1. Team A scales inference from 2 to 1 replica (simulating Kueue preemption of one replica)
2. Immediately scale back to 2 replicas
3. Monitor request success rate throughout

**Acceptance Criteria:**
- [ ] EPP detects the terminating pod and stops routing new requests to it (verify via EPP logs or `llm_d_epp_request_running` metric dropping for that endpoint)
- [ ] In-flight requests on the terminating pod complete successfully (vLLM `--shutdown-timeout` allows drain)
- [ ] All new requests are routed to the surviving replica — zero 503 errors during the transition
- [ ] After the replacement pod is Ready, EPP routes requests to both replicas again (verify via metrics or logs)
- [ ] Compare error rate to Phase 1 Scenario 4 (without llm-d): record any difference

**What this validates:** llm-d's inference-aware routing reduces or eliminates request failures during GPU reallocation compared to basic kube-proxy Service routing.


### Scenario 10: Request Buffering During Single-Replica Rolling Update

**Prerequisite:** Flow Control feature gate enabled on EPP (add `featureGates: ["flowControl"]` to the inline EndpointPickerConfig). Team A running 1 inference replica behind llm-d gateway. Continuous load generator running.

**Steps:**
1. Trigger a rolling update on the underlying model server pods
2. With maxSurge: 0, maxUnavailable: 1 — the single replica terminates before the replacement is Ready
3. During the gap (old pod Terminating, new pod loading model), observe request behavior

**Acceptance Criteria:**
- [ ] EPP Flow Control buffers requests while zero replicas are Ready (verify via `llm_d_epp_flow_control_queue_size` metric > 0)
- [ ] Requests that arrive during the gap are held, not rejected — provided the model loads within the TTL (default 60s)
- [ ] After the replacement pod is Ready, queued requests are dispatched and complete successfully
- [ ] If model load exceeds TTL: requests in queue are rejected with 503 (`rejected-ttl-expired`) — record how many
- [ ] Record the maximum queue depth observed during the gap

**What this validates:** EPP Flow Control acts as a buffer during the zero-replica window. This is the key capability that kube-proxy cannot provide. Model load time is the limiting factor — if the model takes longer than the queue TTL, requests will still be rejected.


### Phase 2 Success Criteria

| # | Scenario | Key Metric |
|---|----------|------------|
| 9 | Inference continuity with llm-d (2 replicas) | Zero 503 errors vs. Phase 1 Scenario 4 error count |
| 10 | Request buffering with Flow Control (1 replica, rolling update) | Requests buffered and served after model load; record max queue depth and any TTL rejections |


### Phase 2 Design Considerations

- **Flow Control requires explicit enablement.** Add `featureGates: ["flowControl"]` in the inline EndpointPickerConfig. Without it, Scenario 10 has no queuing — requests get 503 immediately when no endpoints exist.
- **Queue TTL vs. model load time.** The default TTL is 60s. For Llama-3.1-8B on A100, model load is typically 30–45s (within TTL). For larger models (70B+), model load can exceed 60s — increase `defaultRequestTTL` or accept that some requests will be rejected during the gap.
- **In-memory queues.** EPP queues are stored in memory. If the EPP pod restarts during the buffering window, all queued requests are lost.
- **EPP endpoint detection timing.** EPP watches pod readiness via the Kubernetes API (same underlying mechanism as kube-proxy). The propagation path is shorter (direct pod watch vs. EndpointSlice → kube-proxy chain), but the improvement is seconds, not milliseconds. Do not claim sub-second endpoint removal.
- **Fail-open behavior.** If the EPP becomes unavailable, the gateway routes requests directly to model servers without Flow Control protection. Priority ordering, fairness, and saturation gating are not enforced during this window.


---

## Phase 3: Request Prioritization for Mixed Interactive and Batch Inference

Phase 1 solves GPU allocation (who gets the cards). Phase 2 solves routing quality (which pod handles each request). Phase 3 solves a different problem: **when interactive users and batch inference pipelines share the same model servers, how do you protect interactive latency without wasting GPU capacity?**

### The Problem

At scale, organizations run both interactive and batch inference against the same LLM:

| Workload | Example | SLO | Volume |
|----------|---------|-----|--------|
| Interactive | Chat, RAG, code completion | P99 TTFT < 500ms | Bursty, user-driven |
| Batch | Document summarization, embedding generation, offline evaluation, synthetic data | Completed within hours | High volume, sustained |

Without request-level prioritization, a batch pipeline flooding the model server queue degrades interactive latency for all users. The typical workaround — separate GPU pools for batch and interactive — doubles infrastructure cost.

Flow Control in RHOAI 3.5 (GA) solves this by consolidating both workload types on the same GPU pool with priority-based queuing. Interactive requests dispatch first. Batch requests fill idle capacity and are shed first under saturation.


### How Flow Control Works

```
   Interactive ──► ┌─────────────────────────────┐
   (priority 100)  │  EPP Flow Control            │
                   │  ┌─────────┐  ┌───────────┐  │     ┌────────────┐
                   │  │ P=100   │──│ Saturation│──│────►│ vLLM Pool  │
                   │  │ queue   │  │ Detector  │  │     │ (shared)   │
                   │  ├─────────┤  │           │  │     └────────────┘
   Batch ─────────►│  │ P=-1   │──│           │  │
   (priority -1)   │  │ queue   │  └───────────┘  │
                   │  └─────────┘                  │
                   └─────────────────────────────┘
```

1. Gateway injects `x-gateway-inference-objective` and `x-gateway-fairness-id` headers based on client authentication (ServiceAccount namespace)
2. EPP resolves the objective header to an InferenceObjective resource, determining the request's priority. The fairness ID identifies the tenant queue within that priority band. Together they form the **flow key** — each unique flow key gets its own queue inside the appropriate band. Requests with no matching InferenceObjective default to priority 0.
3. Requests enter priority-specific queues based on the flow key
4. The saturation detector monitors `vllm:num_requests_waiting` and `vllm:kv_cache_usage_perc`. When pool saturation reaches a band's configured dispatch ceiling, requests in that band and all lower-priority bands remain queued. Higher-priority bands continue to dispatch.
5. Within an eligible band, the fairness policy (round-robin) selects a tenant queue, then the ordering policy (FCFS) selects the next request from it. Only after admission does the scheduler select a backend.
6. Work-conserving: when the pool is below saturation, all requests (including batch) dispatch immediately with zero added latency — priority queuing activates only under pressure


### Flow Control Configuration

Enable Flow Control and configure saturation detection in the LLMInferenceService. This adds the `flowControl` feature gate and saturation detector to the inline scheduler config while retaining the default scoring plugins:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: vllm-serving
  namespace: team-a
spec:
  replicas: 2
  model:
    uri: hf://meta-llama/Llama-3.1-8B-Instruct
    name: meta-llama/Llama-3.1-8B-Instruct
  router:
    route: {}
    gateway: {}
    scheduler:
      config:
        inline:
          apiVersion: llm-d.ai/v1alpha1
          kind: EndpointPickerConfig
          featureGates:
            - "flowControl"
          flowControl:
            defaultRequestTTL: 1m
            saturationDetector:
              pluginRef: utilization-detector
            priorityBands:
            - priority: 100
              orderingPolicyRef: fcfs-ordering-policy
              fairnessPolicyRef: round-robin-fairness-policy
            - priority: 0
              orderingPolicyRef: fcfs-ordering-policy
              fairnessPolicyRef: round-robin-fairness-policy
            - priority: -1
              maxRequests: 1000
              orderingPolicyRef: fcfs-ordering-policy
              fairnessPolicyRef: global-strict-fairness-policy
          plugins:
            - name: utilization-detector
              type: utilization-detector
              parameters:
                queueDepthThreshold: 5
                kvCacheUtilThreshold: 0.8
                metricsStalenessThreshold: 200ms
            - type: queue-scorer
            - type: kv-cache-utilization-scorer
            - type: prefix-cache-scorer
            - type: no-hit-lru-scorer
          schedulingProfiles:
          - name: default
            plugins:
            - pluginRef: queue-scorer
              weight: 2
            - pluginRef: kv-cache-utilization-scorer
              weight: 2
            - pluginRef: prefix-cache-scorer
              weight: 3
            - pluginRef: no-hit-lru-scorer
              weight: 2
    template:
      containers:
      - name: main
        resources:
          limits:
            cpu: "4"
            memory: 32Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: "2"
            memory: 16Gi
            nvidia.com/gpu: "1"
```

### InferenceObjective Resources

Create InferenceObjective resources to map client identity to priority tiers. The Gateway AuthPolicy automatically sets the `x-gateway-inference-objective` header based on authentication:

- **ServiceAccount tokens:** Header is set to the **ServiceAccount's namespace**
- **User tokens:** Header is set to `authenticated`
- **Anonymous requests:** Header is set to `unauthenticated`

InferenceObjective names must match these header values. Since ServiceAccount tokens map to their namespace, create InferenceObjective resources named after the namespaces where the client ServiceAccounts live.

In this example:
- Interactive clients use a ServiceAccount in namespace `app-interactive`
- Batch pipeline uses a ServiceAccount in namespace `batch-pipeline`

```yaml
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata:
  name: app-interactive        # matches the namespace of the interactive ServiceAccount
  namespace: team-a            # namespace where the InferencePool is deployed
spec:
  priority: 100
  poolRef:
    group: llm-d.ai
    kind: InferencePool
    name: vllm-serving-inference-pool
---
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata:
  name: batch-pipeline         # matches the namespace of the batch ServiceAccount
  namespace: team-a            # namespace where the InferencePool is deployed
spec:
  priority: -1
  poolRef:
    group: llm-d.ai
    kind: InferencePool
    name: vllm-serving-inference-pool
```

To create the corresponding ServiceAccounts and tokens:

```bash
# Interactive client (namespace must match InferenceObjective name)
oc new-project app-interactive
oc create serviceaccount llm-user -n app-interactive
TOKEN_INTERACTIVE=$(oc create token llm-user -n app-interactive --duration=1h)

# Batch client (namespace must match InferenceObjective name)
oc new-project batch-pipeline
oc create serviceaccount batch-user -n batch-pipeline
TOKEN_BATCH=$(oc create token batch-user -n batch-pipeline --duration=1h)
```

### Scenario 11: Baseline — Interactive Latency Without Batch Load

**Setup:** LLMInferenceService deployed with Flow Control enabled. 2 replicas running. No batch traffic.

**Steps:**
1. Send 10 concurrent interactive chat requests via the gateway
2. Record P50, P95, P99 time-to-first-token (TTFT) and time-per-output-token (TPOT)

**Acceptance Criteria:**
- [ ] All requests complete successfully
- [ ] Record baseline P99 TTFT: ____ms
- [ ] Record baseline P99 TPOT: ____ms
- [ ] `llm_d_epp_flow_control_queue_size` remains at 0 (no queuing — pool not saturated)

**What this validates:** Baseline latency numbers. Flow Control adds zero overhead when the pool is not saturated (work-conserving property).


### Scenario 12: Batch Flooding Without Flow Control — Latency Degradation

**Setup:** Disable Flow Control (remove `featureGates: ["flowControl"]`). 2 replicas running.

**Steps:**
1. Start batch pipeline: submit 1000 summarization requests using the `batch-user` ServiceAccount token (from namespace `batch-pipeline`)
2. Simultaneously send 10 concurrent interactive chat requests using the `llm-user` ServiceAccount token (from namespace `app-interactive`)
3. Record interactive P50, P95, P99 TTFT and TPOT

**Acceptance Criteria:**
- [ ] Interactive P99 TTFT degrades significantly compared to Scenario 11 baseline
- [ ] Record degraded P99 TTFT: ____ms (expected: 2-5x baseline)
- [ ] Batch and interactive requests are treated identically — no priority differentiation
- [ ] `vllm:num_requests_waiting` shows high queue depth on model servers

**What this validates:** Without Flow Control, batch traffic directly competes with interactive traffic. This is the problem being solved.


### Scenario 13: Batch + Interactive with Flow Control — Latency Protected

**Setup:** Re-enable Flow Control. Apply InferenceObjective resources (priority 100 for interactive, -1 for batch). 2 replicas running.

**Steps:**
1. Start the same batch pipeline (1000 summarization requests, `batch-user` token from `batch-pipeline` namespace)
2. Simultaneously send 10 concurrent interactive chat requests (`llm-user` token from `app-interactive` namespace)
3. Record interactive P50, P95, P99 TTFT and TPOT

**Acceptance Criteria:**
- [ ] Interactive P99 TTFT is within acceptable range of Scenario 11 baseline (expected: < 1.5x)
- [ ] Record protected P99 TTFT: ____ms
- [ ] Batch requests are dispatched when capacity is available (verify via `llm_d_epp_flow_control_requests_total` with priority=-1 label showing dispatched count > 0)
- [ ] `llm_d_epp_flow_control_queue_size` shows batch requests queuing while interactive dispatches immediately
- [ ] Compare: Scenario 13 interactive TTFT vs. Scenario 12 interactive TTFT — quantify the improvement

**What this validates:** Flow Control protects interactive latency while batch makes progress on idle capacity. Same GPU pool, no separate infrastructure.


### Scenario 14: Saturation Behavior — Load Shedding Under Pressure

**Setup:** Flow Control enabled with priority bands. 2 replicas running.

**Steps:**
1. Increase batch volume until pool saturates: submit 5000 requests in rapid succession
2. Simultaneously send interactive requests
3. Observe Flow Control metrics

**Acceptance Criteria:**
- [ ] `llm_d_epp_flow_control_pool_saturation` reaches 1.0
- [ ] Interactive requests (priority 100) continue dispatching even under saturation
- [ ] Batch requests (priority -1) queue and begin receiving rejection: HTTP 429 (`rejected-saturated`) when band capacity (`maxRequests: 1000`) is exceeded, or HTTP 503 (`rejected-ttl-expired`) after 60s
- [ ] Check `x-llm-d-request-dropped-reason` response header on rejected requests — verify it matches documented values
- [ ] Interactive requests are never rejected unless the pool is completely overwhelmed

**What this validates:** Graceful degradation under extreme load. Batch traffic is shed first. Interactive traffic is protected. The platform does not crash — it rejects excess batch work with documented HTTP status codes and reason headers.


### Scenario 15: Starvation Protection — Batch Gets Served

**Setup:** Flow Control enabled. Configure `priority-holdback-policy` with `minCeiling: 0.3`. 2 replicas running.

**Steps:**
1. Send sustained interactive load for 5 minutes (enough to keep the pool above 30% saturation but below 100%)
2. Simultaneously submit batch requests
3. Monitor batch dispatch rate

**Acceptance Criteria:**
- [ ] Batch requests are dispatched when pool saturation is below the holdback ceiling for priority -1 (0.3 with linear interpolation)
- [ ] `llm_d_epp_flow_control_requests_total{priority="-1", outcome="dispatched"}` is greater than 0
- [ ] Batch is not permanently starved — it makes progress when capacity is available
- [ ] Interactive latency remains within acceptable range

**What this validates:** Starvation protection. Under sustained high-priority load, lower-priority traffic is not permanently blocked. The holdback policy gates batch at lower saturation thresholds, ensuring fair use of idle capacity.


### Phase 3 Success Criteria

| # | Scenario | Key Metric |
|---|----------|------------|
| 11 | Interactive baseline | Record P99 TTFT and TPOT without batch |
| 12 | Batch flooding (no Flow Control) | Interactive P99 TTFT degrades 2-5x |
| 13 | Batch + Interactive (with Flow Control) | Interactive P99 TTFT within 1.5x of baseline |
| 14 | Saturation and load shedding | Batch rejected with 429/503, interactive protected |
| 15 | Starvation protection | Batch dispatched > 0 under sustained interactive load |


### Phase 3 Design Considerations

- **Flow Control is GA in RHOAI 3.5.** Not dev preview, not tech preview. Fully supported.
- **API group is `llm-d.ai`.** InferenceObjective uses `apiVersion: llm-d.ai/v1alpha2`. EndpointPickerConfig uses `apiVersion: llm-d.ai/v1alpha1`. The older `inference.networking.x-k8s.io` group is deprecated.
- **Authentication is required.** Flow Control maps client identity to priority via the `x-gateway-inference-objective` header, which is set by the Gateway AuthPolicy based on ServiceAccount tokens. Enable authentication and authorization for the LLMInferenceService before configuring Flow Control.
- **Default priority is 0.** Requests with no matching InferenceObjective default to priority 0. This is why the EndpointPickerConfig includes a priority 0 band — it catches unauthenticated, anonymous, or unmatched requests.
- **Flow key = objective + fairness ID.** The objective resolves to a priority, the fairness ID identifies the tenant. Together they form the flow key. Each unique flow key gets its own queue inside the appropriate priority band.
- **Admission vs. scheduling.** Flow Control separates two decisions: admission (when a request can advance) and scheduling (where the admitted request runs). Admission holds requests in a central policy queue where priority and fairness apply. Only after admission does the scheduler score backends. This separation is what allows priority ordering and tenant fairness before the request enters a backend-local vLLM queue.
- **Work-conserving.** When the pool is below saturation, all requests (including batch) dispatch immediately with zero added latency. Priority queuing activates only under saturation.
- **Fail-open.** If EPP becomes unavailable, the gateway routes requests directly to model servers without priority ordering, fairness, or saturation gating.
- **Saturation formula.** Pool saturation = average across pods of `Max(num_requests_waiting / queueDepthThreshold, kv_cache_usage_perc / kvCacheUtilThreshold)`. The utilization detector can reflect backend utilization (queue depth + KV cache) or the EPP's in-flight request budget, depending on configuration. Tuning `queueDepthThreshold` (default 5) and `kvCacheUtilThreshold` (default 0.8) controls when queuing activates.
- **Per-replica headroom.** Separate from pool-wide saturation, per-replica headroom controls when an individual replica is filtered from routing. This separates backend eligibility from the admission decision.
- **Batch inference gateway.** RHOAI 3.5 also ships a dedicated batch inference gateway (Chapter 8 of the llm-d docs) with AIMD adaptive concurrency control and system-prompt hash sorting for prefix cache reuse. This is an alternative to raw batch scripts for submitting offline inference work.
- **Metrics prefix.** All flow control metrics use the `llm_d_epp_flow_control_` prefix. Key metrics: `queue_size`, `pool_saturation`, `request_queue_duration_seconds`, `requests_total` (with outcome and priority labels).
- **Flight Recorder.** The Flow Control Flight Recorder replays client traffic, EPP queues, and vLLM pressure on the same timeline. Use it during the PoC to see when admission begins holding requests, where requests wait, and whether queues drain after a surge.


---

## How the Three Phases Fit Together

| Phase | Problem | Solution | What Gets Validated |
|-------|---------|----------|-------------------|
| **Phase 1** (Scenarios 1–8) | Who gets the GPU cards? | Kueue — priority preemption, elastic borrowing, quota reclaim | GPU allocation, fleet utilization, serving protection |
| **Phase 2** (Scenarios 9–10) | Which pod handles each request? | llm-d EPP — queue-depth routing, prefix-cache routing, request buffering | Inference availability during pod transitions |
| **Phase 3** (Scenarios 11–15) | Who gets served first on the same model server? | llm-d Flow Control — priority queuing, saturation detection, load shedding | Interactive latency protection, batch consolidation, infrastructure cost reduction |

Each phase is independently valuable. Phase 1 is the foundation. Phase 2 adds routing quality. Phase 3 adds request-level SLO enforcement for mixed inference workloads.


## Platform References

- Kueue Deployment integration: https://kueue.sigs.k8s.io/docs/tasks/run/deployment/
- Kueue preemption: https://kueue.sigs.k8s.io/docs/concepts/preemption/
- WorkloadPriorityClass: https://kueue.sigs.k8s.io/docs/concepts/workload_priority_class/
- RHOAI 3.5 Kueue management: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-workloads-with-kueue
- RHOAI 3.5 llm-d Flow Control: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/managing-mixed-workloads-with-priority-queuing
- RHOAI 3.5 llm-d Scheduler Configuration: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/configuring-llm-scheduler
- RHOAI 3.5 Batch Inference with llm-d: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/batch-inference-with-llmd_flow-control
- RHOAI 3.5 LLMInferenceService Deployment: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/deploying-models-using-distributed-inference_distributed-inference
- llm-d Flow Control blog (Red Hat Developers, August 2026): https://developers.redhat.com/articles/2026/08/27/llm-d-flow-control-priority-queuing-for-shared-gpu-inference
- KServe graceful drain pattern: https://github.com/kserve/kserve/pull/5496
