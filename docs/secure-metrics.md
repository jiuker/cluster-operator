# Secure Metrics with HTTPS

## Overview

By default, the RabbitMQ Cluster Operator serves metrics over HTTP on port 8080. This configuration is simple and has no external dependencies.

For production environments where secure metrics are required, you can enable HTTPS metrics with authentication and authorization. This requires [cert-manager](https://cert-manager.io/) to be installed in your cluster to manage TLS certificates.

## HTTP vs HTTPS Metrics

### HTTP (Default)

- **Port**: 8080
- **Protocol**: HTTP
- **Authentication**: None
- **Authorization**: None
- **Dependencies**: None
- **Use case**: Development, testing, internal networks

### HTTPS (Optional)

- **Port**: 8443
- **Protocol**: HTTPS
- **Authentication**: Kubernetes TokenReview
- **Authorization**: Kubernetes SubjectAccessReview
- **Dependencies**: cert-manager
- **Use case**: Production, security-sensitive environments

## Prerequisites

To enable HTTPS metrics, you need:

1. **cert-manager** installed in your cluster (v1.0.0 or later)
2. **kubectl** with access to your cluster
3. **kustomize** (v5.0.0 or later) or the operator's Makefile

## Enabling HTTPS Metrics

### Method 1: Using Kustomize Overlay

The operator provides a pre-configured Kustomize overlay for HTTPS metrics:

```bash
# Deploy with HTTPS metrics
kubectl apply -k config/overlays/metrics-https
```

This overlay will:
- Change the metrics port from 8080 to 8443
- Enable TLS on the metrics endpoint
- Add `--metrics-secure=true` flag to the operator
- Create RBAC roles for authentication and authorization
- Configure cert-manager to issue certificates

### Method 2: Using the Makefile with YTT

If you're using the operator's Makefile and YTT for deployment:

```bash
# Deploy with HTTPS metrics using YTT overlay
make deploy-manager-dev OVERLAY_PATH=config/overlays/metrics-https
```

### Method 3: Manual Kustomize Patch

Create your own `kustomization.yaml` that includes the HTTPS overlay:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- github.com/rabbitmq/cluster-operator/config/overlays/metrics-https?ref=main

# Add your other customizations here
```

## What Gets Changed

The HTTPS overlay makes the following changes:

1. **Manager Deployment**:
   - Adds `--metrics-bind-address=:8443` argument
   - Adds `--metrics-secure=true` argument
   - Changes container port from 8080 to 8443

2. **Metrics Service**:
   - Changes port from 8080 to 8443
   - Changes protocol name from `http` to `https`

3. **RBAC**:
   - Creates `metrics-auth-role` ClusterRole for TokenReview and SubjectAccessReview
   - Creates `metrics-auth-rolebinding` ClusterRoleBinding
   - Creates `metrics-reader` ClusterRole for accessing the `/metrics` endpoint

## Accessing Secure Metrics

When HTTPS metrics are enabled, clients need proper authentication to access the metrics endpoint.

### Using kubectl with a Service Account Token

```bash
# Create a ServiceAccount with metrics reader permissions
kubectl create serviceaccount metrics-reader -n default

# Bind the metrics-reader role
kubectl create clusterrolebinding metrics-reader-binding \
  --clusterrole=metrics-reader \
  --serviceaccount=default:metrics-reader

# Get the token
TOKEN=$(kubectl create token metrics-reader -n default)

# Access metrics
kubectl port-forward -n rabbitmq-system \
  svc/rabbitmq-cluster-operator-metrics-service 8443:8443

curl -k -H "Authorization: Bearer $TOKEN" \
  https://localhost:8443/metrics
```

### Prometheus Configuration

For Prometheus to scrape HTTPS metrics, configure a ServiceMonitor with authentication:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: rabbitmq-cluster-operator
  namespace: rabbitmq-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: rabbitmq-cluster-operator
  endpoints:
  - port: https
    scheme: https
    tlsConfig:
      insecureSkipVerify: true  # Use proper CA in production
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
```

## Security Considerations

### TLS Certificate Management

The HTTPS metrics endpoint uses certificates managed by cert-manager. Ensure that:

- cert-manager is running and healthy
- The operator namespace has appropriate certificate issuers
- Certificates are renewed before expiration

### Authentication and Authorization

With HTTPS metrics enabled:

- All requests are authenticated using Kubernetes TokenReview
- Authorization is enforced using SubjectAccessReview
- Only clients with the `metrics-reader` role can access metrics

### Network Policies

Consider implementing NetworkPolicies to restrict metrics access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-metrics-from-prometheus
  namespace: rabbitmq-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: rabbitmq-cluster-operator
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 8443
```

## Troubleshooting

### Metrics endpoint not accessible

Check that the operator is running with the correct flags:

```bash
kubectl logs -n rabbitmq-system deployment/rabbitmq-cluster-operator | grep metrics
```

You should see:
```
--metrics-bind-address=:8443
--metrics-secure=true
```

### Certificate issues

Check cert-manager certificate status:

```bash
kubectl get certificates -n rabbitmq-system
kubectl describe certificate <cert-name> -n rabbitmq-system
```

### Authentication failures

Verify the token has proper permissions:

```bash
kubectl auth can-i get /metrics --as=system:serviceaccount:default:metrics-reader
```

## Reverting to HTTP

To revert to HTTP metrics, redeploy using the default configuration:

```bash
kubectl apply -k config/installation
```

Or update the deployment manually:

```bash
kubectl patch deployment rabbitmq-cluster-operator -n rabbitmq-system \
  --type=json \
  -p='[
    {"op": "remove", "path": "/spec/template/spec/containers/0/args/0"},
    {"op": "remove", "path": "/spec/template/spec/containers/0/args/0"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/ports/0/containerPort", "value": 8080}
  ]'

kubectl patch service rabbitmq-cluster-operator-metrics-service -n rabbitmq-system \
  --type=json \
  -p='[
    {"op": "replace", "path": "/spec/ports/0/port", "value": 8080},
    {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 8080}
  ]'
```

## References

- [cert-manager documentation](https://cert-manager.io/docs/)
- [Kubernetes Authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes Authorization](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)
- [Prometheus Operator ServiceMonitor](https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api.md#servicemonitor)
