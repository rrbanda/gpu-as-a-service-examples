# PoC Use Case: Mixed Batch and Inference GPU Sharing with Kueue

## Use Case Summary

On a shared GPU fleet, multiple teams run a mix of long-running inference services and batch training jobs on the same pool of GPUs. The platform must ensure that:

- Inference services receive GPUs with priority over batch training
- Idle GPU capacity is never stranded — it is automatically utilized by batch workloads
- When a team needs their GPUs back, capacity is reclaimed within seconds
- Inference traffic is unaffected during GPU reallocation
- No manual intervention is required at any point


## Business Problem

GPU infrastructure is expensive. In a multi-team environment, two forms of waste occur:

1. **Contention waste:** A batch training job holds GPUs that an inference service needs. The inference service sits Pending until training finishes — which could be hours. Someone must manually identify and stop the training job.

2. **Idle waste:** A team's allocated GPUs sit unused while another team is GPU-starved. There is no mechanism to temporarily share idle capacity and reclaim it when needed.

Kueue addresses both problems through priority-based preemption and elastic quota sharing, managed entirely by platform policy with zero manual intervention.


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

**Prerequisite:** Scenario 5 complete. Team A running 1 inference replica, Team B running 1 training job.

**Steps:**
1. Team B submits 2 additional training jobs (total: 3 training jobs queued)

**Acceptance Criteria:**
- [ ] 2 training jobs are admitted (1 from Team B quota, 1 borrowed from Team A's idle quota)
- [ ] Third training job remains SchedulingGated (no quota available)
- [ ] All 4 GPUs are in use: 1 inference (Team A) + 1 training (Team B own quota) + 2 training (Team B borrowed)
- [ ] GPU utilization is 100% across the fleet

**What this validates:** Maximum utilization. Every GPU in the fleet is productive. Idle capacity from any team is automatically used by batch workloads. The fleet operates at full capacity without over-provisioning.


### Scenario 7: Quota Reclaim — Team Gets Guaranteed GPUs Back

**Prerequisite:** Scenario 6 complete. All 4 GPUs in use. Team B has borrowed 2 GPUs from Team A and shared pool.

**Steps:**
1. Team A scales inference to 2 replicas: `oc scale deployment/vllm-serving --replicas=2`

**Acceptance Criteria:**
- [ ] Kueue preempts 1 of Team B's training jobs on borrowed quota
- [ ] Team A's second inference replica is admitted and starts
- [ ] Time from scale command to preemption to inference Ready: record this value
- [ ] Team B's training job on its own nominal quota continues running (unaffected)
- [ ] Team B's remaining borrowed training job continues running (only 1 was preempted — the minimum needed)

**What this validates:** Targeted reclaim. Kueue preempts the minimum number of lower-priority borrowed workloads needed to satisfy the reclaim request. Workloads on nominal quota are unaffected.


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
| 7 | Targeted reclaim | Borrowed batch preempted, nominal workloads unaffected — record time |
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

Phase 1 validates GPU admission, quota, and preemption using Kueue alone. Phase 2 adds the llm-d inference gateway in front of the serving Deployment and re-runs Scenario 4 to validate zero-downtime inference during GPU reallocation.

### Why llm-d

Kueue decides **which pods get GPUs**. llm-d decides **which pod gets each request**. They operate at different layers and are complementary.

| Concern | Without llm-d | With llm-d (EPP) |
|---------|--------------|-------------------|
| **Request routing during pod termination** | Random (probabilistic) via kube-proxy iptables rules; requests can hit a terminating pod until EndpointSlice propagation completes | EPP watches pod readiness directly (shorter propagation path than the EndpointSlice → kube-proxy chain) and deprioritizes endpoints by queue-depth scoring, reducing the window during which requests reach a draining pod |
| **Requests arriving when no replica is Ready** | 503 — nothing to queue them | With Flow Control enabled (off by default), EPP buffers requests in-memory up to a configurable TTL (default 60s). If queue fills or TTL expires before a replica is Ready, the request is rejected with 503. Queues are in-memory only and lost on EPP restart |
| **Multi-replica load balancing** | Random (probabilistic) | KV cache affinity + queue depth aware — composite scoring routes to the replica most likely to serve fast |
| **Model-aware routing** | None | LoRA-affinity scoring (routes to pods with the requested adapter loaded) + prefix-cache-aware scheduling (routes to pods with relevant KV cache entries for the prompt, reducing time-to-first-token) |


### llm-d Setup

llm-d requires Gateway API and an InferencePool resource pointing at the serving pods.

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: vllm-pool
spec:
  targetPortNumber: 8000
  selector:
    matchLabels:
      app: vllm-serving
  endpointPickerConfig:
    extensionRef:
      name: llm-d-epp
    failureMode: failOpen
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inference-route
spec:
  parentRefs:
  - name: inference-gateway
  rules:
  - backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: vllm-pool
```

To enable Flow Control (request queuing), set the `flowControl` feature gate in the EPP EndpointPickerConfig. Without it, EPP routes requests but does not queue them when the pool is saturated.


### Scenario 9: Inference Continuity During Preemption — With llm-d

**Prerequisite:** Phase 1 Scenario 3 complete. Team A running 2 inference replicas behind the llm-d gateway. Continuous load generator running against the gateway endpoint.

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

**What this validates:** llm-d's inference-aware routing eliminates request failures during GPU reallocation that would occur with basic kube-proxy Service routing.


### Scenario 10: Request Queuing During Single-Replica Preemption — With llm-d Flow Control

**Prerequisite:** Flow Control feature gate enabled on EPP. Team A running 1 inference replica behind llm-d gateway. Continuous load generator running.

**Steps:**
1. Trigger a rolling update: `oc rollout restart deployment/vllm-serving`
2. With maxSurge: 0, maxUnavailable: 1 — the single replica terminates before the replacement is Ready
3. During the gap (old pod Terminating, new pod loading model), observe request behavior

**Acceptance Criteria:**
- [ ] EPP Flow Control buffers requests while zero replicas are Ready (verify via `llm_d_epp_flow_control_queue_size` metric > 0)
- [ ] Requests that arrive during the gap are held, not rejected — provided the model loads within the TTL (default 60s)
- [ ] After the replacement pod is Ready, queued requests are dispatched and complete successfully
- [ ] If model load exceeds TTL: requests in queue are rejected with 503 — record how many
- [ ] Record the maximum queue depth observed during the gap

**What this validates:** EPP Flow Control acts as a buffer during the zero-replica window that Kueue's rolling update strategy creates. This is the key capability that kube-proxy cannot provide. Note: model load time is the limiting factor — if the model takes longer than the queue TTL, requests will still be rejected.


### Phase 2 Success Criteria

| # | Scenario | Key Metric |
|---|----------|------------|
| 9 | Inference continuity with llm-d (2 replicas) | Zero 503 errors vs. Phase 1 Scenario 4 error count |
| 10 | Request queuing with Flow Control (1 replica, rolling update) | Requests buffered and served after model load; record max queue depth and any TTL rejections |


### Phase 2 Design Considerations

- **Flow Control is off by default.** It must be explicitly enabled via the `flowControl` feature gate in the EPP configuration. Without it, Scenarios 9 and 10 behave like Phase 1 (no queuing).
- **Queue TTL vs. model load time.** The default TTL is 60s. For Llama-3.1-8B on A100, model load is typically 30–45s (within TTL). For larger models (70B+), model load can exceed 60s — increase TTL or accept that some requests will be rejected during the gap.
- **In-memory queues.** EPP queues are stored in memory. If the EPP pod restarts during the queuing window, all buffered requests are lost. Plan EPP availability accordingly.
- **EPP endpoint detection timing.** EPP watches pod readiness via the Kubernetes API (same underlying mechanism as kube-proxy). The propagation path is shorter (direct pod watch vs. EndpointSlice → kube-proxy chain), but the improvement is seconds, not milliseconds. Do not claim sub-second endpoint removal.


## Platform References

- Kueue Deployment integration: https://kueue.sigs.k8s.io/docs/tasks/run/deployment/
- Kueue preemption: https://kueue.sigs.k8s.io/docs/concepts/preemption/
- WorkloadPriorityClass: https://kueue.sigs.k8s.io/docs/concepts/workload_priority_class/
- RHOAI 3.5 Kueue management: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-workloads-with-kueue
- GKE mixed training + inference with Kueue: https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/mixed-workloads
- KServe graceful drain pattern: https://github.com/kserve/kserve/pull/5496
- llm-d Flow Control: https://github.com/llm-d/llm-d/blob/main/docs/architecture/core/router/epp/flow-control.md
- llm-d Graceful Shutdown: https://llm-d.ai/docs/dev/operations/graceful-shutdown
- llm-d Scheduling Architecture: https://github.com/llm-d/llm-d/blob/main/docs/architecture/core/router/epp/scheduling.md
- llm-d EPP Configuration: https://llm-d.ai/docs/architecture/core/router/epp/configuration
