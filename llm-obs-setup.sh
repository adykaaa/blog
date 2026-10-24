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
# Usage: ./llm-obs-setup.sh
# Preview: RENDER_ONLY=1 ./llm-obs-setup.sh
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
install_stack
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
