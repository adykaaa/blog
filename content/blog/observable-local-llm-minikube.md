---
title: "Observing a local LLM on minikube with OpenLIT and Grafana"
date: 2026-10-04T18:00:00+02:00
description: "A complete CPU-only local LLM runbook with OpenLIT, Prometheus, Tempo, and one Grafana operations dashboard."
tags: ["Kubernetes", "AI", "Observability", "Grafana"]
draft: false
wideCode: true
toc: true
---

I wanted to see what a local LLM was doing without building a large observability platform around it. The result is a small CPU-only model on minikube, OpenLIT instrumentation, Prometheus and Tempo, and one Grafana dashboard focused on the questions I care about as a platform engineer: is it available, how long do requests take, where does capacity run out, and can I follow an individual inference request?

The starting point was [Grafana’s zero-code AI observability article](https://grafana.com/blog/ai-observability-zero-code/). This runbook adapts that idea to a local, open-source stack. It uses real inference from SmolLM2 135M rather than synthetic AI responses. Everything needed to reproduce it is included inline below.

## What the dashboard tells me

The single **Local LLM / Platform Operations** dashboard covers request volume and HTTP outcomes; p50/p95/p99 latency and time to first token; input/output tokens; inference throughput and cache behavior; admission pressure and backend queues; CPU, memory, throttling, OOMs and restarts; and the health of the telemetry pipeline. Its trace table lets me inspect individual SDK calls in Tempo.

Dashboard overview:

![Token usage, prompt cache efficiency, and inference throughput in Grafana](/blog/images/observable-local-llm-minikube/tokens-and-throughput.png)

![Request admission, context usage, CPU, memory, throttling, and restarts in Grafana](/blog/images/observable-local-llm-minikube/capacity-and-resources.png)

## Where the metrics actually come from

Grafana is the presentation layer. It queries **Prometheus for metrics** and **Tempo for traces**. It does not read the model’s weights or scrape the model itself.

| Source | How it reaches the backends | What it measures |
| --- | --- | --- |
| llama.cpp model server | Prometheus scrapes `http://smollm-model:8080/metrics` | Native inference throughput, active requests, queued requests, prompt cache behavior and context high-water mark |
| Python gateway | Prometheus scrapes `http://smollm-client:8080/metrics` | HTTP outcomes, successful request latency, arrival-to-first-content-token time, token counts, admission pressure and completion reasons |
| OpenLIT SDK instrumentation | Sends OTLP to the Collector; Prometheus scrapes the Collector exporter at `http://otel-collector:8889/metrics`; the Collector forwards traces to Tempo | Instrumented OpenAI-compatible SDK call durations, token usage and inference spans |
| Kubernetes kubelet/cAdvisor | Prometheus scrapes each node through the Kubernetes API proxy at `/api/v1/nodes/<node>/proxy/metrics/cadvisor` | Container CPU, memory working set, CPU throttling and OOM events |
| Kubernetes API | The Collector’s `k8s_cluster` receiver reads workload metadata and exposes metrics through the same exporter | Readiness, restarts, desired/available replicas and configured resource limits |
| Collector, Tempo and Prometheus | Prometheus scrapes their own metrics endpoints | Whether the monitoring pipeline is accepting, exporting and storing telemetry |

These addresses are Kubernetes Services inside the `ai-observability` namespace. Prometheus pulls the scrape endpoints periodically. OpenLIT instead pushes telemetry to the Collector’s OTLP endpoint. The `--metrics` flag on llama.cpp enables the model server’s native metrics endpoint; the gateway implements its own endpoint because the server cannot measure the entire caller-to-gateway experience.

For example, a slow request can have a high gateway latency while the model’s decode throughput stays healthy: it may have waited behind another request. Looking at admitted requests, the backend queue, TTFT and decode throughput together helps distinguish waiting from slow inference. Gateway TTFT here means time until the first model content chunk reaches the gateway; the HTTP response to the caller is buffered.

Metrics and capacity panels:

![Scrape health, accepted telemetry, trace delivery, exporter queue, and Tempo spans in Grafana](/blog/images/observable-local-llm-minikube/telemetry-pipeline.png)

A request trace in Tempo:

![Tempo request trace showing inference duration, token usage, prompt, and model response](/blog/images/observable-local-llm-minikube/tempo-request-trace.png)

This setup measures system behavior. It does not evaluate answer correctness, report live KV-cache occupancy, or invent cloud billing costs for a local CPU model. The small model is useful for exercising the complete pipeline; it is not a benchmark of production model quality.

## Reproduce the setup

This guide is self-contained. Every application source file, configuration, Kubernetes YAML manifest, and dashboard definition is included below. Run the steps in order in a directory of your choice; no existing repository or machine-specific path is needed.

Target: a Linux/amd64 Kubernetes node running in a minikube Docker profile. Host prerequisites: Docker, minikube, kubectl, Python 3, Bash, curl, tar, openssl, and base64. Initial downloads need public internet access. Use cluster-admin credentials for operator/CRD installation. The pinned Python instrumentation image and CPU server digest are amd64; another node architecture needs compatible image builds.

## Architecture

```text
POST /chat → Python gateway → llama.cpp CPU server → SmolLM2 135M Q4_K_M
                 │                     │
                 │ OpenLIT OTLP        │ native inference metrics
                 ▼                     ▼
        OpenTelemetry Collector → Prometheus ← gateway /metrics
                 │                     ↑
                 │ traces       kubelet cAdvisor via Kubernetes API
                 ▼                     │
               Tempo ─────────────── Grafana
                            one Local LLM / Platform Operations dashboard
```

One process/pod per application or backend. No distributed backend deployments, GPU allocation, separate OpenLIT UI, ClickHouse, or Loki. The existing Collector collects Kubernetes readiness/restarts/limits; Prometheus scrapes the kubelet for CPU, memory, throttling, and OOM counters, so no additional resource exporter is needed. Separate log events are discarded; metrics and traces are retained. Inference is demand-driven.

Pinned versions: Grafana Operator 5.25.0; Grafana 13.1.3; OpenLIT chart 0.2.2/operator and injection image 0.0.2; Prometheus 3.15.0; Tempo 2.10.8; Collector Contrib 0.161.0; Python 3.11/OpenAI client SDK 1.109.1. Tempo 2.10 retains the small single-process architecture. The llama.cpp CPU image and model blob are pinned by SHA-256 in the model deployment YAML.

## 1. Start the cluster and choose a working directory

Choose any profile name. The commands consistently target its matching Kubernetes context.

```bash
export CLUSTER="llm-lab"
mkdir -p local-llm-observability
cd local-llm-observability

minikube start -p "$CLUSTER" --driver=docker --cpus=2 --memory=4096
minikube status -p "$CLUSTER"
kubectl --context "$CLUSTER" get nodes

```

Expected: the node is Ready. On an existing profile, `minikube start -p "$CLUSTER"` resumes its original settings. No cluster deletion is required. Keep this shell for installation; new terminals must set the same `CLUSTER` value.

The cluster needs a default StorageClass; minikube's standard storage provisioner normally provides one.

```bash
kubectl --context "$CLUSTER" get storageclass
```

## 2. Make Helm available

```bash
if command -v helm >/dev/null 2>&1; then
  HELM=helm
else
  mkdir -p tools
  HELM_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  HELM_ARCH=$(uname -m)
  case "$HELM_ARCH" in
    x86_64) HELM_ARCH=amd64 ;;
    aarch64|arm64) HELM_ARCH=arm64 ;;
    *) echo "Unsupported Helm host architecture: $HELM_ARCH"; exit 1 ;;
  esac
  curl -fsSL \
    "https://get.helm.sh/helm-v3.19.0-${HELM_OS}-${HELM_ARCH}.tar.gz" \
    -o tools/helm.tar.gz
  tar -xzf tools/helm.tar.gz -C tools
  HELM="$PWD/tools/${HELM_OS}-${HELM_ARCH}/helm"
fi
"$HELM" version --short
```

## 3. Install Grafana Operator and persistent Grafana

Server-side apply avoids oversized client-side CRD annotations. The operator watches the `grafana` namespace. Credentials are generated once and stored in a Secret; no password is embedded in this guide.

```bash
kubectl --context "$CLUSTER" apply --server-side -f \
  https://github.com/grafana/grafana-operator/releases/download/v5.25.0/kustomize-namespace_scoped.yaml
kubectl --context "$CLUSTER" wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=180s
kubectl --context "$CLUSTER" -n grafana rollout status deployment/grafana-operator-controller-manager --timeout=300s

if ! kubectl --context "$CLUSTER" -n grafana get secret grafana-admin >/dev/null 2>&1; then
  GRAFANA_INITIAL_PASSWORD=$(openssl rand -hex 24)
  kubectl --context "$CLUSTER" -n grafana create secret generic grafana-admin \
    --from-literal=GF_SECURITY_ADMIN_USER=admin \
    --from-literal=GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_INITIAL_PASSWORD"
  unset GRAFANA_INITIAL_PASSWORD
fi
```

Save the following as `grafana.yaml`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: grafana
  labels:
    dashboards: grafana
spec:
  version: 13.1.3
  disableDefaultAdminSecret: true
  config:
    log:
      mode: console
    server:
      protocol: http
  persistentVolumeClaim:
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi
  deployment:
    spec:
      strategy:
        type: Recreate
        rollingUpdate: null
      template:
        spec:
          securityContext:
            fsGroup: 472
          volumes:
            - name: grafana-data
              persistentVolumeClaim:
                claimName: grafana-pvc
          containers:
            - name: grafana
              env:
                - name: GF_SECURITY_ADMIN_USER
                  valueFrom:
                    secretKeyRef:
                      name: grafana-admin
                      key: GF_SECURITY_ADMIN_USER
                - name: GF_SECURITY_ADMIN_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: grafana-admin
                      key: GF_SECURITY_ADMIN_PASSWORD
```

```bash
kubectl --context "$CLUSTER" apply -f grafana.yaml

# The operator creates the Deployment asynchronously.
for attempt in {1..120}; do
  if kubectl --context "$CLUSTER" -n grafana get deployment grafana-deployment >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl --context "$CLUSTER" -n grafana rollout status deployment/grafana-deployment --timeout=300s
kubectl --context "$CLUSTER" -n grafana get pvc,pods
```

Expected: `grafana-pvc` is Bound and Grafana is ready. This provisions persistent data from the first start of a new instance. Migrating an already-populated temporary Grafana volume requires copying/backing up its database before changing the volume.

## 4. Deploy Prometheus, Tempo, and the Collector

The manifest below contains all configurations, PVCs, Services, Deployments, and RBAC. Save it as a plain YAML file and apply it with kubectl. After editing a ConfigMap, explicitly restart its Deployment as shown in step 11 so the process reloads its configuration. The Collector's Kubernetes API access is read-only and scoped to the application namespace. Prometheus discovers node names automatically, authenticates with its ServiceAccount, and verifies the API server's certificate.

Save the following as `stack.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus
  namespace: ai-observability
data:
  config.yaml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: openlit
        static_configs:
          - targets: ['otel-collector:8889']
      - job_name: smollm-model
        static_configs:
          - targets: ['smollm-model:8080']
      - job_name: smollm-client
        static_configs:
          - targets: ['smollm-client:8080']
      - job_name: collector-internal
        static_configs:
          - targets: ['otel-collector:8888']
      - job_name: tempo
        static_configs:
          - targets: ['tempo:3200']
      - job_name: kubelet-cadvisor
        scheme: https
        authorization:
          credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - source_labels: [__meta_kubernetes_node_name]
            target_label: __metrics_path__
            replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor
          - target_label: __address__
            replacement: kubernetes.default.svc:443
        metric_relabel_configs:
          - source_labels: [namespace, pod]
            regex: 'ai-observability;smollm-(model|client)-.*'
            action: keep
          - source_labels: [__name__]
            regex: 'container_(cpu_usage_seconds_total|cpu_cfs_periods_total|cpu_cfs_throttled_periods_total|memory_working_set_bytes|oom_events_total)'
            action: keep
      - job_name: prometheus
        static_configs:
          - targets: ['localhost:9090']
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus
  namespace: ai-observability
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ai-observability
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      securityContext:
        fsGroup: 10001
      containers:
      - name: prometheus
        image: prom/prometheus:v3.15.0
        args:
        - --config.file=/etc/observability/config.yaml
        - --storage.tsdb.path=/data
        - --storage.tsdb.retention.time=24h
        - --storage.tsdb.retention.size=512MB
        ports:
        - name: http
          containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/observability
          readOnly: true
        - name: data
          mountPath: /data
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 5
        env:
        - name: GOMEMLIMIT
          value: 200MiB
      volumes:
      - name: config
        configMap:
          name: prometheus
      - name: data
        persistentVolumeClaim:
          claimName: prometheus
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ai-observability
spec:
  selector:
    app: prometheus
  ports:
  - name: http
    port: 9090
    targetPort: 9090
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector
  namespace: ai-observability
data:
  config.yaml: |
    receivers:
      k8s_cluster:
        auth_type: serviceAccount
        collection_interval: 30s
        namespaces: [ai-observability]
        metrics:
          k8s.container.cpu_limit:
            enabled: true
          k8s.container.memory_limit:
            enabled: true
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 96
        spike_limit_mib: 24
      batch:
        timeout: 2s
    exporters:
      nop:
      prometheus:
        endpoint: 0.0.0.0:8889
        resource_to_telemetry_conversion:
          enabled: true
        enable_open_metrics: true
      otlp/tempo:
        endpoint: tempo:4317
        tls:
          insecure: true
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
    service:
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
                    without_type_suffix: true
                    without_units: true
      extensions: [health_check]
      pipelines:
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [nop]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/tempo]
        metrics:
          receivers: [otlp, k8s_cluster]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: ai-observability
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      serviceAccountName: otel-collector
      securityContext:
        fsGroup: 10001
      containers:
      - name: otel-collector
        image: otel/opentelemetry-collector-contrib:0.161.0
        args:
        - --config=/etc/observability/config.yaml
        ports:
        - name: otlp-grpc
          containerPort: 4317
        - name: otlp-http
          containerPort: 4318
        - name: metrics
          containerPort: 8889
        - name: internal
          containerPort: 8888
        - name: health
          containerPort: 13133
        volumeMounts:
        - name: config
          mountPath: /etc/observability
          readOnly: true
        resources:
          requests:
            cpu: 25m
            memory: 32Mi
          limits:
            cpu: 500m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /
            port: 13133
          initialDelaySeconds: 5
          periodSeconds: 5
        env:
        - name: GOMEMLIMIT
          value: 100MiB
      volumes:
      - name: config
        configMap:
          name: otel-collector
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: ai-observability
spec:
  selector:
    app: otel-collector
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
  - name: metrics
    port: 8889
    targetPort: 8889
  - name: internal
    port: 8888
    targetPort: 8888
  - name: health
    port: 13133
    targetPort: 13133
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo
  namespace: ai-observability
data:
  config.yaml: |
    server:
      http_listen_port: 3200
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
    ingester:
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: 24h
    storage:
      trace:
        backend: local
        wal:
          path: /data/wal
        local:
          path: /data/blocks
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tempo
  namespace: ai-observability
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: ai-observability
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      serviceAccountName: default
      securityContext:
        fsGroup: 10001
      containers:
      - name: tempo
        image: grafana/tempo:2.10.8
        args:
        - -config.file=/etc/observability/config.yaml
        ports:
        - name: http
          containerPort: 3200
        - name: otlp-grpc
          containerPort: 4317
        - name: otlp-http
          containerPort: 4318
        volumeMounts:
        - name: config
          mountPath: /etc/observability
          readOnly: true
        - name: data
          mountPath: /data
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        readinessProbe:
          httpGet:
            path: /ready
            port: 3200
          initialDelaySeconds: 5
          periodSeconds: 5
        env:
        - name: GOMEMLIMIT
          value: 200MiB
      volumes:
      - name: config
        configMap:
          name: tempo
      - name: data
        persistentVolumeClaim:
          claimName: tempo
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: ai-observability
spec:
  selector:
    app: tempo
  ports:
  - name: http
    port: 3200
    targetPort: 3200
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: ai-observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: ai-observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: llm-prometheus-kubelet
rules:
- apiGroups:
  - ''
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ''
  resources:
  - nodes/proxy
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: llm-prometheus-kubelet
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: llm-prometheus-kubelet
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: ai-observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: otel-k8s-metadata
  namespace: ai-observability
rules:
- apiGroups:
  - ''
  resources:
  - pods
  - services
  - events
  - replicationcontrollers
  - resourcequotas
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - apps
  resources:
  - deployments
  - replicasets
  - daemonsets
  - statefulsets
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - batch
  resources:
  - jobs
  - cronjobs
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - autoscaling
  resources:
  - horizontalpodautoscalers
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: otel-k8s-metadata
  namespace: ai-observability
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: otel-k8s-metadata
subjects:
- kind: ServiceAccount
  name: otel-collector
  namespace: ai-observability
```

```bash
kubectl --context "$CLUSTER" apply -f stack.yaml
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/prometheus --timeout=300s
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/tempo --timeout=300s
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/otel-collector --timeout=300s
```

The model/client scrape targets will be down until step 6 deploys them. This is expected. Prometheus retains 24 hours of data and limits TSDB retention size to 512 MB; Tempo retains traces for 24 hours. Both use local PVC storage. The Collector's metrics exporter and sending queue are in memory.

## 5. Install OpenLIT and its opt-in policy

Save the following as `openlit-values.yaml`:

```yaml
operator:
  defaultInitImage: ghcr.io/openlit/openlit-ai-instrumentation:0.0.2
resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    cpu: 250m
    memory: 128Mi
```

```bash
"$HELM" repo add openlit https://openlit.github.io/helm/
"$HELM" repo update openlit
"$HELM" upgrade --install openlit-operator openlit/openlit-operator \
  --version 0.2.2 --kube-context "$CLUSTER" \
  --namespace openlit --create-namespace -f openlit-values.yaml
kubectl --context "$CLUSTER" wait --for=condition=Established crd/autoinstrumentations.openlit.io --timeout=180s
kubectl --context "$CLUSTER" -n openlit rollout status deployment/openlit-operator --timeout=180s
```

Save the following as `openlit-instrumentation.yaml`:

```yaml
apiVersion: openlit.io/v1alpha1
kind: AutoInstrumentation
metadata:
  name: grafana-observability
  namespace: ai-observability
spec:
  selector:
    matchLabels:
      instrumentation: openlit
  python:
    instrumentation:
      enabled: true
      provider: openlit
      version: "0.0.2"
  otlp:
    endpoint: http://otel-collector.ai-observability.svc.cluster.local:4318
  resource:
    environment: minikube
```

```bash
kubectl --context "$CLUSTER" apply -f openlit-instrumentation.yaml
```

The operator manages its own admission-webhook certificates. It instruments only selected Python pods created after the policy is ready. Keep Python 3.11 for this pinned injection image: its compiled dependencies use that ABI. The gateway's explicit Python command lets the operator recognize the locally built application image.

## 6. Write and deploy the real model gateway

This gateway uses an OpenAI-compatible SDK against the local model server. Its application code does not initialize OpenLIT: injection supplies that instrumentation. It also exposes low-cardinality HTTP/admission/finish-reason/latency histograms for operational visibility.

At most two requests are admitted against one inference slot. Extra requests receive HTTP 429 rather than creating an unbounded inference queue. Responses use up to 64 generated tokens. The gateway consumes the model stream internally to measure arrival-to-first-content latency, then returns a buffered JSON response. Its TTFT therefore measures model streaming at the gateway, not HTTP time-to-first-byte experienced by the caller.

Save the following as `app.py`:

```python
"""Local LLM gateway with bounded admission and low-cardinality Prometheus metrics."""

import json
import os
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from openai import OpenAI, BadRequestError, APITimeoutError

MODEL = "smollm2:135m-instruct-q4_K_M"
MAX_INFLIGHT = 2
CONTEXT_LIMIT = 512
client = OpenAI(
    base_url=os.environ["MODEL_BASE_URL"],
    api_key="local-no-key",
    timeout=60,
    max_retries=0,
)
slots = threading.BoundedSemaphore(MAX_INFLIGHT)
lock = threading.Lock()
requests = Counter({str(s): 0 for s in [200, 400, 413, 429, 502, 504]})
finishes = Counter({s: 0 for s in ["stop", "length", "other"]})
inflight = 0
histograms = {}
for name in ["local_llm_http_duration_seconds", "local_llm_first_token_seconds"]:
    histograms[name] = {
        "bounds": [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60],
        "counts": [0] * 12,
        "count": 0,
        "sum": 0.0,
    }


def observe(name, value):
    with lock:
        h = histograms[name]
        h["count"] += 1
        h["sum"] += value
        for i, bound in enumerate(h["bounds"]):
            h["counts"][i] += value <= bound


def metrics():
    with lock:
        lines = ["# TYPE local_llm_http_requests_total counter"]
        lines += [
            f'local_llm_http_requests_total{{status="{s}"}} {n}'
            for s, n in requests.items()
        ]
        lines += ["# TYPE local_llm_completions_total counter"]
        lines += [
            f'local_llm_completions_total{{finish_reason="{s}"}} {n}'
            for s, n in finishes.items()
        ]
        lines += [
            "# TYPE local_llm_inflight_requests gauge",
            f"local_llm_inflight_requests {inflight}",
            "# TYPE local_llm_admission_capacity gauge",
            f"local_llm_admission_capacity {MAX_INFLIGHT}",
        ]
        for name, h in histograms.items():
            lines += [f"# TYPE {name} histogram"]
            lines += [
                f'{name}_bucket{{le="{b}"}} {n}'
                for b, n in zip(h["bounds"], h["counts"])
            ]
            lines += [
                f'{name}_bucket{{le="+Inf"}} {h["count"]}',
                f'{name}_sum {h["sum"]}',
                f'{name}_count {h["count"]}',
            ]
        return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, content_type="application/json"):
        body = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send(200, {"status": "ok", "model": MODEL})
        elif self.path == "/metrics":
            self.send(200, metrics(), "text/plain; version=0.0.4")
        else:
            self.send(404, {"error": "Use POST /chat with a JSON prompt."})

    def do_POST(self):
        global inflight
        if self.path != "/chat":
            self.send(404, {"error": "Unknown endpoint"})
            return
        start = time.monotonic()
        admitted = slots.acquire(blocking=False)
        status = 429
        payload = {
            "error": "Busy; at most two inference requests are admitted. Retry later."
        }
        if admitted:
            with lock:
                inflight += 1
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 8192:
                    status = 413
                    payload = {"error": "Send a JSON body of 1–8192 bytes."}
                else:
                    data = json.loads(self.rfile.read(size))
                    prompt = data.get("prompt") if isinstance(data, dict) else None
                    max_tokens = (
                        data.get("max_tokens", 64) if isinstance(data, dict) else None
                    )
                    if (
                        not isinstance(prompt, str)
                        or not prompt.strip()
                        or len(prompt) > 2000
                    ):
                        raise ValueError("prompt must contain 1–2000 characters.")
                    if type(max_tokens) is not int or not 1 <= max_tokens <= 64:
                        raise ValueError("max_tokens must be an integer from 1 to 64.")
                    text, usage, reason, ttft = [], None, "other", None
                    with client.chat.completions.create(
                        model=MODEL,
                        messages=[{"role": "user", "content": prompt}],
                        max_tokens=max_tokens,
                        temperature=0.2,
                        stream=True,
                        stream_options={"include_usage": True},
                    ) as stream:
                        for chunk in stream:
                            if chunk.usage:
                                usage = chunk.usage.model_dump()
                            for choice in chunk.choices:
                                content = choice.delta.content
                                if content:
                                    if ttft is None:
                                        ttft = time.monotonic() - start
                                        observe("local_llm_first_token_seconds", ttft)
                                    text.append(content)
                                if choice.finish_reason:
                                    reason = (
                                        choice.finish_reason
                                        if choice.finish_reason in ["stop", "length"]
                                        else "other"
                                    )
                    with lock:
                        finishes[reason] += 1
                    status = 200
                    payload = {
                        "model": MODEL,
                        "response": "".join(text),
                        "usage": usage,
                        "finish_reason": reason,
                        "first_token_seconds": ttft,
                        "duration_seconds": round(time.monotonic() - start, 3),
                    }
            except (ValueError, TypeError, BadRequestError) as exc:
                status, payload = 400, {"error": str(exc)}
            except APITimeoutError as exc:
                status, payload = 504, {"error": str(exc)}
            except Exception as exc:
                status, payload = 502, {"error": str(exc)}
            finally:
                with lock:
                    inflight -= 1
                slots.release()
        with lock:
            requests[str(status)] += 1
        if status == 200:
            observe("local_llm_http_duration_seconds", time.monotonic() - start)
        try:
            self.send(status, payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
```

Save the following as `Dockerfile`:

```dockerfile
FROM python:3.11-slim
RUN pip install --no-cache-dir openai==1.109.1
WORKDIR /app
COPY app.py /app/app.py
CMD ["python", "-u", "/app/app.py"]
```

```bash
minikube -p "$CLUSTER" image build . -t local/smollm-client:1
```

The next code block contains the complete model and client deployment definitions. The model is a real 135M-parameter SmolLM2 Instruct Q4_K_M GGUF, approximately 105 MB. Its init container downloads a pinned blob, verifies SHA-256, and atomically renames it. Subsequent starts verify and reuse the PVC copy. The server runs CPU-only with two threads, one slot, and a 512-token context.

Save the following as `model-gateway.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smollm-model
  namespace: ai-observability
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 512Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smollm-model
  namespace: ai-observability
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: smollm-model
  template:
    metadata:
      labels:
        app: smollm-model
    spec:
      initContainers:
      - name: download-model
        image: curlimages/curl:8.17.0
        command:
        - sh
        - -c
        - |
          set -eu
          if [ -f /models/smollm2.gguf ] && \
            echo '8030f04528538d47bda434f6f0bdf3952c40a58123e4d5e755332f23731a8684  /models/smollm2.gguf' | sha256sum -c -; then
            exit 0
          fi
          curl --fail --location --retry 3 \
            https://registry.ollama.ai/v2/library/smollm2/blobs/sha256:8030f04528538d47bda434f6f0bdf3952c40a58123e4d5e755332f23731a8684 \
            -o /models/smollm2.gguf.part
          echo '8030f04528538d47bda434f6f0bdf3952c40a58123e4d5e755332f23731a8684  /models/smollm2.gguf.part' | sha256sum -c -
          mv /models/smollm2.gguf.part /models/smollm2.gguf
        securityContext:
          runAsUser: 0
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 250m
            memory: 64Mi
        volumeMounts:
        - name: models
          mountPath: /models
      containers:
      - name: model
        image: ghcr.io/ggml-org/llama.cpp@sha256:1cdfea0828170c34d56a8a6d9fc5a0898e8bca3762e5ec6be0c01032f7f7bde8
        args:
        - --model
        - /models/smollm2.gguf
        - --alias
        - smollm2:135m-instruct-q4_K_M
        - --host
        - 0.0.0.0
        - --port
        - '8080'
        - --ctx-size
        - '512'
        - --parallel
        - '1'
        - --threads
        - '2'
        - --threads-batch
        - '2'
        - --n-gpu-layers
        - '0'
        - --batch-size
        - '64'
        - --ubatch-size
        - '64'
        - --metrics
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: models
          mountPath: /models
          readOnly: true
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: '2'
            memory: 384Mi
        startupProbe:
          httpGet:
            path: /health
            port: 8080
          failureThreshold: 60
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          periodSeconds: 10
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: smollm-model
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smollm-client
  namespace: ai-observability
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: smollm-client
  template:
    metadata:
      labels:
        app: smollm-client
        instrumentation: openlit
    spec:
      containers:
      - name: client
        image: local/smollm-client:1
        imagePullPolicy: Never
        command:
        - python
        - -u
        - /app/app.py
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: MODEL_BASE_URL
          value: http://smollm-model:8080/v1
        - name: OTEL_METRIC_EXPORT_INTERVAL
          value: '15000'
        - name: OPENLIT_DISABLE_EVENTS
          value: 'true'
        resources:
          requests:
            cpu: 10m
            memory: 96Mi
          limits:
            cpu: 250m
            memory: 192Mi
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: smollm-model
  namespace: ai-observability
spec:
  selector:
    app: smollm-model
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: smollm-client
  namespace: ai-observability
spec:
  selector:
    app: smollm-client
  ports:
  - name: http
    port: 8080
    targetPort: 8080
```

```bash
kubectl --context "$CLUSTER" apply -f model-gateway.yaml
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/smollm-model --timeout=300s
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/smollm-client --timeout=180s
```

Check the injected init image and bootstrap log:

```bash
kubectl --context "$CLUSTER" -n ai-observability get pod -l app=smollm-client \
  -o jsonpath='{.items[0].spec.initContainers[0].image}'
kubectl --context "$CLUSTER" -n ai-observability logs deployment/smollm-client --tail=20
kubectl --context "$CLUSTER" -n ai-observability logs deployment/smollm-model -c download-model --tail=10
```

Expected: injection image 0.0.2, `OpenLIT auto-instrumentation initialized`, and a passing model checksum. `OTEL_METRIC_EXPORT_INTERVAL=15000` and `OPENLIT_DISABLE_EVENTS=true` are set directly on the gateway container; that avoids relying on a newer CR custom-env field which the installed operator image did not apply.

## 7. Connect Grafana to both backends

These resources must live in the Grafana Operator's watched namespace.

Save the following as `datasources.yaml`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: ai-prometheus
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: AI Prometheus
    uid: ai-prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.ai-observability.svc.cluster.local:9090
    isDefault: true
    jsonData:
      httpMethod: POST
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: ai-tempo
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: AI Tempo
    uid: ai-tempo
    type: tempo
    access: proxy
    url: http://tempo.ai-observability.svc.cluster.local:3200
    isDefault: false
    jsonData:
      tracesToMetrics:
        datasourceUid: ai-prometheus
      nodeGraph:
        enabled: true
```

```bash
kubectl --context "$CLUSTER" apply -f datasources.yaml
```

## 8. Create the single operations dashboard

The full dashboard definition is embedded as JSON in the YAML resource below, as required by the GrafanaDashboard API. This is the only dashboard provisioned by this guide. Its PromQL is included inline, and the trace table uses the Tempo datasource on the same page.

Coverage:

| Question | Signals |
| --- | --- |
| Is inference healthy? | Model/client scrape health, HTTP outcomes, valid-request success fraction, desired/available replicas, readiness |
| Is it fast? | Gateway and SDK p50/p95/p99, measured model TTFT, example ≤1-second fast-success SLI |
| How much work is being done? | Input/output token rates and volumes, p95 tokens/request, finish reasons, output-cap fraction |
| Is inference efficient? | Prefill/decode throughput during active inference, decode time/token, prompt-cache hit fraction |
| Is it saturated? | Admitted requests, admission capacity, active inference, server queue, context-length high-water mark |
| Is the platform constraining it? | CPU/memory versus limits, CFS throttling, OOM events, container restarts |
| Can the telemetry be trusted? | Scrape health, Collector accepted/refused spans and metrics, exporter failures/queue, Tempo ingest |
| Which requests explain a regression? | Embedded trace search table for `smollm-client` |

No artificial dollar-cost, GPU, semantic quality, or live KV-occupancy panels are shown. Those measurements are unavailable/not applicable to this CPU-only lab. The context signal is explicitly a high-water mark. The one-second latency threshold is illustrative, not an agreed production SLO.

Save the following as `dashboard.yaml`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: smollm-local
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: AI Observability
  json: |
    {
      "uid": "smollm-local",
      "title": "Local LLM / Platform Operations",
      "schemaVersion": 39,
      "version": 2,
      "refresh": "15s",
      "time": {
        "from": "now-30m",
        "to": "now"
      },
      "tags": [
        "llm",
        "platform",
        "openlit"
      ],
      "panels": [
        {
          "id": 1,
          "type": "row",
          "title": "Service health and traffic",
          "collapsed": false,
          "panels": [],
          "gridPos": {
            "x": 0,
            "y": 0,
            "w": 24,
            "h": 1
          }
        },
        {
          "id": 2,
          "title": "Model ready",
          "description": "Scrape/model availability, independent of whether traffic exists.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              },
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {
                    "color": "red",
                    "value": null
                  },
                  {
                    "color": "green",
                    "value": 1
                  }
                ]
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "up{job=\"smollm-model\"}",
              "legendFormat": "value",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 3,
          "title": "Client ready",
          "description": "Metrics endpoint availability. Check replicas below for Kubernetes readiness.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 4,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              },
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {
                    "color": "red",
                    "value": null
                  },
                  {
                    "color": "green",
                    "value": 1
                  }
                ]
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "up{job=\"smollm-client\"}",
              "legendFormat": "value",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 4,
          "title": "Requests / selected range",
          "description": "Counter increases over the selected window. Very first samples may not have a preceding baseline.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 8,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(increase(local_llm_http_requests_total{job=\"smollm-client\"}[$__range]))",
              "legendFormat": "value",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 5,
          "title": "Valid-request success / selected range",
          "description": "Valid statuses: 200, 429, 502, 504. Input-validation errors are excluded. Idle windows have no success percentage.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * sum(increase(local_llm_http_requests_total{job=\"smollm-client\",status=\"200\"}[$__range])) / sum(increase(local_llm_http_requests_total{job=\"smollm-client\",status=~\"200|429|502|504\"}[$__range]))",
              "legendFormat": "value",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 6,
          "title": "P95 successful request duration",
          "description": "Successful request processing through the gateway, including server queueing. The HTTP response is buffered until complete.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 16,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.95, sum by(le) (rate(local_llm_http_duration_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p95",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 7,
          "title": "P95 first model token",
          "description": "Gateway arrival to first nonempty model stream chunk; includes queueing and prefill. This is not first-byte latency seen by the HTTP caller.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 20,
            "y": 1,
            "w": 4,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.95, sum by(le) (rate(local_llm_first_token_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p95",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 8,
          "title": "HTTP requests by outcome",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 5,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "reqps",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum by(status) (rate(local_llm_http_requests_total{job=\"smollm-client\"}[$__rate_interval]))",
              "legendFormat": "{{status}}",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 9,
          "title": "HTTP failure and admission-rejection rates",
          "description": "Separate backend failures from explicit overload rejection. Zero traffic gives no percentage, not an artificial 100% success.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 5,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * sum(rate(local_llm_http_requests_total{job=\"smollm-client\",status=~\"502|504\"}[$__rate_interval])) / sum(rate(local_llm_http_requests_total{job=\"smollm-client\",status=~\"200|429|502|504\"}[$__rate_interval]))",
              "legendFormat": "5xx / valid requests",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "100 * sum(rate(local_llm_http_requests_total{job=\"smollm-client\",status=\"429\"}[$__rate_interval])) / sum(rate(local_llm_http_requests_total{job=\"smollm-client\",status=~\"200|429|502|504\"}[$__rate_interval]))",
              "legendFormat": "429 / valid requests",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 10,
          "type": "row",
          "title": "Latency, streaming, and reliability",
          "collapsed": false,
          "panels": [],
          "gridPos": {
            "x": 0,
            "y": 13,
            "w": 24,
            "h": 1
          }
        },
        {
          "id": 11,
          "title": "Successful request duration: p50 / p95 / p99",
          "description": "Histogram estimates over the rate window. Low request volume limits percentile precision.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 14,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.5, sum by(le) (rate(local_llm_http_duration_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p50",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "histogram_quantile(0.95, sum by(le) (rate(local_llm_http_duration_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p95",
              "instant": false
            },
            {
              "refId": "C",
              "expr": "histogram_quantile(0.99, sum by(le) (rate(local_llm_http_duration_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p99",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 12,
          "title": "First model token: p50 / p95 / p99",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 14,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.5, sum by(le) (rate(local_llm_first_token_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p50",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "histogram_quantile(0.95, sum by(le) (rate(local_llm_first_token_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p95",
              "instant": false
            },
            {
              "refId": "C",
              "expr": "histogram_quantile(0.99, sum by(le) (rate(local_llm_first_token_seconds_bucket{job=\"smollm-client\"}[$__rate_interval])))",
              "legendFormat": "p99",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 13,
          "title": "OpenLIT SDK duration: p50 / p95 / p99",
          "description": "SDK streaming operation duration; compare with gateway latency for application overhead.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 22,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.5, sum by(le) (rate(gen_ai_client_operation_duration_seconds_bucket{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\"}[$__rate_interval])))",
              "legendFormat": "p50",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "histogram_quantile(0.95, sum by(le) (rate(gen_ai_client_operation_duration_seconds_bucket{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\"}[$__rate_interval])))",
              "legendFormat": "p95",
              "instant": false
            },
            {
              "refId": "C",
              "expr": "histogram_quantile(0.99, sum by(le) (rate(gen_ai_client_operation_duration_seconds_bucket{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\"}[$__rate_interval])))",
              "legendFormat": "p99",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 14,
          "title": "Illustrative fast-success SLI (\u22641 s)",
          "description": "Successful valid requests completed within one second / all valid requests. One second is a lab threshold, not an agreed production SLO.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 22,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * sum(rate(local_llm_http_duration_seconds_bucket{job=\"smollm-client\",le=\"1.0\"}[$__rate_interval])) / sum(rate(local_llm_http_requests_total{job=\"smollm-client\",status=~\"200|429|502|504\"}[$__rate_interval]))",
              "legendFormat": "success within 1 s",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 15,
          "title": "Completion finish reasons",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 30,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "reqps",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum by(finish_reason) (rate(local_llm_completions_total{job=\"smollm-client\"}[$__rate_interval]))",
              "legendFormat": "{{finish_reason}}",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 16,
          "title": "Output capped at max_tokens",
          "description": "Length finish reason means generation reached its output limit. This is distinct from a context-window error.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 30,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * sum(rate(local_llm_completions_total{job=\"smollm-client\",finish_reason=\"length\"}[$__rate_interval])) / sum(rate(local_llm_completions_total{job=\"smollm-client\"}[$__rate_interval]))",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 17,
          "type": "row",
          "title": "Tokens and inference efficiency",
          "collapsed": false,
          "panels": [],
          "gridPos": {
            "x": 0,
            "y": 38,
            "w": 24,
            "h": 1
          }
        },
        {
          "id": 18,
          "title": "Input / output token rate",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 39,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "suffix:tokens/s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum by(gen_ai_token_type) (rate(gen_ai_client_token_usage_sum{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\"}[$__rate_interval]))",
              "legendFormat": "{{gen_ai_token_type}}",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 19,
          "title": "Tokens / selected range",
          "description": "SDK-reported usage. Cached input tokens can differ from newly evaluated prompt tokens at the server.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 39,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum by(gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\"}[$__range]))",
              "legendFormat": "{{gen_ai_token_type}}",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 20,
          "title": "P95 tokens per request",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 47,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.95,sum by(le) (rate(gen_ai_client_token_usage_bucket{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\",gen_ai_token_type=\"input\"}[$__rate_interval])))",
              "legendFormat": "input",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "histogram_quantile(0.95,sum by(le) (rate(gen_ai_client_token_usage_bucket{service_name=\"smollm-client\",gen_ai_request_model=\"smollm2:135m-instruct-q4_K_M\",gen_ai_token_type=\"output\"}[$__rate_interval])))",
              "legendFormat": "output",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 21,
          "title": "Prompt cache hit fraction",
          "description": "Cached prompt tokens / (cached + newly evaluated prompt tokens). Native server counters, weighted over the rate window.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 47,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * sum(rate(llamacpp:prompt_tokens_cached_total{job=\"smollm-model\"}[$__rate_interval])) / (sum(rate(llamacpp:prompt_tokens_cached_total{job=\"smollm-model\"}[$__rate_interval])) + sum(rate(llamacpp:prompt_tokens_total{job=\"smollm-model\"}[$__rate_interval])))",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 22,
          "title": "Throughput while evaluating / decoding",
          "description": "Tokens / CPU inference wall time. Excludes idle time; not equivalent to tokens per second delivered over the entire observation window.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 55,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "suffix:tokens/s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(rate(llamacpp:prompt_tokens_total{job=\"smollm-model\"}[$__rate_interval])) / sum(rate(llamacpp:prompt_seconds_total{job=\"smollm-model\"}[$__rate_interval]))",
              "legendFormat": "prefill",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "sum(rate(llamacpp:tokens_predicted_total{job=\"smollm-model\"}[$__rate_interval])) / sum(rate(llamacpp:tokens_predicted_seconds_total{job=\"smollm-model\"}[$__rate_interval]))",
              "legendFormat": "decode",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 23,
          "title": "Mean decode time per output token",
          "description": "Weighted server decode time / generated tokens, not a per-request latency percentile.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 55,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(rate(llamacpp:tokens_predicted_seconds_total{job=\"smollm-model\"}[$__rate_interval])) / sum(rate(llamacpp:tokens_predicted_total{job=\"smollm-model\"}[$__rate_interval]))",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 24,
          "type": "row",
          "title": "Saturation and resource pressure",
          "collapsed": false,
          "panels": [],
          "gridPos": {
            "x": 0,
            "y": 63,
            "w": 24,
            "h": 1
          }
        },
        {
          "id": 25,
          "title": "Admitted, active, and queued requests",
          "description": "One server slot, at most two admitted requests. Gauges sampled every 15 s may miss very short queue spikes; the 429 counter does not.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 64,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "local_llm_inflight_requests{job=\"smollm-client\"}",
              "legendFormat": "gateway admitted",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "local_llm_admission_capacity{job=\"smollm-client\"}",
              "legendFormat": "gateway capacity",
              "instant": false
            },
            {
              "refId": "C",
              "expr": "llamacpp:requests_processing{job=\"smollm-model\"}",
              "legendFormat": "server active",
              "instant": false
            },
            {
              "refId": "D",
              "expr": "llamacpp:requests_deferred{job=\"smollm-model\"}",
              "legendFormat": "server queue",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 26,
          "title": "Context length high-water mark / 512 tokens",
          "description": "Highest sequence length seen since model start. This is not instantaneous KV-cache occupancy or current memory utilization.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 64,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * llamacpp:n_tokens_max{job=\"smollm-model\"} / 512",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 27,
          "title": "CPU usage / limits",
          "description": "Kubelet cAdvisor pod-level CPU usage, with API-reported application-container limits. Uses the pod aggregate when available to avoid double counting.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 72,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "suffix:cores",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "(sum by(pod) (rate(container_cpu_usage_seconds_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container=\"\"}[$__rate_interval])) or sum by(pod) (rate(container_cpu_usage_seconds_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container!=\"\",container!=\"POD\"}[$__rate_interval])))",
              "legendFormat": "{{pod}} used",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "label_replace(sum by(k8s_pod_name) (k8s_container_cpu_limit{k8s_namespace_name=\"ai-observability\",k8s_pod_name=~\"smollm-(model|client)-.*\",k8s_container_name=~\"model|client\"}), \"pod\", \"$1\", \"k8s_pod_name\", \"(.*)\")",
              "legendFormat": "{{pod}} limit",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 28,
          "title": "Working memory / limits",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 72,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "bytes",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "(sum by(pod) (container_memory_working_set_bytes{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container=\"\"}) or sum by(pod) (container_memory_working_set_bytes{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container!=\"\",container!=\"POD\"}))",
              "legendFormat": "{{pod}} used",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "label_replace(sum by(k8s_pod_name) (k8s_container_memory_limit_bytes{k8s_namespace_name=\"ai-observability\",k8s_pod_name=~\"smollm-(model|client)-.*\",k8s_container_name=~\"model|client\"}), \"pod\", \"$1\", \"k8s_pod_name\", \"(.*)\")",
              "legendFormat": "{{pod}} limit",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 29,
          "title": "CPU throttled periods",
          "description": "Throttled CFS periods / elapsed CFS periods by pod. An idle denominator yields no percentage.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 80,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "100 * (sum by(pod) (rate(container_cpu_cfs_throttled_periods_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container=\"\"}[$__rate_interval])) or sum by(pod) (rate(container_cpu_cfs_throttled_periods_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container!=\"\",container!=\"POD\"}[$__rate_interval]))) / (sum by(pod) (rate(container_cpu_cfs_periods_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container=\"\"}[$__rate_interval])) or sum by(pod) (rate(container_cpu_cfs_periods_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container!=\"\",container!=\"POD\"}[$__rate_interval])))",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 30,
          "title": "OOM events and container restarts",
          "description": "Current cumulative counts. Kubernetes restart gauges can reset when pods are replaced; do not apply counter rate() semantics.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 80,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "(sum by(pod) (container_oom_events_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container=\"\"}) or sum by(pod) (container_oom_events_total{job=\"kubelet-cadvisor\",namespace=\"ai-observability\",pod=~\"smollm-(model|client)-.*\",container!=\"\",container!=\"POD\"}))",
              "legendFormat": "{{pod}} OOM events",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "sum by(k8s_pod_name) (k8s_container_restarts{k8s_namespace_name=\"ai-observability\",k8s_pod_name=~\"smollm-(model|client)-.*\",k8s_container_name=~\"model|client\"})",
              "legendFormat": "{{k8s_pod_name}} restarts",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 31,
          "title": "Deployment desired / available replicas",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 88,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "k8s_deployment_desired{k8s_deployment_name=~\"smollm-(model|client)\"}",
              "legendFormat": "{{k8s_deployment_name}} desired",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "k8s_deployment_available{k8s_deployment_name=~\"smollm-(model|client)\"}",
              "legendFormat": "{{k8s_deployment_name}} available",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 32,
          "title": "Container readiness",
          "description": "Kubernetes readiness from the existing Collector. Missing data is not treated as ready.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 88,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "k8s_container_ready{k8s_namespace_name=\"ai-observability\",k8s_pod_name=~\"smollm-(model|client)-.*\",k8s_container_name=~\"model|client\"}",
              "legendFormat": "{{k8s_pod_name}}",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 33,
          "type": "row",
          "title": "Telemetry health and trace drill-down",
          "collapsed": false,
          "panels": [],
          "gridPos": {
            "x": 0,
            "y": 96,
            "w": 24,
            "h": 1
          }
        },
        {
          "id": 34,
          "title": "Scrape health",
          "description": "Read each target separately. A down metrics pipeline can make business panels empty even while inference still works.",
          "type": "stat",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 97,
            "w": 24,
            "h": 4
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "up{job=~\"smollm-model|smollm-client|openlit|collector-internal|kubelet-cadvisor|tempo\"}",
              "legendFormat": "{{job}}",
              "instant": true
            }
          ],
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "auto"
          }
        },
        {
          "id": 35,
          "title": "Collector accepted telemetry",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 101,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(rate(otelcol_receiver_accepted_spans{receiver=\"otlp\"}[$__rate_interval]))",
              "legendFormat": "spans / s",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "sum(rate(otelcol_receiver_accepted_metric_points{receiver=\"otlp\"}[$__rate_interval]))",
              "legendFormat": "metric points / s",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 36,
          "title": "Collector refused or failed trace delivery",
          "description": "Failure counters may be absent until the first failure. Use scrape health and queue gauges to distinguish uninitialized counters from a missing Collector.",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 101,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(rate(otelcol_receiver_refused_spans{receiver=\"otlp\"}[$__rate_interval]))",
              "legendFormat": "refused spans / s",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "sum(rate(otelcol_exporter_send_failed_spans{exporter=\"otlp/tempo\"}[$__rate_interval]))",
              "legendFormat": "failed sends / s",
              "instant": false
            },
            {
              "refId": "C",
              "expr": "sum(rate(otelcol_exporter_enqueue_failed_spans{exporter=\"otlp/tempo\"}[$__rate_interval]))",
              "legendFormat": "enqueue failures / s",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 37,
          "title": "Trace exporter queue / capacity",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 0,
            "y": 109,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "short",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "otelcol_exporter_queue_size{exporter=\"otlp/tempo\"}",
              "legendFormat": "queued batches",
              "instant": false
            },
            {
              "refId": "B",
              "expr": "otelcol_exporter_queue_capacity{exporter=\"otlp/tempo\"}",
              "legendFormat": "capacity",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 38,
          "title": "Tempo spans received",
          "description": "",
          "type": "timeseries",
          "datasource": {
            "type": "prometheus",
            "uid": "ai-prometheus"
          },
          "gridPos": {
            "x": 12,
            "y": 109,
            "w": 12,
            "h": 8
          },
          "fieldConfig": {
            "defaults": {
              "unit": "suffix:spans/s",
              "decimals": 2,
              "noValue": "No samples",
              "color": {
                "mode": "palette-classic"
              }
            },
            "overrides": []
          },
          "targets": [
            {
              "refId": "A",
              "expr": "sum(rate(tempo_distributor_spans_received_total[$__rate_interval]))",
              "legendFormat": "value",
              "instant": false
            }
          ],
          "options": {
            "legend": {
              "displayMode": "table",
              "placement": "bottom",
              "calcs": [
                "lastNotNull"
              ]
            },
            "tooltip": {
              "mode": "multi"
            }
          }
        },
        {
          "id": 39,
          "title": "Successful and failed inference traces",
          "type": "table",
          "datasource": {
            "type": "tempo",
            "uid": "ai-tempo"
          },
          "gridPos": {
            "x": 0,
            "y": 117,
            "w": 24,
            "h": 9
          },
          "targets": [
            {
              "refId": "A",
              "queryType": "traceql",
              "query": "{ resource.service.name = \"smollm-client\" }",
              "limit": 20,
              "tableType": "traces"
            }
          ],
          "options": {
            "showHeader": true
          },
          "fieldConfig": {
            "defaults": {},
            "overrides": []
          }
        },
        {
          "id": 40,
          "title": "Interpretation and measurement limits",
          "type": "text",
          "gridPos": {
            "x": 0,
            "y": 126,
            "w": 24,
            "h": 5
          },
          "options": {
            "mode": "markdown",
            "content": "Only real local-model traffic is selected. **Idle periods:** no percentile/ratio sample is expected when there are no requests. **TTFT:** first model content chunk at the gateway; HTTP replies are buffered. **Context:** high-water mark, not live KV occupancy. **Limits:** semantic quality, correctness, electricity cost, and true live KV occupancy are not measured. No GPU is allocated and no provider invoice exists. Trace drill-down preserves model and token attributes. Thresholds are lab examples; agree SLOs and workload-specific limits before treating them as production objectives."
          }
        }
      ],
      "templating": {
        "list": []
      }
    }
```

```bash
kubectl --context "$CLUSTER" apply -f dashboard.yaml
```

## 9. Access Grafana and the gateway

In a separate terminal, set the same profile name and leave this running:

```bash
export CLUSTER="llm-lab"  # use the profile name chosen in step 1
kubectl --context "$CLUSTER" -n grafana port-forward svc/grafana-service 3000:3000
```

Open **http://localhost:3000/d/smollm-local**. Username: `admin`. Retrieve the generated password:

```bash
kubectl --context "$CLUSTER" -n grafana get secret grafana-admin \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 --decode
```

In another terminal, leave the gateway forwarding running:

```bash
export CLUSTER="llm-lab"  # use the same profile name
kubectl --context "$CLUSTER" -n ai-observability \
  port-forward svc/smollm-client 8080:8080
```

Send real requests from another terminal. No provider API key or account is needed.

```bash
curl --fail --silent --show-error http://localhost:8080/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Say hello in three words."}' \
  | python3 -m json.tool

curl --fail --silent --show-error http://localhost:8080/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain a Kubernetes pod in one sentence.","max_tokens":1}' \
  | python3 -m json.tool
```

The second request intentionally exercises the output limit with a real inference call: `finish_reason` should be `length`. The response includes actual token usage, `first_token_seconds`, and total processing duration. A very small model is sufficient to validate telemetry, even though response quality is limited.

Allow roughly 30 seconds for OpenLIT export and Prometheus scraping. At low traffic, rate/percentile estimates are sparse. No observations or zero request denominators yield no sample rather than a misleading success percentage. Counters use `increase`/`rate` before aggregation to handle restarts, but first samples without a preceding baseline may not contribute to range increases.

OpenLIT's provider label can read `openai` because the SDK is OpenAI-compatible. The model and network endpoint identify local inference; no OpenAI service is called. Direct requests to the model server bypass gateway/OpenLIT measurements, though native server metrics still count them.

## 10. Verify the entire pipeline

### Kubernetes and reconciliation

```bash
kubectl --context "$CLUSTER" -n ai-observability get deployments,pods,pvc
kubectl --context "$CLUSTER" -n grafana get grafanadatasources,grafanadashboards
kubectl --context "$CLUSTER" -n grafana get grafanadashboard smollm-local -o yaml
```

Expected: all deployments ready, PVCs Bound, exactly one managed dashboard, and `DashboardSynchronized=True`.

### Metrics

On the dashboard, check HTTP 200 traffic, input/output token counts, first-token latency, completion finish reasons, memory/CPU usage, and every scrape-health target. For independent Prometheus checks, forward it in another terminal:

```bash
kubectl --context "$CLUSTER" -n ai-observability \
  port-forward svc/prometheus 9090:9090
```

```bash
curl -fsS -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum(gen_ai_client_token_usage_sum{service_name="smollm-client"})' \
  | python3 -m json.tool

curl -fsS -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=local_llm_first_token_seconds_count' \
  | python3 -m json.tool

curl -fsS -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"smollm-client|smollm-model|openlit|collector-internal|kubelet-cadvisor|tempo"}' \
  | python3 -m json.tool
```

Each scrape-health target should be 1. Kubernetes metric identities vary between versions; the resource queries prefer the cAdvisor pod aggregate where it exists and fall back to container sums, avoiding double counting. Container limit/restart/readiness metrics come from the API through the Collector. Old pod series can linger briefly after a rollout until metric expiry.

### Traces

Use the dashboard's embedded trace table, or Explore → AI Tempo:

```traceql
{ resource.service.name = "smollm-client" }
```

Open a `chat smollm2:135m-instruct-q4_K_M` trace. Check duration, token attributes, and status. Metric collection alone is not proof of successful trace delivery: use the Collector queue/failure panels and Tempo ingest on the same dashboard.

### Input rejection and bounded-admission behavior

A malformed prompt should produce HTTP 400, which is counted separately from valid-request success:

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":""}'
```

Optionally issue a small finite burst of real requests to exercise rejection and queueing. This is a bounded verification, not continuous traffic generation:

Save the following as `verify-burst.py`:

```python
import concurrent.futures
import json
import urllib.error
import urllib.request


def call(_):
    body = json.dumps(
        {"prompt": "Write a short explanation of containers.", "max_tokens": 64}
    ).encode()
    request = urllib.request.Request(
        "http://localhost:8080/chat", body, {"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    print(list(pool.map(call, range(12))))
```

```bash
python3 verify-burst.py
```

Expect successful calls and possibly 429 responses depending on overlap. The rejection counter retains short spikes that a 15-second gauge scrape may miss. Idle gauges/rates should settle when requests stop.

## 11. Persistence, restart, and changes

| Data | PVC | Size | Retention |
| --- | --- | --- | --- |
| Grafana database/settings | `grafana/grafana-pvc` | 1 GiB | Until explicitly deleted |
| Prometheus metrics | `ai-observability/prometheus` | 1 GiB | 24 hours / 512 MB TSDB cap |
| Tempo traces | `ai-observability/tempo` | 2 GiB | 24 hours |
| Model weights | `ai-observability/smollm-model` | 512 MiB | Reused and checksum-verified |

Normal restart:

```bash
minikube stop -p "$CLUSTER"
minikube start -p "$CLUSTER"
kubectl --context "$CLUSTER" -n ai-observability get pods,pvc
kubectl --context "$CLUSTER" -n grafana get pods,pvc
```

Restart port forwards, then make another request. No reinstall or rebuild is necessary for a normal stop/start. The profile retains Kubernetes resources, Secrets, model weights, and the locally built client image. Process counters restart, while historical metrics/traces remain within retention. Deleting the profile deletes that state; repeating this guide recreates the setup, not the deleted data.

For application changes, edit `app.py`, rebuild the client image, and apply `model-gateway.yaml`. Because the local image tag is reused, explicitly restart the client to load the rebuilt image and run OpenLIT injection again:

```bash
minikube -p "$CLUSTER" image build . -t local/smollm-client:1
kubectl --context "$CLUSTER" apply -f model-gateway.yaml
kubectl --context "$CLUSTER" -n ai-observability rollout restart deployment/smollm-client
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/smollm-client --timeout=180s
```

For backend configuration changes, edit `stack.yaml`, apply it, and restart each backend whose ConfigMap changed. For example, after changing the Collector configuration:

```bash
kubectl --context "$CLUSTER" apply -f stack.yaml
kubectl --context "$CLUSTER" -n ai-observability rollout restart deployment/otel-collector
kubectl --context "$CLUSTER" -n ai-observability rollout status deployment/otel-collector --timeout=300s
```

Use the same restart and rollout-status commands for `prometheus` or `tempo` when changing their configuration. For dashboard changes, edit the JSON under `spec.json` in `dashboard.yaml` and run `kubectl --context "$CLUSTER" apply -f dashboard.yaml`; the operator reconciles it without a Grafana restart.

Scale inference down when unused, retaining the model PVC:

```bash
kubectl --context "$CLUSTER" -n ai-observability scale \
  deployment/smollm-model deployment/smollm-client --replicas=0

# Resume:
kubectl --context "$CLUSTER" -n ai-observability scale \
  deployment/smollm-model deployment/smollm-client --replicas=1
```

## 12. Operational response guide

| Symptom | Investigation / response |
| --- | --- |
| Model/client scrape down | Inspect deployment availability, readiness, pod events; restart port forwards after a pod replacement |
| TTFT rising, decode steady | Check server deferred requests, gateway admission, prefill throughput and cache hit fraction; distinguish queue pressure from prompt work |
| Decode throughput drops | Check CPU usage versus limits and CFS throttling; compare token lengths before increasing resources |
| HTTP 429 rising | Admission is full; reduce caller concurrency or intentionally change capacity/slots after checking CPU and memory headroom |
| HTTP 400 / 413 rising | Check prompt/body limits and 512-token context; these are validation failures, not server availability failures |
| Output capped at max_tokens | Check `length` finish fraction and output-token distribution; the lab permits 1–64 generated tokens |
| Memory near limit / OOM / restarts | Inspect pod termination reasons; correlate context/concurrency with working memory before increasing the limit |
| Missing metrics while inference succeeds | Check gateway scrape, `openlit` scrape, injection bootstrap, collector OTLP accepted metrics, and kubelet RBAC errors |
| Missing traces while metrics exist | Check refused spans, exporter enqueue/send failures, queue/capacity, and Tempo scrape/ingest; inspect Collector/Tempo logs |
| First installation stuck | Inspect model download checksum/network access, ServiceAccount/RBAC creation, and PVC binding |

Useful commands:

```bash
kubectl --context "$CLUSTER" -n ai-observability get events --sort-by=.lastTimestamp
kubectl --context "$CLUSTER" -n ai-observability describe pod -l app=smollm-client
kubectl --context "$CLUSTER" -n ai-observability \
  logs deployment/smollm-client --tail=50
kubectl --context "$CLUSTER" -n ai-observability \
  logs deployment/smollm-model -c download-model --tail=30
kubectl --context "$CLUSTER" -n ai-observability \
  logs deployment/otel-collector --tail=50
kubectl --context "$CLUSTER" -n ai-observability logs deployment/tempo --tail=50
```

The dashboard's percentiles depend on histogram bucket resolution and sample volume. Its ratios intentionally remain undefined at zero traffic. Restart gauges should not be treated as monotonic counters. Model context high-water mark is not live KV usage. Semantic correctness, evaluation scores, electricity costs, and true live KV-cache occupancy need additional measurement; they are not inferred from latency or tokens.

## Conclusion

We now have a real LLM running on a local CPU, with metrics and traces staying on the same minikube cluster. I can see how long requests take, how quickly tokens arrive, where requests queue up, and how much CPU and memory the model uses. When something slows down, there’s enough detail to investigate it and compare what happens after changing a limit or sending more traffic. The model is tiny and this won’t tell me whether its answers are any good, but it gives me a useful local lab for learning how inference behaves under load, without a GPU or a provider account.

## References

- [Grafana zero-code AI observability architecture](https://grafana.com/blog/ai-observability-zero-code/)
- [Grafana Operator release](https://github.com/grafana/grafana-operator/releases/tag/v5.25.0)
- [OpenLIT telemetry to Prometheus and Tempo](https://docs.openlit.io/latest/sdk/destinations/prometheus-tempo)
- [llama.cpp CPU container images](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- [llama.cpp server metrics and API](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Collector Kubernetes cluster receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.161.0/receiver/k8sclusterreceiver)
