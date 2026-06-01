# RabbitmqCluster Quorum Status

## Overview

The `quorumStatus` field in the RabbitmqCluster status provides real-time information about whether any node in the cluster is quorum critical. This helps operators understand if it's safe to restart or delete pods during maintenance operations.

## How It Works

The cluster operator continuously monitors all RabbitMQ nodes by:

1. **Discovering pods** via EndpointSlice resources for the cluster
2. **Connecting directly to each pod** using its stable DNS name: `<pod-name>.<cluster-name>-nodes.<namespace>.svc`
3. **Querying the RabbitMQ Management API** endpoint `/api/health/checks/node-is-quorum-critical` for each node
4. **Aggregating results** into a single status string that reflects the cluster-wide state

### Connection Method

The operator connects to each pod using StatefulSet stable DNS names rather than Pod IPs. This is particularly important for TLS deployments where users typically configure certificates with Subject Alternative Names (SANs) for the pod DNS names:

```
<pod-name>.<headless-service>.<namespace>.svc
```

For example, for a cluster named `my-rabbit` in namespace `default`:
- Pod 0: `my-rabbit-server-0.my-rabbit-nodes.default.svc`
- Pod 1: `my-rabbit-server-1.my-rabbit-nodes.default.svc`
- Pod 2: `my-rabbit-server-2.my-rabbit-nodes.default.svc`

This approach ensures TLS certificate validation works correctly without requiring users to include Pod IP-based DNS entries (`*.pod`) in their certificates.

## Status Values

The `quorumStatus` field uses a structured format: `<status> [(<details>)]`

### Healthy States

| Status | Meaning | Example |
|--------|---------|---------|
| `ok` | All nodes are healthy and none are quorum critical | `ok` |
| `ok (N unavailable)` | No nodes are quorum critical, but some nodes couldn't be reached | `ok (1 unavailable)` |

### Unhealthy States

| Status | Meaning | Example |
|--------|---------|---------|
| `quorum-critical: pod-names` | One or more pods are quorum critical | `quorum-critical: my-rabbit-server-0` |
| `quorum-critical: pod-names (N unavailable)` | Some pods are quorum critical AND some couldn't be reached | `quorum-critical: my-rabbit-server-0, my-rabbit-server-2 (1 unavailable)` |
| `unavailable` | All nodes unreachable or the cluster isn't ready | `unavailable` |

### What Does "Quorum Critical" Mean?

A node is quorum critical if stopping it would cause quorum queues to lose their quorum (majority). This happens when:
- The node hosts leader replicas for quorum queues
- There aren't enough other nodes with synced replicas to maintain quorum if this node goes down

## Viewing Quorum Status

### Using kubectl

```bash
# View the full status
kubectl get rabbitmqcluster my-cluster -o jsonpath='{.status.quorumStatus}'

# Watch for changes
kubectl get rabbitmqcluster my-cluster -w -o jsonpath='{.status.quorumStatus}'

# View as part of the full status
kubectl get rabbitmqcluster my-cluster -o yaml
```

### Example Output

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: my-cluster
  namespace: default
spec:
  replicas: 3
status:
  quorumStatus: ok
  conditions:
  - type: AllReplicasReady
    status: "True"
```

## Use Cases

### Pre-Maintenance Checks

Before performing maintenance operations, check the quorum status:

```bash
STATUS=$(kubectl get rabbitmqcluster my-cluster -o jsonpath='{.status.quorumStatus}')
if [[ "$STATUS" == "ok" ]]; then
  echo "Safe to proceed with maintenance"
else
  echo "WARNING: Cluster has quorum issues: $STATUS"
fi
```

### Monitoring and Alerting

Set up alerts when quorum status indicates problems:

```yaml
# Prometheus alert example
- alert: RabbitMQQuorumCritical
  expr: |
    rabbitmq_cluster_quorum_status{status!="ok"} == 1
  for: 5m
  annotations:
    summary: "RabbitMQ cluster {{ $labels.cluster }} has quorum issues"
    description: "Status: {{ $labels.quorum_status }}"
```

## Integration with StatefulSet PreStop Hooks

The quorum status feature complements but does not replace the StatefulSet preStop hooks. They work together to ensure safe pod termination:

1. **PreStop Hook (local check)**: Each pod blocks its own termination until it's not quorum critical
2. **Quorum Status (cluster-wide visibility)**: Provides operators visibility into which pods are blocking and why

The preStop hook continues to be the primary mechanism for preventing unsafe pod deletions. The quorum status field provides observability into the cluster state.

For more details on the preStop hook mechanism, see [Gracefully terminating RabbitMQ pods](design/20200520-graceful-pod-termination.md).

## Limitations

### 1. Manual RabbitMQ Changes Not Reflected

**CRITICAL**: The quorum status only reflects the state of queues and nodes known to Kubernetes. If you manually modify queue membership or node configuration directly in RabbitMQ (bypassing Kubernetes), the status may be inaccurate.

**Examples of operations that can cause inaccuracy:**
- Manually deleting or adding queue replicas via RabbitMQ CLI
- Using `rabbitmqctl` to add/remove cluster members outside of Kubernetes
- Direct modifications via RabbitMQ Management UI that change queue topology

**Recommendation**: Always manage your RabbitMQ cluster through Kubernetes (scaling replicas, etc.) to ensure the quorum status remains accurate.

### 2. Point-in-Time Check

The status reflects the state at the time of the last reconciliation. The cluster state may change between checks. The reconciliation loop typically runs:
- Every few seconds during normal operation
- Immediately when cluster configuration changes
- When pods are created/deleted

### 3. Network Issues

If the operator cannot reach a pod (network issues, pod not ready, etc.), that pod is counted as "unavailable" in the status. This doesn't necessarily mean the pod is unhealthy from RabbitMQ's perspective.

### 4. TLS Configuration Requirements

For TLS-enabled clusters, ensure your certificates include the appropriate SANs:

**Required SANs:**
```
DNS:my-rabbit-server-0.my-rabbit-nodes.default.svc
DNS:my-rabbit-server-1.my-rabbit-nodes.default.svc
DNS:my-rabbit-server-2.my-rabbit-nodes.default.svc
```

**Not required (but previously needed):**
```
DNS:10-0-0-1.default.pod
DNS:*.default.pod
```

The operator uses stable DNS names specifically to avoid requiring Pod IP-based DNS entries in certificates.

## Troubleshooting

### Status Shows "unavailable"

**Possible causes:**
1. Cluster is still initializing (wait for pods to become ready)
2. StatefulSet has no ready pods
3. Network connectivity issues between operator and pods
4. RabbitMQ Management API is not responding

**Debug steps:**
```bash
# Check pod status
kubectl get pods -l app.kubernetes.io/name=<cluster-name>

# Check if management API is accessible
kubectl exec <pod-name> -- rabbitmq-diagnostics check_running

# Check operator logs
kubectl logs -n rabbitmq-system deployment/rabbitmq-cluster-operator
```

### Status Shows Persistent "quorum-critical"

**Possible causes:**
1. High queue throughput preventing sync
2. Not enough replicas for the configured queue replication factor
3. Network issues between RabbitMQ nodes
4. Disk or memory pressure preventing sync

**Debug steps:**
```bash
# Check queue status
kubectl exec <pod-name> -- rabbitmqctl list_queues name type members

# Check cluster status
kubectl exec <pod-name> -- rabbitmqctl cluster_status

# Check for alarms
kubectl exec <pod-name> -- rabbitmqctl eval 'rabbit_alarm:get_alarms().'
```

### Status Shows "(N unavailable)"

Some pods couldn't be queried. Check individual pod health:

```bash
# Check pod status
kubectl describe pod <pod-name>

# Check if management plugin is enabled
kubectl exec <pod-name> -- rabbitmq-plugins list

# Test management API manually
kubectl exec <pod-name> -- curl -u guest:guest http://localhost:15672/api/health/checks/node-is-quorum-critical
```

## Best Practices

1. **Monitor the status**: Set up alerts for non-"ok" status values
2. **Use in CI/CD**: Check quorum status before rolling updates or deployments
3. **Respect the status**: Don't force-delete pods showing as quorum critical unless absolutely necessary
4. **Plan for redundancy**: Ensure you have enough replicas (typically 3 or 5) to maintain quorum during maintenance
5. **Use proper certificates**: For TLS clusters, include pod stable DNS names in certificate SANs
6. **Manage via Kubernetes**: Always scale and manage the cluster through the RabbitmqCluster resource, not directly via RabbitMQ

## References

- [RabbitMQ Quorum Queues Documentation](https://www.rabbitmq.com/quorum-queues.html)
- [rabbitmq-queues CLI Reference](https://www.rabbitmq.com/rabbitmq-queues.8.html)
- [StatefulSet DNS](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-network-id)
- [Graceful Pod Termination Design](design/20200520-graceful-pod-termination.md)
