#!/usr/bin/env bash
# Local Linux/macOS observability sandbox. Run as your normal Docker-enabled user.
# Host prerequisites: Docker and Bash 3.2+. Missing minikube, kubectl, Helm,
# Python/venv and curl are bootstrapped by default. Linux requires an NVIDIA
# driver and NVIDIA Container Toolkit configured for Docker. macOS runs without GPU.
# This does not install host drivers, change Docker configuration, or delete clusters.
# Defaults resolve latest stable upstream releases AND latest stable Helm charts.
# Override *_VERSION / *_CHART_VERSION to reproduce a previous installation.
# References:
# https://minikube.sigs.k8s.io/docs/tutorials/nvidia/
# https://opentelemetry.io/docs/platforms/kubernetes/helm/collector/
# https://github.com/openlit/openlit
# https://github.com/grafana-community/helm-charts
# Usage: ./01-llm-obs-setup.sh
# Preview: RENDER_ONLY=1 ./01-llm-obs-setup.sh
# Data is local PVC storage; deleting the minikube profile deletes the data.
set -Eeuo pipefail
umask 077
HOST_OS=$(uname -s)
case "$HOST_OS" in
  Linux) GPU_ENABLED=1 ;;
  Darwin) GPU_ENABLED=0 ;;
  *) printf 'Unsupported OS: %s. Use Linux or macOS.\n' "$HOST_OS" >&2; exit 1 ;;
esac
printf 'Detected %s; Kubernetes GPU support: %s\n' "$HOST_OS" "$GPU_ENABLED"
if [[ $HOST_OS == Darwin ]]; then
  printf 'macOS: running the observability stack without GPU passthrough.\n'
fi
PROFILE=${PROFILE:-llm-obs}
NAMESPACE=${NAMESPACE:-llm-obs}
CPUS=${CPUS:-4}
MEMORY=${MEMORY:-8192}
GRAFANA_PORT=${GRAFANA_PORT:-3000}
OPENLIT_PORT=${OPENLIT_PORT:-3001}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT:-4317}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT:-4318}
STATE_DIR=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llm-obs/$PROFILE}
TIMEOUT=${TIMEOUT:-15m}
RENDER_ONLY=${RENDER_ONLY:-0} # Download charts and render manifests; no cluster/SDK changes.
mkdir -p "$STATE_DIR"
STATE_DIR=$(cd "$STATE_DIR" && pwd)
trap 'printf "Failed at line %s. Generated configuration: %s\n" "$LINENO" "$STATE_DIR" >&2' ERR
fail() { printf '%s\n' "$*" >&2; exit 1; }
# Install missing CLI dependencies. Docker and Linux NVIDIA setup remain host prerequisites.
BOOTSTRAP=${BOOTSTRAP:-1}
INSTALL_BIN=${INSTALL_BIN:-$HOME/.local/bin}
# Find binaries installed by an earlier run even if the login shell PATH was not updated.
if [[ $HOST_OS == Linux ]]; then
  export PATH="$PATH:$INSTALL_BIN"
fi
package_index_updated=0
as_root() {
  if [[ $EUID == 0 ]]; then "$@"; else
    command -v sudo >/dev/null || fail 'Installing system packages requires sudo.'
    sudo "$@"
  fi
}
linux_packages() {
  if command -v apt-get >/dev/null; then
    if [[ $package_index_updated == 0 ]]; then as_root apt-get update; package_index_updated=1; fi
    as_root apt-get install -y "$@"
  elif command -v dnf >/dev/null; then
    as_root dnf install -y "$@"
  else
    fail 'Automatic system package installation supports apt-get/dnf. Install Python 3.10+ with venv, curl, and CA certificates manually, then rerun.'
  fi
}
python_ready() {
  command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3,10))' 2>/dev/null
}
brew_dependency() {
  command -v brew >/dev/null || fail 'Install Homebrew (https://brew.sh/) to bootstrap missing macOS tools, then rerun.'
  if [[ $1 == python ]] && brew list --versions python >/dev/null 2>&1; then
    brew upgrade python
  else
    brew install "$1"
  fi
  PATH="$(brew --prefix)/bin:$PATH"
  export PATH
  hash -r
}
verify_sha256() {
  python3 - "$1" "$2" <<'PYSHA'
import hashlib,pathlib,sys
file,checksum=map(pathlib.Path,sys.argv[1:])
expected=checksum.read_text().split()[0].lower()
h=hashlib.sha256()
with file.open('rb') as f:
    for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
if h.hexdigest()!=expected: raise SystemExit(f'SHA256 verification failed: {file}')
PYSHA
}
bootstrap_dependencies() {
  local tool arch download_dir version
  if [[ $HOST_OS == Darwin ]]; then
    if ! command -v curl >/dev/null; then brew_dependency curl; fi
    if ! python_ready; then brew_dependency python; fi
  else
    if ! command -v curl >/dev/null; then linux_packages curl ca-certificates; fi
    if ! python_ready; then linux_packages python3; fi
  fi
  python_ready || fail 'Python 3.10+ is required. Install a supported Python release and put it first in PATH.'
  # A Python executable alone is insufficient on distributions packaging venv separately.
  if ! python3 -m venv "$STATE_DIR/bootstrap-venv-check" >/dev/null 2>&1; then
    if [[ $HOST_OS == Darwin ]]; then
      fail 'Python venv support is unavailable. Repair your Python/Homebrew installation, then rerun.'
    elif command -v apt-get >/dev/null; then
      linux_packages python3-venv
    else
      linux_packages python3-pip
    fi
    python3 -m venv "$STATE_DIR/bootstrap-venv-check" || fail 'Python venv/pip support is still unavailable.'
  fi
  "$STATE_DIR/bootstrap-venv-check/bin/python" -m pip --version >/dev/null || fail 'Python venv must include pip.'
  rm -rf "$STATE_DIR/bootstrap-venv-check"
  if [[ $HOST_OS == Darwin ]]; then
    for tool in minikube kubectl helm; do
      if command -v "$tool" >/dev/null; then
        printf 'Using installed %s: %s\n' "$tool" "$(command -v "$tool")"
      elif [[ $tool == kubectl ]]; then brew_dependency kubernetes-cli
      else brew_dependency "$tool"
      fi
    done
    return
  fi
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) fail 'Automatic Linux CLI downloads support x86_64 and ARM64.' ;;
  esac
  mkdir -p "$INSTALL_BIN" "$STATE_DIR/bootstrap"
  download_dir="$STATE_DIR/bootstrap"
  # Preserve installed tools on PATH; only add INSTALL_BIN when placing a missing tool.
  for tool in minikube kubectl helm; do
    if command -v "$tool" >/dev/null; then
      printf 'Using installed %s: %s\n' "$tool" "$(command -v "$tool")"
      continue
    fi
    printf 'Installing missing %s into %s\n' "$tool" "$INSTALL_BIN"
    case "$tool" in
      minikube)
        curl -fsSL --retry 3 "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-$arch" -o "$download_dir/minikube"
        curl -fsSL --retry 3 "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-$arch.sha256" -o "$download_dir/minikube.sha256"
        verify_sha256 "$download_dir/minikube" "$download_dir/minikube.sha256"
        install -m 755 "$download_dir/minikube" "$INSTALL_BIN/minikube"
        ;;
      kubectl)
        version=$(curl -fsSL --retry 3 https://dl.k8s.io/release/stable.txt)
        [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid kubectl release: $version"
        curl -fsSL --retry 3 "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl" -o "$download_dir/kubectl"
        curl -fsSL --retry 3 "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl.sha256" -o "$download_dir/kubectl.sha256"
        verify_sha256 "$download_dir/kubectl" "$download_dir/kubectl.sha256"
        install -m 755 "$download_dir/kubectl" "$INSTALL_BIN/kubectl"
        ;;
      helm)
        version=$(curl -fsSL --retry 3 https://api.github.com/repos/helm/helm/releases/latest |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
        [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid Helm release: $version"
        curl -fsSL --retry 3 "https://get.helm.sh/helm-$version-linux-$arch.tar.gz" -o "$download_dir/helm.tar.gz"
        curl -fsSL --retry 3 "https://get.helm.sh/helm-$version-linux-$arch.tar.gz.sha256sum" -o "$download_dir/helm.sha256"
        verify_sha256 "$download_dir/helm.tar.gz" "$download_dir/helm.sha256"
        tar -xzf "$download_dir/helm.tar.gz" -C "$download_dir" "linux-$arch/helm"
        install -m 755 "$download_dir/linux-$arch/helm" "$INSTALL_BIN/helm"
        ;;
    esac
    export PATH="$INSTALL_BIN:$PATH"
    hash -r
  done
  printf 'For future shells, include %s in PATH.\n' "$INSTALL_BIN"
}
# Preview must remain free of package/CLI installations.
if [[ $BOOTSTRAP == 1 && $RENDER_ONLY != 1 ]]; then bootstrap_dependencies; fi
for command in helm curl python3; do
  command -v "$command" >/dev/null || fail "Missing prerequisite: $command"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else "Python 3.10+ is required")'
if [[ $RENDER_ONLY != 1 ]]; then
  minikube version --short | python3 -c 'import re,sys; m=re.search(r"v?(\d+)\.(\d+)",sys.stdin.read()); sys.exit(0 if m and tuple(map(int,m.groups())) >= (1,32) else "minikube 1.32+ required; update your installed minikube")'
  helm version --short | python3 -c 'import re,sys; m=re.search(r"v?(\d+)\.",sys.stdin.read()); sys.exit(0 if m and int(m[1]) >= 3 else "Helm 3+ required; update your installed Helm")'
fi
[[ $PROFILE =~ ^[a-z][a-z0-9-]*$ && $NAMESPACE =~ ^[a-z][a-z0-9-]*$ ]] || fail 'Use DNS labels for PROFILE and NAMESPACE.'
python3 - "$GRAFANA_PORT" "$OPENLIT_PORT" "$OTLP_GRPC_PORT" "$OTLP_HTTP_PORT" <<'PY'
import sys
ports = [int(p) for p in sys.argv[1:]]
assert len(set(ports)) == len(ports) and all(1024 <= p <= 65535 for p in ports), 'Ports must be distinct and in 1024..65535'
PY
latest() {
  local repository=$1
  curl --fail --silent --show-error --retry 3 "https://api.github.com/repos/$repository/releases/latest" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].removeprefix("v"))'
}
# Resolve once per invocation and record exact versions for review/reproduction.
LOKI_VERSION=${LOKI_VERSION:-$(latest grafana/loki)}
TEMPO_VERSION=${TEMPO_VERSION:-$(latest grafana/tempo)}
GRAFANA_VERSION=${GRAFANA_VERSION:-$(latest grafana/grafana)}
OTEL_VERSION=${OTEL_VERSION:-$(latest open-telemetry/opentelemetry-collector-releases)}
OPENLIT_VERSION=${OPENLIT_VERSION:-$(curl --fail --silent --show-error --retry 3 'https://api.github.com/repos/openlit/openlit/releases?per_page=100' |
  python3 -c 'import json,re,sys; print(next(r["tag_name"].removeprefix("openlit-") for r in json.load(sys.stdin) if not r["prerelease"] and not r["draft"] and re.fullmatch(r"openlit-[0-9]+\.[0-9]+\.[0-9]+",r["tag_name"])))')}
PROMETHEUS_VERSION=${PROMETHEUS_VERSION:-$(latest prometheus/prometheus)}
for version in "$LOKI_VERSION" "$TEMPO_VERSION" "$GRAFANA_VERSION" "$OTEL_VERSION" "$OPENLIT_VERSION" "$PROMETHEUS_VERSION"; do
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Expected stable semver, got: $version"
done
helm repo add llm-grafana https://grafana-community.github.io/helm-charts --force-update
helm repo add llm-otel https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm repo add llm-openlit https://openlit.github.io/helm/ --force-update
helm repo update
chart_version() {
  helm search repo "$1" --versions -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["version"])'
}
LOKI_CHART_VERSION=${LOKI_CHART_VERSION:-$(chart_version llm-grafana/loki)}
TEMPO_CHART_VERSION=${TEMPO_CHART_VERSION:-$(chart_version llm-grafana/tempo)}
GRAFANA_CHART_VERSION=${GRAFANA_CHART_VERSION:-$(chart_version llm-grafana/grafana)}
OTEL_CHART_VERSION=${OTEL_CHART_VERSION:-$(chart_version llm-otel/opentelemetry-collector)}
OPENLIT_CHART_VERSION=${OPENLIT_CHART_VERSION:-$(chart_version llm-openlit/openlit)}
for name in LOKI TEMPO GRAFANA OTEL OPENLIT PROMETHEUS; do
  var=${name}_VERSION; printf '%s=%s\n' "$var" "${!var}"
  if [[ $name != PROMETHEUS ]]; then
    var=${name}_CHART_VERSION; printf '%s=%s\n' "$var" "${!var}"
  fi
done | tee "$STATE_DIR/versions.env"
cat > "$STATE_DIR/loki.yaml" <<EOF
fullnameOverride: loki
deploymentMode: Monolithic
loki:
  image:
    tag: "$LOKI_VERSION"
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    allow_structured_metadata: true
    retention_period: 24h
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 8
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  sidecar: false
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: "1", memory: 768Mi}
  persistence:
    enabled: true
    size: 2Gi
read: {replicas: 0}
write: {replicas: 0}
backend: {replicas: 0}
gateway: {enabled: false}
lokiCanary: {enabled: false}
test: {enabled: false}
chunksCache: {enabled: false}
resultsCache: {enabled: false}
minio: {enabled: false}
EOF
cat > "$STATE_DIR/tempo.yaml" <<EOF
fullnameOverride: tempo
replicas: 1
tempo:
  tag: "$TEMPO_VERSION"
  reportingEnabled: false
  retention: 24h
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: "1", memory: 768Mi}
  receivers:
    jaeger:
      protocols:
        grpc: null
        thrift_binary: null
        thrift_compact: null
        thrift_http: null
    otlp:
      protocols:
        grpc: {endpoint: "0.0.0.0:4317"}
        http: {endpoint: "0.0.0.0:4318"}
persistence:
  enabled: true
  size: 2Gi
EOF
cat > "$STATE_DIR/openlit.yaml" <<EOF
fullnameOverride: openlit
replicaCount: 1
image:
  tag: "$OPENLIT_VERSION"
service: {type: ClusterIP}
extraEnv:
  - {name: OPENLIT_EDITION, value: ce}
resources:
  requests: {cpu: 100m, memory: 256Mi}
  limits: {cpu: "1", memory: 1Gi}
persistence:
  enabled: true
  size: 1Gi
config:
  usageMetrics: false
  database:
    host: "openlit-db.$NAMESPACE.svc.cluster.local"
clickhouse:
  persistence: {size: 3Gi}
  resources:
    requests: {cpu: 100m, memory: 512Mi}
    limits: {cpu: "1", memory: 1536Mi}
openlit-controller: {enabled: false}
EOF
# One standalone contrib Collector handles all three signals. OpenLIT's platform
# chart also runs its own embedded ingestion process; it is not another pod.
cat > "$STATE_DIR/otel.yaml" <<'EOF'
fullnameOverride: otel
mode: deployment
replicaCount: 1
image:
  repository: otel/opentelemetry-collector-contrib
command:
  name: otelcol-contrib
resources:
  requests: {cpu: 100m, memory: 128Mi}
  limits: {cpu: 500m, memory: 256Mi}
# Node container log files require root read access; mounts are read-only.
securityContext:
  runAsUser: 0
  runAsGroup: 0
presets:
  logsCollection:
    enabled: true
    includeCollectorLogs: false
  kubernetesAttributes:
    enabled: true
  kubeletMetrics:
    enabled: true
ports:
  jaeger-compact: {enabled: false}
  jaeger-thrift: {enabled: false}
  jaeger-grpc: {enabled: false}
  zipkin: {enabled: false}
  prometheus:
    enabled: true
    containerPort: 8889
    servicePort: 8889
    protocol: TCP
# alternateConfig avoids inheriting unwanted default receivers/exporters/pipelines.
# Chart presets still add the filelog receiver, mounts and Kubernetes RBAC.
alternateConfig:
  extensions:
    health_check: {endpoint: "0.0.0.0:13133"}
  receivers:
    kubeletstats:
      collection_interval: 15s
      auth_type: serviceAccount
      endpoint: "${env:OTEL_K8S_NODE_IP}:10250"
      insecure_skip_verify: true # Local minikube kubelet uses a self-signed cert.
      metric_groups: [pod]
      metrics:
        k8s.pod.cpu.usage: {enabled: true}
    otlp:
      protocols:
        grpc: {endpoint: "0.0.0.0:4317"}
        http: {endpoint: "0.0.0.0:4318"}
  processors:
    memory_limiter:
      check_interval: 1s
      limit_mib: 192
      spike_limit_mib: 48
    batch:
      timeout: 2s
      send_batch_size: 256
  exporters:
    otlp/tempo:
      endpoint: tempo:4317
      tls: {insecure: true}
    otlphttp/loki:
      endpoint: http://loki:3100/otlp
    otlphttp/openlit:
      endpoint: http://openlit:4318
    prometheus:
      endpoint: "0.0.0.0:8889"
      resource_to_telemetry_conversion: {enabled: true}
      enable_open_metrics: true
  service:
    extensions: [health_check]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo, otlphttp/openlit]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlphttp/loki, otlphttp/openlit]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheus, otlphttp/openlit]
EOF
cat > "$STATE_DIR/prometheus.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: prometheus}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: prometheus-discovery}
rules:
  - apiGroups: ['']
    resources: [pods]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: prometheus-discovery}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: prometheus-discovery}
subjects:
  - {kind: ServiceAccount, name: prometheus, namespace: $NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: prometheus}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: agents
        static_configs:
          - targets: ['otel:8889']
      # Opt in model servers/exporters in this namespace. Only the named metrics
      # container port is selected, so multi-port pods aren't scraped twice.
      - job_name: inference
        kubernetes_sd_configs:
          - role: pod
            namespaces: {names: ['$NAMESPACE']}
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: 'true'
          - source_labels: [__meta_kubernetes_pod_phase]
            action: keep
            regex: Running
          - source_labels: [__meta_kubernetes_pod_container_port_name]
            action: keep
            regex: metrics
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            target_label: __metrics_path__
            regex: '(.+)'
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: prometheus}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 1Gi}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: prometheus}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: prometheus}
  template:
    metadata:
      labels: {app: prometheus}
    spec:
      serviceAccountName: prometheus
      securityContext: {runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534}
      containers:
        - name: prometheus
          image: prom/prometheus:v$PROMETHEUS_VERSION
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=1d
            - --storage.tsdb.retention.size=512MB
          ports: [{name: http, containerPort: 9090}]
          readinessProbe:
            httpGet: {path: /-/ready, port: http}
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {cpu: 500m, memory: 384Mi}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
            - {name: data, mountPath: /prometheus}
      volumes:
        - name: config
          configMap: {name: prometheus}
        - name: data
          persistentVolumeClaim: {claimName: prometheus}
---
apiVersion: v1
kind: Service
metadata: {name: prometheus}
spec:
  selector: {app: prometheus}
  ports: [{name: http, port: 9090, targetPort: http}]
EOF
cat > "$STATE_DIR/grafana.yaml" <<'EOF'
fullnameOverride: grafana
replicas: 1
deploymentStrategy: {type: Recreate}
image:
  repository: grafana/grafana
admin:
  existingSecret: grafana-admin
  userKey: admin-user
  passwordKey: admin-password
resources:
  requests: {cpu: 100m, memory: 256Mi}
  limits: {cpu: 500m, memory: 1Gi}
persistence:
  enabled: true
  size: 1Gi
initChownData: {enabled: false}
grafana.ini:
  analytics:
    reporting_enabled: false
    check_for_updates: false
  users:
    default_theme: dark
  dashboards:
    default_home_dashboard_path: /var/lib/grafana/dashboards/inference/inference.json
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: inference
        orgId: 1
        folder: LLM Inference
        type: file
        disableDeletion: false
        editable: false
        updateIntervalSeconds: 30
        options:
          path: /var/lib/grafana/dashboards/inference
dashboardsConfigMaps:
  inference: llm-inference-dashboard
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki:3100
        jsonData:
          derivedFields:
            - name: TraceID
              matcherRegex: '"trace_id"\s*:\s*"([0-9a-fA-F]{32})"'
              datasourceUid: tempo
              url: '$${__value.raw}'
      - name: Tempo
        uid: tempo
        type: tempo
        access: proxy
        url: http://tempo:3200
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: '-5m'
            spanEndTimeShift: '5m'
            tags: [{key: service.name, value: service_name}]
            filterByTraceID: true
            filterBySpanID: false
          nodeGraph: {enabled: true}
EOF
# Keep dashboard generation inline so downloading this script alone still works.
python3 - "$STATE_DIR" "$NAMESPACE" <<'PYDASHBOARD'
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
namespace = sys.argv[2]
ds = {'type': 'prometheus', 'uid': 'prometheus'}
panels = []
y = 0
engine_filter = 'model_name=~"${model:regex}",pod=~"${pod:regex}"'
stage_filter = 'model_name=~"${model:regex}",service_name=~"${service:regex}"'

def metric(name, extra=''):
    labels = engine_filter + (',' + extra if extra else '')
    # vLLM's colon names stay intact; other runtimes can implement the documented
    # llm_inference_* contract. Match series before aggregating across replicas.
    return f'(vllm:{name}{{{labels}}} or llm_inference_{name}{{{labels}}})'

def rate(name, extra=''):
    labels = engine_filter + (',' + extra if extra else '')
    return (f'(rate(vllm:{name}{{{labels}}}[$__rate_interval]) or '
            f'rate(llm_inference_{name}{{{labels}}}[$__rate_interval]))')

def history(name, labels=engine_filter):
    return (f'(last_over_time(vllm:{name}{{{labels}}}[$__range]) or '
            f'last_over_time(llm_inference_{name}{{{labels}}}[$__range]))')

def quantile(name, q=.95):
    return f'histogram_quantile({q}, sum by (le,model_name) ({rate(name + "_bucket")}))'

def mean(name):
    return f'sum by (model_name) ({rate(name + "_sum")}) / sum by (model_name) ({rate(name + "_count")})'

def stage_rate(suffix, stage):
    return f'rate(llm_inference_stage_{suffix}{{{stage_filter},stage="{stage}"}}[$__rate_interval])'

def stage_quantile(stage, q):
    return f'histogram_quantile({q}, sum by (le,model_name) ({stage_rate("duration_seconds_bucket", stage)}))'

def add(title, queries=(), unit='short', description='', kind='timeseries', x=0, w=12, h=8, content=None):
    p = {'id': len(panels)+1, 'title': title, 'type': kind,
         'gridPos': {'x': x, 'y': y, 'w': w, 'h': h}, 'description': description}
    if kind == 'text':
        p['options'] = {'mode': 'markdown', 'content': content}
    else:
        p['datasource'] = ds
        p['targets'] = [{'refId': chr(65+i), 'expr': expr, 'legendFormat': label,
                         'range': True, 'datasource': ds} for i, (label, expr) in enumerate(queries)]
        p['fieldConfig'] = {'defaults': {'unit': unit, 'min': 0, 'noValue': 'No telemetry',
            'color': {'mode': 'palette-classic'}, 'custom': {'drawStyle': 'line', 'lineWidth': 2,
            'fillOpacity': 8, 'spanNulls': False}, 'thresholds': {'mode': 'absolute',
            'steps': [{'color': 'green', 'value': None}]}}, 'overrides': []}
        p['options'] = {'legend': {'displayMode': 'table', 'placement': 'bottom', 'calcs': ['mean', 'max']},
                        'tooltip': {'mode': 'multi', 'sort': 'desc'}}
        if kind == 'stat':
            p['options'] = {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '', 'values': False},
                            'colorMode': 'value', 'graphMode': 'area', 'textMode': 'auto'}
    panels.append(p)
    return p

article_url = 'https://adykaaa.github.io/blog/llm-platform-engineering-1-inference-overview/'
section_guides = {
    '00': ('Reading the request path', 'inference', '''### Follow one request through the system
Inference runs learned model weights to predict output tokens. The request passes through tokenization, embedding lookup, prefill and repeated decode steps, while the KV cache preserves reusable attention state. A slow answer can come from any of these stages or from queueing and transport.

**Read latency together with workload.** Prompt length, generated length, request rate and concurrency change the amount of work. Compare p50 (typical), p95 and p99 (tail); histogram percentiles are estimates and cannot be added to reconstruct a request. Use a trace for the timing breakdown of one request.

**Check coverage first.** A successful scrape proves an endpoint is reachable. Empty phase charts indicate missing measurements or no observations in that window; they do not demonstrate zero-cost inference.'''),
    '01': ('Tokenization and CPU work', 'tokenization-and-embeddings', '''### Turn text into token IDs
The article's `Hello, how are you?` example becomes six token IDs. A token can be a word fragment, punctuation or whitespace-related unit. Token counts therefore describe model work more accurately than word counts.

Tokenizers usually perform CPU work: string processing, branching and vocabulary lookups. Longer prompts can increase tokenizer time before GPU execution begins. Compare tokenizer latency and tokenized tokens/s with the CPU tile to spot possible contention; CPU activity also includes HTTP handling, scheduling and other processes.

**CPU scope:** the tile and CPU history follow the Pod filter. All includes the sandbox namespace's observability pods. Model and Service do not filter CPU. One core is one fully busy logical CPU; it is not a percentage of a pod's CPU limit.'''),
    '02': ('Embedding lookup and model weights', 'tokenization-and-embeddings', '''### Look up learned vectors before attention
Each token ID selects a row in the model's learned input embedding table. Qwen2.5-0.5B uses 896-dimensional vectors. The article's `151,936 × 896 × 2 bytes` example requires about 260 MiB for this table at two bytes per parameter. It is part of model weights, not per-request KV storage.

The same token starts with the same input embedding; attention and the Q/K/V projections then build context-dependent representations. Here we measure that internal lookup, separate from semantic-search embedding APIs.

**Read timings carefully.** The lookup can already be included in prefill/decode timings, so do not add it again. GPU wall timers need completed CUDA work to measure execution. A missing explicit timer means the lookup has not been measured separately.'''),
    '03': ('Prefill and the first-token wait', 'prefill', '''### Process the known context and populate the cache
During prefill, prompt positions are already known and much of their work can run in parallel while causal attention still restricts each position to itself and earlier tokens. The model computes attention state, fills K/V storage, and produces the first output token. Reusing weights across many positions often makes prefill compute-bound.

**TTFT covers more than pure prefill.** Tokenization, scheduling, queueing and transport can contribute, depending on the measurement boundary. Compare prompt length, uncached KV tokens, queue time and prefill duration before blaming GPU compute.

A prefix hit can reduce actual prefill work even when the full prompt length stays the same. Tokens per engine iteration reveals scheduled work and batching, including mixed prefill/decode iterations; it is not a request batch-size count.'''),
    '04': ('Decode and streaming speed', 'decode', '''### Generate subsequent tokens autoregressively
The next token depends on prior output. Each decode step processes new input state, reads previous K/V entries and extends the cache. Weight and context reads recur with less weight reuse per position than in a large prefill batch, so memory bandwidth often matters. Larger batches and workload shape can change the limiting resource.

The article's **50 ms per output token ≈ 20 tokens/s** describes one stream after its first token. Fleet token throughput combines concurrent streams and cannot be read as per-user speed. Longer outputs also increase total decode duration without necessarily increasing per-token latency.

Compare TPOT, inter-token latency, output length and length-limited finishes. TPOT is sampled per request; ITL is sampled per output event, and one event can contain multiple tokens. Use the client section to see delivery cadence experienced across the network.'''),
    '05': ('Why cache only keys and values?', 'kv-cache', '''### Preserve attention state instead of recomputing the past
The current Query describes information the new token seeks. Prior Keys are matched against it, and prior Values carry the information mixed by attention. Future tokens reuse those earlier K/V vectors; they do not need earlier Queries or attention Outputs. The cache stores K and V for each relevant layer and token position.

Prefill populates the prompt state. Decode reads that state and adds newly processed positions. Longer contexts and more concurrent sequences consume more cache capacity and increase attention memory traffic. Prefix sharing can reduce duplicate work when matching token prefixes remain reusable.

Use occupancy/headroom for pressure, hit and miss token rates for reuse, preemptions for interrupted work, and optional block lifetime/idle/reuse-gap histograms for eviction behavior. These metrics expose cache behavior and configuration; they do not display the numerical K/V tensors.'''),
    '06': ('Compute, capacity and memory bandwidth', 'cores-and-memory-bandwidth', '''### Keep the GPU's three constraints separate
The article distinguishes arithmetic throughput, VRAM capacity and memory bandwidth. Weights must fit, and active requests need room for K/V state and other runtime tensors. A large prefill can reuse weights across many positions; decode repeatedly accesses weights and an expanding context.

**Utilization does not measure TFLOPS.** A busy GPU can still spend time waiting on memory. Used/free framebuffer counters describe capacity, while DRAM activity describes the fraction of cycles with memory-interface traffic, not actual GB/s. Correlate these with prefill, TPOT, context length and batching.

These panels require an annotated NVIDIA DCGM exporter; profiling fields also depend on GPU support and exporter configuration. All hardware charts cover the sandbox namespace independently of model selection. Missing exporter data means unmeasured hardware signals.'''),
    '07': ('What the user actually waits for', 'inference', '''### Compare server execution with client experience
A long first-token wait feels like a frozen request; slow follow-up delivery feels like hesitant generation. The server panels explain inference work, while client operation duration and streaming chunk timings include transport, buffering and provider/client overhead.

Client time to first chunk is an end-user observation, distinct from the engine's own TTFT boundary. Gaps between delivered chunks can differ from TPOT because chunks can bundle tokens or arrive in bursts. Streaming metrics appear only when streaming calls are instrumented.

Client and engine token measurements describe different observation points. Keep them separate when estimating workload; adding them would count the same inference twice. Use a correlated Tempo trace and Loki logs to investigate an individual outlier.'''),
}
section_context = {
    '00': 'Inference predicts tokens using fixed learned weights. Request length, output length, queueing and concurrency all affect observed latency; inspect them together.',
    '01': 'Tokenization usually runs on the CPU and converts text into token IDs. Rising latency can reflect longer inputs or CPU contention; whole-pod CPU also includes scheduling and HTTP work.',
    '02': 'Internal embeddings are learned weight-table lookups. They feed attention, which builds context-dependent Q/K/V representations. Lookup timing can overlap full prefill/decode accounting.',
    '03': 'Prefill processes uncached input context, populates K/V state and produces the first output token. It often benefits from GPU compute parallelism; TTFT also includes waiting and other overhead.',
    '04': 'Decode generates tokens sequentially while reading existing K/V state. Context length, batching and memory bandwidth affect per-token speed; output length affects total duration.',
    '05': 'K/V state trades repeated computation for memory capacity and traffic. More context and concurrency increase demand; matching retained prefixes can be reused across requests.',
    '06': 'GPU compute, capacity and bandwidth are distinct limits. Activity ratios and VRAM counters are evidence to correlate with latency, not standalone proof of a bottleneck.',
    '07': 'Client observations include network and delivery behavior. Streaming chunk cadence and server token timing have different measurement boundaries.',
}

def row(title):
    global y
    panels.append({'id': len(panels)+1, 'title': title, 'type': 'row', 'collapsed': False,
                   'gridPos': {'x': 0, 'y': y, 'w': 24, 'h': 1}, 'panels': []})
    y += 1
    section = section_guides[title[:2]]
    guide(section[0], section[2] + '\n\n[Read Part 1 · ' + section[0] + '](' + article_url + '#' + section[1] + ')', h=10)

def guide(title, content, h=6):
    global y
    add(title, kind='text', w=24, h=h, content=content)
    y += h

add('Inference, from prompt to output', kind='text', w=24, h=6, content='''### Tokenize → Embed → Prefill → Decode ↔ KV cache
**Start with the latency cards, then follow the numbered stages.** Use Model / Pod for engine metrics and Service for explicit stage timers and client telemetry. CPU follows the Pod filter (All = the sandbox namespace), independently of Model / Service. GPU and scrape-health panels cover the namespace.

**No telemetry means unmeasured, never zero.** This setup does not install a model. Connect a vLLM `/metrics` endpoint (annotated pod, named `metrics` port) and use `inference_metrics.py` for tokenization / internal embedding timing. Client OpenLIT data is shown separately below. After removing a workload, select its historical model/pod and a time range containing its requests.''')
y += 6
for i, (title, name, unit, desc) in enumerate([
    ('TTFT · p95', 'time_to_first_token_seconds', 's', 'Server time to first token includes queueing and prefill. It is not pure prefill time.'),
    ('TPOT · p95', 'request_time_per_output_token_seconds', 's', 'Per-request time per output token after the first. ITL is shown separately; batching and speculative decoding can make them differ.'),
    ('End-to-end · p95', 'e2e_request_latency_seconds', 's', 'Request arrival to final token at the server; compare with the client view below.'),
]):
    add(title, [('{{model_name}}', quantile(name))], unit, desc, 'stat', x=i*6, w=6, h=4)
add('Output tokens / second', [('{{model_name}}', f'sum by (model_name) ({rate("generation_tokens_total")})')],
    'tps', 'Aggregate output throughput across selected replicas, not per-user generation speed.', 'stat', x=18, w=6, h=4)
y += 4
row('00 / Signal coverage & request pressure')
coverage = [('Tokenization', f'count(llm_inference_stage_duration_seconds_count{{{stage_filter},stage="tokenization"}})'),
            ('Embedding lookup', f'count(llm_inference_stage_duration_seconds_count{{{stage_filter},stage="embedding"}})'),
            ('Prefill', f'count({metric("request_prefill_time_seconds_count")})'),
            ('Decode', f'count({metric("request_decode_time_seconds_count")})'),
            ('KV cache', f'count(({metric("kv_cache_usage_perc")} or {metric("gpu_cache_usage_perc")}))')]
coverage_panel = add('Measured signals · series present', coverage, description='Counts series, not requests. Missing stages display No telemetry. Requires at least one measurement for a timer.', kind='stat', w=24, h=4)
coverage_panel['options'].update({'colorMode': 'none', 'graphMode': 'none'})
y += 4
add('Scrape health · all namespace targets', [('{{job}} · {{pod}} {{instance}}', 'up{job=~"agents|inference"}')],
    description='1 = reachable; 0 = failed scrape. A healthy Collector does not imply that an LLM is instrumented.')
add('Running & waiting requests', [('{{model_name}} · running', f'sum by (model_name) ({metric("num_requests_running")})'),
    ('{{model_name}} · waiting', f'sum by (model_name) ({metric("num_requests_waiting")})')],
    description='A growing queue with saturated KV cache suggests capacity pressure. Check prompt lengths and prefill latency as well.', x=12)
y += 8
add('End-to-end latency · typical & tail', [(f'{{{{model_name}}}} · p{int(q*100)}', quantile('e2e_request_latency_seconds', q)) for q in (.5, .95, .99)],
    's', 'Server request arrival to final token. Compare typical p50 and tail p95/p99 to see whether a small fraction of requests is much slower. These are request-weighted histogram estimates; low-traffic tails can be unstable.')
add('Waiting requests · by replica', [('{{model_name}} · {{pod}}', f'sum by (model_name,pod) ({metric("num_requests_waiting")})')],
    description='Per-replica waiting requests. A growing queue on one pod with idle peers suggests routing or cache-locality imbalance. Widespread queue growth points toward demand, scheduling, or capacity limits.', x=12)
y += 8
row('01 / Tokenization · CPU text → token IDs')
cpu = f'k8s_pod_cpu_usage{{job="agents",k8s_namespace_name="{namespace}",k8s_pod_name=~"${{pod:regex}}"}}'
add('CPU usage · selected pods', [('CPU cores', f'sum({cpu})')], 'suffix: cores',
    'Kubelet-measured CPU usage summed over the selected pods. 1 core means one fully busy logical CPU; 0.25 means a quarter of a core. Pod=All includes every pod in the sandbox namespace, including observability services. Model and Service do not filter this tile. This measures the whole pod, including HTTP handling, scheduling and other work; correlate it with tokenization duration to investigate CPU contention.',
    kind='stat', w=8, h=5)
add('CPU usage · by pod', [('{{k8s_pod_name}}', f'sum by (k8s_pod_name) ({cpu})')], 'suffix: cores',
    'Per-pod CPU usage from the kubelet, including all processes and containers in each pod. Uses the Pod filter, independently of Model / Service. Compare imbalance between replicas and spikes alongside tokenizer duration; CPU activity alone does not identify tokenization as the cause.', x=8, w=16, h=5)
y += 5
add('Tokenization duration', [(f'{{{{model_name}}}} · p{int(q*100)}', stage_quantile('tokenization', q)) for q in (.5, .95, .99)], 's',
    'Explicit tokenization timer. Prompt-token counts alone cannot measure tokenizer latency. Use the supplied observe_phase helper around tokenizer calls.')
add('Tokenizer throughput', [('{{model_name}} · tokenized tokens/s', f'sum by (model_name) ({stage_rate("tokens_total", "tokenization")})')],
    'tps', 'Tokens counted by the explicit timer. This is CPU tokenization throughput, distinct from prompt tokens processed by the model.', x=12)
y += 8
add('Prompt length distribution', [('{{model_name}} · p50', quantile('request_prompt_tokens', .5)), ('{{model_name}} · p95', quantile('request_prompt_tokens'))],
    'short', 'Tokens per completed request. Long prompts increase tokenization work, prefill compute and KV cache demand.')
add('Stage failures / second', [('{{model_name}} · {{stage}}', f'sum by (model_name,stage) (rate(llm_inference_stage_errors_total{{{stage_filter}}}[$__rate_interval]))')],
    'ops', 'Exceptions observed by the explicit tokenization / embedding timer; not a server HTTP error counter.', x=12)
y += 8
row('02 / Embeddings · token IDs → model vectors')
add('Internal embedding lookup duration', [(f'{{{{model_name}}}} · p{int(q*100)}', stage_quantile('embedding', q)) for q in (.5, .95, .99)], 's',
    'Time the model input embedding layer, not a RAG embedding API. This work may overlap prefill/decode accounting; do not sum it with full phase durations. CUDA calls need synchronization or CUDA-event timing to measure execution.')
add('Embedding lookup throughput', [('{{model_name}} · tokens/s', f'sum by (model_name) ({stage_rate("tokens_total", "embedding")})')],
    'tps', 'Number of token vectors looked up, including decode steps if instrumented. No inferred embedding timings.', x=12)
y += 8
row('03 / Prefill · process context & populate KV cache')
add('Prefill duration', [(f'{{{{model_name}}}} · p{int(q*100)}', quantile('request_prefill_time_seconds', q)) for q in (.5, .95, .99)],
    's', 'Pure server prefill timing. Compare with queue time and TTFT to locate prompt processing delays.')
add('Queue time vs time to first token · p95', [('{{model_name}} · queue', quantile('request_queue_time_seconds')), ('{{model_name}} · TTFT', quantile('time_to_first_token_seconds'))],
    's', 'TTFT includes waiting and other overhead. Percentiles describe different samples and must not be added or subtracted.', x=12)
y += 8
add('Prompt tokens processed / second', [('{{model_name}}', f'sum by (model_name) ({rate("prompt_tokens_total")})')],
    'tps', 'Server prompt-token counter; may include cached prompt tokens. It is not a direct GPU compute-throughput measurement.')
add('Mean server time by phase', [('{{model_name}} · '+label, mean(name)) for label, name in [('queue','request_queue_time_seconds'), ('prefill','request_prefill_time_seconds'), ('decode','request_decode_time_seconds')]],
    's', 'Means by server phase. Interpret alongside request lengths and concurrency; this is not a breakdown of individual requests.', x=12)
y += 8
add('Tokens per engine iteration', [('{{model_name}} · p50', quantile('iteration_tokens_total', .5)), ('{{model_name}} · p95', quantile('iteration_tokens_total'))],
    description='Tokens scheduled in one engine step, from vLLM\'s iteration_tokens_total histogram (despite its name, it is not a counter). It can mix chunked prefill and decode work. Larger values can come from long prompts or more batched requests; this is not a count of concurrent requests.', w=24)
y += 8
row('04 / Decode · sequential output generation')
add('TPOT vs inter-token latency · p95', [('{{model_name}} · TPOT', quantile('request_time_per_output_token_seconds')), ('{{model_name}} · ITL', quantile('inter_token_latency_seconds'))],
    's', 'TPOT is one sample per request; ITL is one per streamed output step. They can differ when outputs bundle tokens. Older vLLM ITL names are not silently relabeled as TPOT.')
add('Decode request duration', [('{{model_name}} · p50', quantile('request_decode_time_seconds', .5)), ('{{model_name}} · p95', quantile('request_decode_time_seconds'))],
    's', 'First to final output token; grows with output length even when per-token speed stays steady.', x=12)
y += 8
add('Generated length', [('{{model_name}} · p50', quantile('request_generation_tokens', .5)), ('{{model_name}} · p95', quantile('request_generation_tokens'))],
    description='Output tokens per request. Check this before attributing high end-to-end latency to slow hardware.')
add('Completion rate by finish reason', [('{{model_name}} · {{finished_reason}}', f'sum by (model_name,finished_reason) ({rate("request_success_total")})')],
    'reqps', 'Finish reasons vary by runtime. Length-limited completions may indicate a small output cap; this metric is not a complete HTTP error rate.', x=12)
y += 8
length_limited_rate = rate('request_success_total', 'finished_reason="length"')
add('Length-limited completions · fraction', [('{{model_name}}', f'sum by (model_name) ({length_limited_rate}) / sum by (model_name) ({rate("request_success_total")})')],
    'percentunit', 'Share of completed requests ending with the runtime length finish reason. This can indicate a requested output cap or context limit; it does not by itself show poor answer quality. Inspect requested caps, generated lengths and full request traces.')
add('Requested output token cap · p95', [('{{model_name}}', quantile('request_params_max_tokens'))],
    description='Requested max_tokens histogram when exported by the runtime. Compare with generated length and the length finish reason to identify truncation. It is a request setting, not generated output or the model context-window limit.', x=12)
y += 8
row('05 / KV cache · capacity, reuse & preemption')
cache = f'({metric("kv_cache_usage_perc")} or {metric("gpu_cache_usage_perc")})'
hit_rate = f'sum by (model_name) ({rate("prefix_cache_hits_total")}) / sum by (model_name) ({rate("prefix_cache_queries_total")})'
for x, title, expr, unit, description in [
    (0, 'KV occupancy · busiest engine', f'max({cache})', 'percentunit', 'Highest active block occupancy among selected replicas and engines. A hot engine can fill up even while the fleet average is low.'),
    (6, 'KV headroom · tightest engine', f'1 - max({cache})', 'percentunit', 'One minus the highest active occupancy. This is available block fraction under the runtime occupancy accounting, not free GPU bytes or a guaranteed number of additional requests.'),
    (12, 'Prefix reuse · recent window', f'sum({rate("prefix_cache_hits_total")}) / sum({rate("prefix_cache_queries_total")})', 'percentunit', 'Cached prompt tokens divided by queried prompt tokens in the rate window. Token-weighted across selected engines. No queries means an undefined ratio, not a zero-percent hit rate.'),
    (18, 'Preemptions · selected interval', f'sum(increase(vllm:num_preemptions_total{{{engine_filter}}}[$__range]) or increase(llm_inference_num_preemptions_total{{{engine_filter}}}[$__range]))', 'short', 'Counter-reset-aware estimate of preemptions in the selected dashboard interval. One request may be preempted multiple times; this is not a failed-request count.'),
]:
    card = add(title, [('Selected engines', expr)], unit, description, kind='stat', x=x, w=6, h=4)
    if unit == 'percentunit':
        card['fieldConfig']['defaults']['max'] = 1
    if x in (0, 6):
        steps = ([{'color': 'green', 'value': None}, {'color': 'yellow', 'value': .8}, {'color': 'red', 'value': .95}]
                 if x == 0 else [{'color': 'red', 'value': None}, {'color': 'yellow', 'value': .05}, {'color': 'green', 'value': .2}])
        card['fieldConfig']['defaults'].update({'color': {'mode': 'thresholds'}, 'thresholds': {'mode': 'absolute', 'steps': steps}})
y += 4
p = add('KV cache occupancy · per replica', [('{{model_name}} · {{pod}} · engine {{engine}}', cache)],
    'percentunit', 'Fraction of allocated cache blocks in use (0–1), not total GPU VRAM usage. Per-replica values expose hot spots that a fleet average hides.')
p['fieldConfig']['defaults'].update({'max': 1, 'thresholds': {'mode': 'absolute', 'steps': [{'color':'green','value':None}, {'color':'yellow','value':.8}, {'color':'red','value':.95}]}})
add('Prefix cache hit fraction', [('{{model_name}}', hit_rate)],
    'percentunit', 'Token-weighted hits / queried tokens. Idle windows have no defined ratio. Low reuse plus long prompts increases prefill work.', x=12)
y += 8
add('Preemptions / second', [('{{model_name}}', f'sum by (model_name) ({rate("num_preemptions_total")})')],
    'ops', 'Preemptions can force recomputation. Correlate spikes with cache occupancy, waiting requests, and TTFT.')
add('Prefix cache throughput · hits & misses', [
    ('{{model_name}} · reused tokens/s', f'sum by (model_name) ({rate("prefix_cache_hits_total")})'),
    ('{{model_name}} · missed tokens/s', f'clamp_min(sum by (model_name) ({rate("prefix_cache_queries_total")}) - sum by (model_name) ({rate("prefix_cache_hits_total")}), 0)'),
], 'tps', 'Token rates from prefix-cache queries: hits are reused tokens, misses are queried minus hit tokens (clamped at zero for rate-window artifacts). These counters describe cache lookups, not decode-generated tokens. A high hit ratio at tiny traffic volume can save less work than a moderate ratio under heavy traffic.', x=12)
y += 8
add('New KV tokens computed per prefill', [
    ('{{model_name}} · p50', quantile('request_prefill_kv_computed_tokens', .5)),
    ('{{model_name}} · p95', quantile('request_prefill_kv_computed_tokens')),
], description='Actual new KV token positions computed per prefill, excluding cached tokens, when the runtime exports this histogram. Compare with prompt length: lower computed-token counts for similar prompts indicate useful prefix reuse. This metric is optional and unavailable in some older vLLM versions.')
add('KV block residency & reuse gaps · p95', [
    ('{{model_name}} · lifetime', quantile('kv_block_lifetime_seconds')),
    ('{{model_name}} · idle before eviction', quantile('kv_block_idle_before_evict_seconds')),
    ('{{model_name}} · gap between reuses', quantile('kv_block_reuse_gap_seconds')),
], 's', 'Sampled block lifecycle histograms: lifetime runs from allocation to eviction; idle time runs from last access to eviction; reuse gap measures time between accesses. Requires a runtime supporting --kv-cache-metrics. Histograms may stay empty until sampled blocks are reused or evicted. These are separate distributions; do not subtract their percentiles.', x=12)
y += 8
config_labels = 'pod=~"${pod:regex}"'
# vLLM cache_config_info has no model_name label. Attach it from the matching
# engine inventory, using a presence gauge so idle (zero-running) engines match.
config_inventory = f'group by (pod,engine,model_name) ({history("num_requests_running")})'
config_expr = f'{history("cache_config_info", config_labels)} * on (pod,engine) group_left (model_name) {config_inventory}'
config = add('KV cache configuration · reported by runtime', [('Cache configuration', config_expr)],
    description='Latest cache configuration seen in the selected interval. Values are labels reported by each runtime, not measurements inferred from GPU memory usage. GPU memory utilization is a configured budget fraction. KV memory bytes is a requested budget when present; it is not live used bytes. Block/head layouts and capacity accounting vary by model and backend.', kind='table', w=24, h=7)
config['targets'][0].update({'instant': True, 'range': False, 'format': 'table'})
fields = {'model_name': 'Model', 'pod': 'Pod', 'engine': 'Engine', 'block_size': 'Tokens / block',
          'num_gpu_blocks': 'GPU blocks', 'cache_dtype': 'KV dtype', 'enable_prefix_caching': 'Prefix caching',
          'kv_cache_memory_bytes': 'KV budget', 'gpu_memory_utilization': 'GPU budget'}
config['transformations'] = [{'id': 'organize', 'options': {'includeByName': {key: True for key in fields},
    'indexByName': {key: i for i, key in enumerate(fields)}, 'renameByName': fields}}]
config['options'] = {'showHeader': True, 'cellHeight': 'sm'}
config['fieldConfig']['defaults']['unit'] = 'none'
config['fieldConfig']['overrides'] = [
    {'matcher': {'id': 'byName', 'options': 'KV budget'}, 'properties': [{'id': 'unit', 'value': 'bytes'}]},
    {'matcher': {'id': 'byName', 'options': 'GPU budget'}, 'properties': [{'id': 'unit', 'value': 'percentunit'}]},
]
y += 7
add('KV cache diagnostic guide', kind='text', w=24, h=11, content='''### Read the signals together
- **High occupancy + queue growth:** KV capacity may limit concurrency.
- **Preemptions + TTFT spikes:** requests may be recomputing evicted state.
- **Low prefix hits + long prompts:** repeated prefill work; examine cache locality.
- **Slow TPOT + modest compute use:** investigate memory traffic, batch size and context length.

**Capacity grows with context and concurrency.** Approximate raw KV bytes per token = `2 × layers × KV heads × head dimension × bytes/value`. The article's Llama 3.1-70B example is `2 × 80 × 8 × 128 × 2 = 320 KiB/token`: 100,000 tokens require about 30.5 GiB before sharing, sharding, quantization and allocator overhead.

**Active occupancy, retained prefixes and reserved VRAM differ.** An idle engine can report zero active occupancy while reusable, evictable prefix blocks remain. Its preallocated GPU pool can still occupy VRAM. The configuration table reports settings; it does not inspect tensor contents. Optional block residency charts need `--kv-cache-metrics` on a compatible vLLM version.''')
y += 11
row('06 / Hardware · optional NVIDIA DCGM exporter')
add('GPU compute utilization', [('{{pod}} · GPU {{gpu}}', 'DCGM_FI_DEV_GPU_UTIL{job="inference"}')],
    'percent', 'Requires an annotated DCGM exporter in this namespace; not installed by setup. Covers all namespace GPUs, independent of Model / Pod filters.')
add('GPU framebuffer memory used', [('{{pod}} · GPU {{gpu}}', 'DCGM_FI_DEV_FB_USED{job="inference"} * 1024 * 1024')],
    'bytes', 'DCGM reports MiB, converted to bytes. Includes weights, KV cache, activations and runtime allocations.', x=12)
y += 8
add('GPU memory bandwidth pressure · DRAM activity', [('{{pod}} · GPU {{gpu}}', '(DCGM_FI_PROF_DRAM_ACTIVE{job="inference"} or DCGM_FI_PROF_DRAM_UTIL_RATIO{job="inference"})')],
    'percentunit', 'Optional DCGM profiling counter: fraction of cycles that the GPU memory interface is sending or receiving data. This is an activity ratio, not measured GB/s. Support depends on GPU and exporter configuration. Correlate high DRAM activity with TPOT, batch size and context length; activity alone cannot prove a bandwidth bottleneck.')
add('GPU framebuffer memory free', [('{{pod}} · GPU {{gpu}}', 'DCGM_FI_DEV_FB_FREE{job="inference"} * 1024 * 1024')],
    'bytes', 'Unallocated GPU framebuffer memory reported by DCGM, converted from MiB to bytes. A preallocated KV pool can retain VRAM even when active cache occupancy falls. This is distinct from the KV pool\'s free blocks.', x=12)
y += 8
row('07 / Client perspective · OpenLIT via OTLP')
client = 'service_name=~"${service:regex}",gen_ai_response_model=~"${model:regex}"'
add('Client operation duration · p95', [('{{service_name}} · {{gen_ai_operation_name}}', f'histogram_quantile(0.95, sum by (le,service_name,gen_ai_operation_name) (rate(gen_ai_client_operation_duration_seconds_bucket{{{client}}}[$__rate_interval])))')],
    's', 'OpenLIT client wall time includes network and provider overhead. Kept separate from engine metrics to avoid double counting. Model filters match gen_ai_response_model here.')
add('Client input / output token usage', [('{{service_name}} · {{gen_ai_token_type}}', f'sum by (service_name,gen_ai_token_type) (rate(gen_ai_client_token_usage_sum{{{client}}}[$__rate_interval]))')],
    'tps', 'Sum of token usage histogram observations per second, not the observation count. Includes supported API embedding calls; these are distinct from internal token embedding lookup.', x=12)
y += 8
for x, title, suffix, explanation in [
    (0, 'Client time to first streamed chunk · p95', 'time_to_first_chunk', 'Client wall time from sending the request until its first response chunk, including network, queueing and server work. It requires streaming client instrumentation; a chunk can carry multiple tokens.'),
    (12, 'Client gap between streamed chunks · p95', 'time_per_output_chunk', 'Client-observed streaming cadence after the first chunk. Chunking, buffering and network delivery affect this independently of per-token server execution. This is not interchangeable with request-level TPOT.'),
]:
    add(title, [('{{service_name}}', f'histogram_quantile(0.95, sum by (le,service_name) (rate(gen_ai_client_operation_{suffix}_seconds_bucket{{{client}}}[$__rate_interval])))')],
        's', explanation, x=x)
y += 8
add('Investigate a slow request', kind='text', w=24, h=4, content='''### Continue in Explore
Open **Tempo** for request traces and **Loki** for workload logs using the links above. Filter by service and the dashboard time range. Structured logs containing `trace_id` link back to Tempo. Per-stage spans require runtime instrumentation; client traces alone cannot reveal internal GPU work.

[Metric definitions: vLLM](https://docs.vllm.ai/en/latest/usage/metrics/) · [Instrumentation and scraping guide](https://github.com/adykaaa/blog/tree/main/code/llm-platform-eng-1#inference-dashboard)''')

def variable(name, label, query):
    return {'name': name, 'label': label, 'type': 'query', 'datasource': ds, 'refresh': 2,
            'query': {'query': query, 'refId': name}, 'includeAll': True, 'allValue': '.*',
            'multi': True, 'sort': 1, 'current': {'text': 'All', 'value': '$__all'}}

# Keep the explanations with the dashboard JSON, including exported copies.
current_section = '00'
for panel in panels:
    if panel['type'] == 'row':
        current_section = panel['title'][:2]
    details = panel.get('description', '')
    if panel.get('targets') and any('histogram_quantile' in target['expr'] for target in panel['targets']):
        details += '\n\nPercentiles are estimated from histogram bucket rates across the selected engines. p95 means approximately 95% of observations fall below that value; it is not a latency guarantee for each request.'
    panel['description'] = (details + '\n\n' + section_context[current_section] +
        '\n\n[Inference overview · Part 1](' + article_url + '#' + section_guides[current_section][1] + ')').strip()

# Include server and client-only models, retaining choices after pods stop.
model_series = ('count by (model_name) (count_over_time({__name__=~"vllm:num_requests_running|'
                'llm_inference_num_requests_running|llm_inference_stage_duration_seconds_count",'
                'model_name!=""}[$__range]))')
client_models = ('label_replace(count by (gen_ai_response_model) '
                 '(count_over_time(gen_ai_client_operation_duration_seconds_count{'
                 'gen_ai_response_model!=""}[$__range])), "model_name", "$1", '
                 '"gen_ai_response_model", "(.+)")')
model_query = f'query_result(count by (model_name) ({model_series} or {client_models}))'
explore_links = [{'title': 'Learn · Inference overview', 'type': 'link', 'url': article_url, 'targetBlank': True}]
for uid, label in [('tempo','Traces · Tempo'), ('loki','Logs · Loki')]:
    pane = json.dumps({'investigate': {'datasource': uid, 'queries': [], 'range': {'from':'${__from}','to':'${__to}'}}}, separators=(',', ':'))
    from urllib.parse import quote
    explore_links.append({'title': label, 'type': 'link', 'url': '/explore?schemaVersion=1&panes='+quote(pane, safe='${}'), 'targetBlank': True})
dashboard = {'uid': 'llm-inference', 'title': 'LLM Inference · From prompt to token', 'schemaVersion': 39,
             'version': 1, 'tags': ['llm', 'inference', 'openlit', 'vllm'], 'timezone': 'browser',
             'editable': False, 'refresh': '15s', 'time': {'from': 'now-1h', 'to': 'now'},
             'timepicker': {'refresh_intervals': ['15s','30s','1m','5m']}, 'links': explore_links,
             'templating': {'list': [
                 variable('model', 'Model', model_query),
                 variable('pod', 'Engine pod', 'label_values({__name__=~"vllm:.*|llm_inference_.*",model_name=~"${model:regex}"}, pod)'),
                 variable('service', 'OTLP service', 'label_values({job="agents"}, service_name)')]},
             'panels': panels}
dashboard['templating']['list'][0]['regex'] = '/model_name="([^"]+)"/'
(state / 'inference-dashboard.json').write_text(json.dumps(dashboard, indent=2) + '\n')
configmap = {'apiVersion':'v1', 'kind':'ConfigMap', 'metadata':{'name':'llm-inference-dashboard'},
             'data':{'inference.json':json.dumps(dashboard)}}
# JSON is valid YAML and avoids an extra host PyYAML dependency.
(state / 'inference-dashboard.yaml').write_text(json.dumps(configmap, indent=2) + '\n')
PYDASHBOARD
cat > "$STATE_DIR/inference_metrics.py" <<'PYSTAGES'
"""Explicit internal-stage timers; initialize OpenLIT/OTel before using them."""
from contextlib import contextmanager
from time import perf_counter
from opentelemetry import metrics, trace

_meter = metrics.get_meter('llm-inference-stages')
_duration = _meter.create_histogram(
    'llm.inference.stage.duration', unit='s',
    description='Internal tokenization or embedding lookup execution time',
    explicit_bucket_boundaries_advisory=(.00001, .00005, .0001, .0005, .001, .005, .01, .05, .1, .5, 1, 5),
)
_tokens = _meter.create_counter('llm.inference.stage.tokens', description='Tokens processed by an internal stage')
_errors = _meter.create_counter('llm.inference.stage.errors', description='Internal stage exceptions')

def record_phase(stage, model_name, seconds, tokens=None):
    """Record actual measured seconds, e.g. from completed CUDA timing events."""
    if stage not in ('tokenization', 'embedding'):
        raise ValueError('stage must be tokenization or embedding')
    if seconds < 0 or (tokens is not None and tokens < 0):
        raise ValueError('duration and token count must be nonnegative')
    attributes = {'stage': stage, 'model_name': model_name}
    _duration.record(seconds, attributes)
    _errors.add(0, attributes)
    if tokens is not None:
        _tokens.add(tokens, attributes)

@contextmanager
def observe_phase(stage, model_name, tokens=None):
    """Time CPU/synchronized work. Set result['tokens'] after tokenization.

    For CUDA, synchronize before entry and before exit, or use record_phase with
    completed CUDA-event elapsed time. Unsynchronized wall time measures dispatch.
    """
    if stage not in ('tokenization', 'embedding'):
        raise ValueError('stage must be tokenization or embedding')
    result = {'tokens': tokens}
    attributes = {'stage': stage, 'model_name': model_name}
    with trace.get_tracer('llm-inference-stages').start_as_current_span('llm.' + stage, attributes=attributes):
        start = perf_counter()
        try:
            yield result
        except BaseException:
            _errors.add(1, attributes)
            raise
        finally:
            record_phase(stage, model_name, perf_counter() - start, result['tokens'])
PYSTAGES
# The preview mode renders charts without changing the cluster.
render_or_install() {
  local release=$1 chart=$2 version=$3 values=$4
  shift 4
  if [[ $RENDER_ONLY == 1 ]]; then
    helm template "$release" "$chart" --version "$version" --namespace "$NAMESPACE" -f "$values" "$@" > "$STATE_DIR/$release.rendered.yaml"
  else
    helm upgrade --install "$release" "$chart" --version "$version" --namespace "$NAMESPACE" --kube-context "$PROFILE" -f "$values" "$@" --wait --timeout "$TIMEOUT" --history-max 3
  fi
}
install_stack() {
  render_or_install loki llm-grafana/loki "$LOKI_CHART_VERSION" "$STATE_DIR/loki.yaml"
  render_or_install tempo llm-grafana/tempo "$TEMPO_CHART_VERSION" "$STATE_DIR/tempo.yaml"
  render_or_install openlit llm-openlit/openlit "$OPENLIT_CHART_VERSION" "$STATE_DIR/openlit.yaml"
  render_or_install otel llm-otel/opentelemetry-collector "$OTEL_CHART_VERSION" "$STATE_DIR/otel.yaml" --set-string image.tag="$OTEL_VERSION"
  render_or_install grafana llm-grafana/grafana "$GRAFANA_CHART_VERSION" "$STATE_DIR/grafana.yaml" --set-string image.tag="$GRAFANA_VERSION"
}
if [[ $RENDER_ONLY == 1 ]]; then
  install_stack
  printf 'Rendered manifests in %s\n' "$STATE_DIR"
  exit 0
fi
for command in minikube kubectl docker; do
  command -v "$command" >/dev/null || fail "Missing prerequisite: $command"
done
docker info >/dev/null || fail 'Docker is not accessible. Start Docker (Docker Desktop on macOS) and check docker info.'
start_args=(--profile "$PROFILE" --driver docker --container-runtime docker --cpus "$CPUS" --memory "$MEMORY")
if [[ $GPU_ENABLED == 1 ]]; then
  command -v nvidia-smi >/dev/null || fail 'Linux GPU setup requires NVIDIA drivers and nvidia-smi.'
  nvidia-smi
  if [[ -r /proc/sys/net/core/bpf_jit_harden && $(cat /proc/sys/net/core/bpf_jit_harden) != 0 ]]; then
    fail 'Minikube GPU prerequisite: set net.core.bpf_jit_harden=0 (see minikube NVIDIA documentation), then rerun.'
  fi
  start_args+=(--gpus all)
fi
minikube start "${start_args[@]}"
minikube addons enable storage-provisioner --profile "$PROFILE"
minikube addons enable default-storageclass --profile "$PROFILE"
k() { kubectl --context "$PROFILE" --namespace "$NAMESPACE" "$@"; }
if [[ $GPU_ENABLED == 1 ]]; then
  minikube addons enable nvidia-device-plugin --profile "$PROFILE"
  printf 'Waiting for an allocatable NVIDIA GPU...\n'
  gpu_ready=0
  for ((i=0; i<90; i++)); do
    if kubectl --context "$PROFILE" get nodes -o json | python3 -c 'import json,sys; sys.exit(not any(int(n["status"].get("allocatable",{}).get("nvidia.com/gpu","0")) > 0 for n in json.load(sys.stdin)["items"]))'; then
      gpu_ready=1; break
    fi
    sleep 2
  done
  [[ $gpu_ready == 1 ]] || fail 'No GPU became allocatable. Check the host NVIDIA Container Toolkit/Docker runtime and device-plugin logs.'
fi
k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
# Reuse the password on reruns; printing it is intentional and requested.
if ! k get secret grafana-admin >/dev/null 2>&1; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(24),end="")' > "$STATE_DIR/admin-password"
  k create secret generic grafana-admin --from-literal=admin-user=admin --from-file=admin-password="$STATE_DIR/admin-password"
  rm -f "$STATE_DIR/admin-password"
fi
k apply -f "$STATE_DIR/prometheus.yaml"
k apply -f "$STATE_DIR/inference-dashboard.yaml"
install_stack
# ConfigMap-only changes do not update the Deployment pod template on reruns.
# Restart to load the latest scrape configuration (and preserve the TSDB PVC).
k rollout restart deployment/prometheus
k rollout status deployment/prometheus --timeout="$TIMEOUT"
# Install OSS automatic instrumentation in an isolated environment, never system Python.
python3 -m venv "$STATE_DIR/venv"
"$STATE_DIR/venv/bin/python" -m pip install --upgrade pip openlit
"$STATE_DIR/venv/bin/python" -m pip freeze > "$STATE_DIR/python-requirements.lock"
cat > "$STATE_DIR/agent.env" <<EOF
export OTEL_SERVICE_NAME=my-agent
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:$OTLP_HTTP_PORT
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=local
EOF
# Python provides detached process sessions on Linux and macOS (no setsid utility).
cat > "$STATE_DIR/forward-supervisor.py" <<'PYFORWARD'
import signal,subprocess,sys,time
child=None
signal.signal(signal.SIGHUP,signal.SIG_IGN)
def stop(signum,frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
try:
    while True:
        child=subprocess.Popen(sys.argv[1:])
        child.wait()
        child=None
        time.sleep(2)
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
PYFORWARD
# Persistent localhost-only forwarding. Check ownership before reusing our PID files.
start_forward() {
  local name=$1 service=$2
  shift 2
  local pidfile="$STATE_DIR/$name.pid" logfile="$STATE_DIR/$name.log" pid
  if [[ -f $pidfile ]]; then
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null && ps -ww -p "$pid" -o args= | python3 -c 'import sys; s=sys.stdin.read(); sys.exit(not ("kubectl" in s and "port-forward" in s and sys.argv[1] in s and ("service/"+sys.argv[2]) in s and all(mapping in s for mapping in sys.argv[3:])))' "$PROFILE" "$service" "$@"; then
      printf 'Reusing %s forward (PID %s).\n' "$name" "$pid"
      return
    fi
  fi
  # Reject occupied ports rather than accidentally reporting another local service.
  python3 - "$@" <<'PY'
import socket,sys
for mapping in sys.argv[1:]:
    with socket.socket() as s: s.bind(('127.0.0.1',int(mapping.split(':')[0])))
PY
  # kubectl exits when the selected pod restarts; supervise it to reconnect.
  pid=$(python3 - "$STATE_DIR/forward-supervisor.py" "$logfile" kubectl --context "$PROFILE" --namespace "$NAMESPACE" port-forward --address 127.0.0.1 "service/$service" "$@" <<'PYLAUNCH'
import subprocess,sys
with open(sys.argv[2],'w') as log:
    process=subprocess.Popen([sys.executable,sys.argv[1],*sys.argv[3:]],
        stdin=subprocess.DEVNULL,stdout=log,stderr=log,
        start_new_session=True,close_fds=True)
print(process.pid)
PYLAUNCH
)
  printf '%s\n' "$pid" > "$pidfile"
  for ((attempt=0; attempt<40; attempt++)); do
    kill -0 "$pid" 2>/dev/null || { cat "$logfile" >&2; fail "Port forwarding $name failed"; }
    if python3 - "$logfile" "$#" <<'PY'
import sys
sys.exit(open(sys.argv[1]).read().count('Forwarding from') < int(sys.argv[2]))
PY
    then return; fi
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  fail "Forward $name did not start; see $logfile"
}
start_forward grafana grafana "$GRAFANA_PORT:80"
start_forward openlit openlit "$OPENLIT_PORT:3000"
start_forward otlp otel "$OTLP_GRPC_PORT:4317" "$OTLP_HTTP_PORT:4318"
curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:$GRAFANA_PORT/api/health" >/dev/null
printf '\nGrafana: http://localhost:%s\nUsername: admin\nPassword: ' "$GRAFANA_PORT"
k get secret grafana-admin -o jsonpath='{.data.admin-password}' | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())'
cat <<EOF
Inference dashboard: http://localhost:$GRAFANA_PORT/d/llm-inference
Internal-stage instrumentation helper: $STATE_DIR/inference_metrics.py
OpenLIT: http://localhost:$OPENLIT_PORT (create your local account)
OTLP HTTP: http://127.0.0.1:$OTLP_HTTP_PORT
OTLP gRPC: 127.0.0.1:$OTLP_GRPC_PORT
In-cluster OTLP HTTP: http://otel.$NAMESPACE.svc.cluster.local:4318

Forwarding runs in the background and reconnects after pod/cluster restarts.
To stop a forward, send TERM to the PID in its .pid file.
Forward PIDs/logs, values and exact versions: $STATE_DIR
Stop the sandbox: minikube stop --profile $PROFILE
Delete the sandbox AND its stored data: minikube delete --profile $PROFILE
EOF
