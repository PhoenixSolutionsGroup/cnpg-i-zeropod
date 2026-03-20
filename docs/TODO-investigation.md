# Investigation & TODO Items

## 1. Multi-Replica Support (2 read, 1 write)

**Question**: How does zeropod + CNPG work with `instances: 3` (1 primary + 2 read replicas)?

**Current understanding**:
- Each instance pod gets `runtimeClassName: zeropod` via the lifecycle plugin
- Each pod independently checkpoints/restores based on its own TCP activity
- Replicas stream WAL from the primary via streaming replication

**Concerns to investigate**:
- When a replica is checkpointed, it stops receiving WAL. On restore, it needs to catch up. Does PG handle this gracefully or does the replication slot get dropped?
- If the primary is idle (no client connections), replicas might still have active replication connections TO the primary — does this keep the primary from scaling down?
- Zeropod tracks TCP connections on configured ports. Replication uses the same port (5432). Need to verify if replication connections count toward the activity tracker or not.
- Should replicas even scale to zero? Or should only the primary scale to zero with replicas staying hot?
- Could configure replicas with a different (or no) scaledown annotation

**Test plan**:
- [ ] Deploy `instances: 3` cluster on vx1-g node with local-path storage
- [ ] Verify all 3 pods get zeropod runtime
- [ ] Check if primary scales down while replicas are connected
- [ ] Check if replicas scale down independently
- [ ] Force a scaledown of a replica, then restore — verify replication resumes
- [ ] Measure replication lag after replica restore

---

## 2. HA Failover with Disabled Liveness Probe — RESOLVED

**Question**: We removed the liveness probe to prevent kubelet from killing checkpointed pods. How does CNPG handle failover?

**Answer**: CNPG does NOT use the liveness probe for failover. It uses its own instance manager (PID 1) + readiness probe. We only remove liveness — readiness stays intact. Failover works.

**Bug found & fixed**: The original reconciliation controller disabled `cnpg.io/reconciliationLoop` on the **entire cluster** when any single pod scaled down. This blocked CNPG from performing switchover/failover.

**Fix**: Replaced global reconciliation disable with **per-instance fencing** via `cnpg.io/fencedInstances`. When a pod checkpoints, it's added to the fenced list. CNPG treats fenced instances as `MightBeUnavailable` — the reconciler skips them when waiting for pods to be ready, allowing failover and other operations to proceed normally on non-fenced instances.

**Test results** (3-instance cluster on vx1-g, `scripts/test-failover.sh`):
- [x] Deploy 3-instance cluster — all 3 healthy
- [x] Trigger switchover (targetPrimary) — **failover in 4 seconds**
- [x] Old primary demoted to replica, new primary promoted
- [x] Data integrity preserved across failover
- [x] Writes work on new primary
- [x] Cluster re-stabilizes with 3 healthy instances

**Key insight**: CNPG does NOT auto-delete Running-but-not-Ready pods. It just waits. Fencing tells CNPG to stop waiting for a specific instance, which is exactly what we need for checkpointed pods.

---

## 3. CNPG Point-in-Time Recovery (PITR) & Branching

**Question**: Can we use CNPG's PITR and branching features alongside zeropod?

**Current understanding**:
- CNPG supports PITR via continuous WAL archiving to object storage (S3, GCS, Azure Blob)
- Uses Barman Cloud under the hood
- "Branching" = creating a new cluster from a backup at a specific point in time
- Our reconciliation controller suspends ScheduledBackups when checkpointed

**Concerns to investigate**:
- When the pod is checkpointed, WAL archiving stops. Is there a gap in the WAL archive?
- On restore, does WAL archiving resume seamlessly?
- Can PITR restore to a point during a checkpoint window? (Probably yes — the WAL is consistent up to checkpoint time)
- ScheduledBackup suspend/resume — verify no backups are missed or duplicated
- Test creating a new cluster from a PITR backup of a zeropod-enabled cluster

**Test plan**:
- [ ] Configure WAL archiving to Vultr Object Storage (S3-compatible)
- [ ] Insert data, let pod checkpoint, insert more data after restore
- [ ] Verify WAL archive is continuous (no gaps)
- [ ] Test PITR restore to a timestamp during active use
- [ ] Test PITR restore to a timestamp during checkpoint window
- [ ] Test creating a "branch" (new cluster from backup)

---

## 4. Block Storage for CNPG PVs

**Question**: Can we use network block storage for CNPG PVs on dedicated nodes?

**Current understanding**:
- vx1-g nodes on Vultr do NOT support block storage ("Block storage is not compatible with this server")
- vc2 (shared CPU) nodes support `vultr-block-storage` (network-attached SSD)
- We proved storage type barely affects cold start time (CPU is the bottleneck)
- Local NVMe via `local-path` works but data is tied to the node (no migration, lost if node dies)

**Options to investigate**:
- [ ] Can we use a mixed node setup? vx1-g for compute + vc2 for storage? (Probably not useful)
- [ ] Vultr Object Storage for CNPG backups (S3-compatible) — this is the production answer for durability
- [ ] Can Vultr VFS storage work on vx1-g? (We got "access mode not supported" — needs more investigation)
- [ ] For production: local-path + WAL archiving to object storage = fast local + durable remote
- [ ] Ask Vultr support about block storage on vx1-g nodes

**Recommended approach**:
- Use `local-path` (local NVMe) for hot data (PG data dir + checkpoint images)
- Configure CNPG WAL archiving + ScheduledBackups to Vultr Object Storage
- If node dies: restore from backup to a new node (CNPG handles this natively)

---

## 5. Testing Environment

**Current VKE cluster state**:
- Kubeconfig: `~/Downloads/vke-e6be6bb3-7757-46be-a2e4-1e128eed27f1.yaml`
- Dedicated node: `dedicated-7a71451ed419` (vx1-g-2c-8g-120s) — **cordoned**
- Shared node: `shared-0c8f66c2898d` (vc2-2c-4gb) — active
- CNPG webhooks patched to `failurePolicy: Ignore` (VKE API server can't reach pods on vx1-g)
- `local-path` StorageClass installed (Rancher local-path-provisioner)
- zeropod DaemonSet on both nodes

**To test on vx1-g**:
- [ ] Uncordon dedicated node
- [ ] Cordon shared node
- [ ] Run tests with `STORAGE_CLASS=local-path STORAGE_SIZE=10Gi`

**To test on shared**:
- [ ] Uncordon shared node
- [ ] Cordon dedicated node
- [ ] Run tests with default storage class (or `local-path`)

---

## 6. Uncommitted Changes

Files with pending changes:
- `internal/webhook/webhook.go` — wake-peers annotation injection
- `scripts/bench-coldstart.sh` — cleaned up PG params (removed max_worker_processes)
- `docs/status.md` — updated benchmarks
- `README.md` — updated cold start numbers

Should commit these before starting new work.
