# Local LLM observability sandbox

[01-llm-obs-setup.sh](./01-llm-obs-setup.sh) detects Linux or macOS, creates a minikube cluster, and installs OpenTelemetry Collector, OpenLIT Community Edition with ClickHouse, Loki, Tempo, Grafana, and a small Prometheus instance for metrics.

Grafana comes with Loki, Tempo, and Prometheus data sources and a provisioned **LLM Inference · From prompt to token** dashboard, also used as the home dashboard. It covers tokenization, internal embeddings, prefill, decode, KV cache, request pressure, and optional GPU metrics. No model or sample telemetry is installed by setup; measurements appear when you connect workloads.

The script resolves the latest stable application releases and Helm charts and records the selected versions. It installs the OpenLIT Python SDK in an isolated virtual environment. It automatically installs missing CLI prerequisites and reuses installed tools. Docker and Linux NVIDIA drivers/toolkit must be prepared separately. It does not instrument already-running agents.

## Supported hosts

| Host                          | Cluster behavior                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| Linux                         | NVIDIA GPU passthrough using Docker; requires NVIDIA drivers and Container Toolkit.     |
| macOS, Apple silicon or Intel | Docker driver, without GPU passthrough; requires a running Docker Desktop installation. |

The macOS Docker/minikube path cannot expose Apple Metal GPUs to Kubernetes. You can run a model server natively on the Mac and instrument its clients, but GPU access from Kubernetes workloads is unavailable. See the [minikube GPU limitations](https://minikube.sigs.k8s.io/docs/tutorials/nvidia/) and [Docker driver documentation](https://minikube.sigs.k8s.io/docs/drivers/docker/). Windows and Linux AMD/Intel GPU setups are not covered.

## Host prerequisites

Run the script as your normal Docker-enabled user, without wrapping the entire script in `sudo`. It invokes `sudo` only when Linux system packages are missing.

Install **Docker** yourself, and on Linux install/configure the **NVIDIA driver and Container Toolkit**. On macOS, **Homebrew** is needed if a CLI dependency is missing. The script handles the tools below automatically; installed tools are reused, not overwritten or unnecessarily upgraded. An incompatible existing minikube/Helm version produces an actionable update message.

| Dependency                           | Requirement                                                                                                                                                          |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Docker                               | Docker Engine on Linux or Docker Desktop on macOS. The daemon must be running and `docker info` must succeed as the current user.                                    |
| NVIDIA GPU driver, Linux only        | A compatible driver installed on the host; `nvidia-smi` must succeed.                                                                                                |
| NVIDIA Container Toolkit, Linux only | Installed and configured for Docker GPU access.                                                                                                                      |
| minikube, automatic                  | Installs if missing. Version 1.32 or newer; use a current stable release. The script uses the Docker driver and Docker container runtime.                            |
| kubectl, automatic                   | Installs if missing. Must be compatible with the Kubernetes version used by minikube.                                                                                |
| Helm, automatic                      | Installs if missing. Version 3 or newer.                                                                                                                             |
| Python, automatic                    | Installs if missing or older than 3.10, including `venv` and pip bootstrapping support. Linux distribution packages must provide Python 3.10+.                       |
| Bash                                 | Version 3.2 or newer; the Bash shipped with macOS is supported. Run with Bash, rather than `sh`.                                                                     |
| curl and CA certificates             | macOS normally includes these; Linux bootstrapping installs curl and certificates if curl is missing. Working HTTPS is required.                                     |
| Standard host utilities              | `cat`, `mkdir`, `rm`, `tee`, `sleep`, `uname`, `ps`, `install`, and `tar`; supplied by Linux/macOS. Python handles detached forwarding, so `setsid` is not required. |

Official installation guides:

- [Docker Engine for Linux](https://docs.docker.com/engine/install/) and [non-root Docker access](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

### macOS setup

Install [Homebrew](https://brew.sh/) and Docker Desktop, then launch Docker:

```bash
open -a Docker
```

When you run the setup script, it uses Homebrew to install missing minikube, kubectl (`kubernetes-cli`), Helm, and Python. A suitable existing Python is reused. If an existing Homebrew Python is too old, it is upgraded.

Wait until Docker Desktop is ready and `docker info` succeeds. After bootstrapping, check that `python3 --version` reports 3.10 or newer. If your shell still selects Apple's older Python, put Homebrew's `bin` directory first in `PATH` using Homebrew's shell setup instructions.

In Docker Desktop's resource settings, allocate enough CPU and memory for minikube (defaults: 4 CPUs, 8 GiB RAM), with additional headroom for Docker itself. Ensure sufficient disk capacity.

Run the same script command shown below. OS detection automatically skips NVIDIA checks, Linux sysctl settings, GPU flags, and the NVIDIA device-plugin add-on on macOS. No Homebrew Bash, NVIDIA toolkit, or GNU coreutils installation is needed. Container images use the Docker engine's native architecture, including ARM64 on Apple silicon.

### Linux setup

Install Docker and NVIDIA drivers/toolkit using the linked distribution-specific instructions. The setup script automatically installs missing minikube, kubectl, and Helm into `~/.local/bin` using official release binaries with SHA256 checks. Both x86_64 and ARM64 are supported. Python/venv installation supports `apt-get` and `dnf` distributions. On other distributions, install Python 3.10+ with venv/pip and curl manually.

If you prefer to prepare the supporting packages yourself, on Ubuntu/Debian use:

```bash
sudo apt-get update
sudo apt-get install -y bash curl ca-certificates python3 python3-venv coreutils procps
```

Check that the distribution's Python is at least 3.10. This command does not install Docker or drivers/toolkit. The script installs the missing Kubernetes/Helm CLIs. No NVIDIA packages, Docker runtime configuration, sysctl settings, or Docker service restarts are performed by the script.

After installing NVIDIA Container Toolkit, configure Docker and restart its daemon. Restarting Docker can interrupt existing containers:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

The Linux GPU path also requires `net.core.bpf_jit_harden=0`, following the [minikube NVIDIA prerequisites](https://minikube.sigs.k8s.io/docs/tutorials/nvidia/). Check it with:

```bash
sysctl net.core.bpf_jit_harden
```

If nonzero, apply the required setting:

```bash
sudo sysctl -w net.core.bpf_jit_harden=0
```

To persist it across reboots:

```bash
printf 'net.core.bpf_jit_harden=0\n' | sudo tee /etc/sysctl.d/99-minikube-gpu.conf
sudo sysctl --system
```

The script checks this setting but does not change it. Follow the linked NVIDIA/minikube guides if your host uses a different service manager or Docker configuration.

### Resources, network, and permissions

- The default cluster requests **4 CPUs and 8 GiB RAM**. Leave additional memory for the host and Docker Desktop VM where applicable. Agent/model workloads need additional resources and, on Linux, GPU VRAM.
- Persistent volumes request **10 GiB total**. Leave additional disk space for Kubernetes, container images, the Python environment, and growing telemetry. The script uses minikube's default disk configuration.
- Allow outbound HTTPS from the host and cluster to GitHub's API/raw content, Helm repositories, container registries (including Docker Hub, GHCR, and minikube/Kubernetes image registries), and PyPI/package download hosts. Cluster DNS must work.
- A GitHub account/token is not required. Unauthenticated GitHub release discovery is rate limited.
- The user needs a writable state directory and permission to manage a minikube Docker container.
- Local TCP ports **3000, 3001, 4317, and 4318** must be available or overridden. Overrides must be distinct and between 1024 and 65535.
- No LLM provider credentials are required to install the stack. Your agents need their own dependencies and provider credentials.

### Automatic installation behavior

- Existing CLI tools are reused. minikube must be at least 1.32 and Helm at least 3; unsupported existing versions must be updated manually.
- Linux binaries go into `INSTALL_BIN` (default `~/.local/bin`), which the script adds to its own `PATH`. Add it to your shell's `PATH` to use the new commands outside the script.
- System package installation may ask for your sudo password. The script never installs NVIDIA components or Docker.
- On Linux distributions whose repositories provide only Python older than 3.10, install a newer Python manually and rerun. The script does not replace the system Python or add third-party Python repositories.
- Set `BOOTSTRAP=0` to require all tools to be installed already. `RENDER_ONLY=1` always skips prerequisite installation.

### Checks after bootstrapping (or when preparing tools manually)

```bash
bash --version
python3 --version
helm version --short
kubectl version --client
minikube version
docker info
command -v curl ps
```

On Linux, also run `nvidia-smi` and `sysctl net.core.bpf_jit_harden`.

Verify virtual environment support:

```bash
python3 -m venv /tmp/llm-obs-venv-check
/tmp/llm-obs-venv-check/bin/python -m pip --version
rm -rf /tmp/llm-obs-venv-check
```

## Run

From this directory, on either supported OS:

```bash
bash ./01-llm-obs-setup.sh
```

Or download just the script from `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/adykaaa/blog/main/code/llm-platform-eng-1/01-llm-obs-setup.sh -o 01-llm-obs-setup.sh
bash 01-llm-obs-setup.sh
```

Replace `main` with a commit SHA or release tag to download a fixed script revision. Application/chart versions still resolve dynamically unless overridden.

The script enables storage add-ons, waits for the services, checks Grafana HTTP health, and prints the admin password and dashboard URL. On Linux it also enables the NVIDIA device-plugin and waits for an allocatable GPU. The dashboard starts with a guide and signal coverage; charts populate when you connect instrumented workloads.

| Endpoint             | Default URL/address                               |
| -------------------- | ------------------------------------------------- |
| Grafana              | http://localhost:3000                             |
| Inference dashboard  | http://localhost:3000/d/llm-inference              |
| OpenLIT              | http://localhost:3001 — create your local account |
| OTLP HTTP            | http://127.0.0.1:4318                             |
| OTLP gRPC            | 127.0.0.1:4317                                    |
| In-cluster OTLP HTTP | http://otel.llm-obs.svc.cluster.local:4318        |

Forwarding binds to `127.0.0.1`; access these URLs on the machine running the script. For remote access, use an SSH tunnel, for example `ssh -L 3000:127.0.0.1:3000 user@host` for Grafana.

The provisioned dashboard has a stable UID and is updated on reruns. Save a copy under another name to customize it; edits to the provisioned original are disabled. Existing telemetry and other dashboards are retained. For an entirely fresh installation, use a new `PROFILE`, or explicitly delete the old cluster and its data as described below.

## Configuration

```bash
CPUS=6 MEMORY=12288 GRAFANA_PORT=3002 bash ./01-llm-obs-setup.sh
```

| Variable         | Default                                                  | Purpose                                                                      |
| ---------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `BOOTSTRAP`      | `1`                                                      | Install missing CLI dependencies; `0` checks existing tools only             |
| `INSTALL_BIN`    | `~/.local/bin`                                           | Linux download destination for missing minikube, kubectl, Helm               |
| `PROFILE`        | `llm-obs`                                                | minikube profile and kubectl context                                         |
| `NAMESPACE`      | `llm-obs`                                                | Kubernetes namespace                                                         |
| `CPUS`           | `4`                                                      | minikube CPU allocation                                                      |
| `MEMORY`         | `8192`                                                   | minikube memory allocation in MiB                                            |
| `GRAFANA_PORT`   | `3000`                                                   | Local Grafana port                                                           |
| `OPENLIT_PORT`   | `3001`                                                   | Local OpenLIT port                                                           |
| `OTLP_GRPC_PORT` | `4317`                                                   | Local Collector OTLP gRPC port                                               |
| `OTLP_HTTP_PORT` | `4318`                                                   | Local Collector OTLP HTTP port                                               |
| `STATE_DIR`      | `${XDG_STATE_HOME:-$HOME/.local/state}/llm-obs/$PROFILE` | Generated values, versions, virtual environment, forwarding logs/PIDs        |
| `TIMEOUT`        | `15m`                                                    | Helm and rollout wait timeout                                                |
| `RENDER_ONLY`    | `0`                                                      | Set to `1` to render charts without changing a cluster or installing the SDK |

Preview mode needs Bash, standard utilities, Helm, curl, Python 3.10+, and network access already installed; it never bootstraps packages or CLIs. It updates Helm repository metadata and writes generated files:

```bash
RENDER_ONLY=1 bash ./01-llm-obs-setup.sh
```

To pin versions, override `LOKI_VERSION`, `TEMPO_VERSION`, `GRAFANA_VERSION`, `OTEL_VERSION`, `OPENLIT_VERSION`, and `PROMETHEUS_VERSION`. All except Prometheus also support `*_CHART_VERSION`. Use application versions without a leading `v` or `openlit-` prefix. Selections are saved in `versions.env`; Python packages are recorded in `python-requirements.lock`. These are records, not automatically loaded on subsequent runs.

The SDK is installed from PyPI. ClickHouse retains the version provided by the OpenLIT chart. Future upstream changes may require configuration updates; successful chart rendering alone does not establish runtime compatibility.

## Connect an agent

Activate your Python agent's environment, then:

```bash
python -m pip install --upgrade openlit
source "$HOME/.local/state/llm-obs/llm-obs/agent.env"
openlit-instrument python your_agent.py
```

Set `OTEL_SERVICE_NAME` to distinguish agents. Adjust the environment file path if you changed the state directory or profile.

Alternatively, install your agent's dependencies into the script-created virtual environment and use the command printed by the script. For containerized Python agents, install `openlit` in the image, use the in-cluster Collector endpoint, and launch with `openlit-instrument python your_agent.py`.

OpenLIT instruments supported frameworks when launched this way; installation alone does not instrument existing processes. The enterprise eBPF controller is disabled. The dashboard's client section queries current OpenLIT `gen_ai.client.operation.duration` and `gen_ai.client.token.usage` histograms exported through the Collector. Engine internals need server metrics or explicit instrumentation as described below.

The Collector reads Kubernetes stdout/stderr from the single minikube node, including on macOS where the node runs inside Docker Desktop. Host processes must explicitly export OTLP logs, for example with an OpenTelemetry logging handler. SDK traces do not automatically capture stdout. Include `trace_id` in structured logs for log-to-trace links.

## Inference dashboard

Open [LLM Inference](http://localhost:3000/d/llm-inference). It is provisioned from the generated `inference-dashboard.yaml` ConfigMap; the readable JSON is also saved in the state directory. Both are generated in preview mode. Setup mounts the dashboard through a Grafana file provider, without a sidecar or remote dashboard download.

The dashboard provides:

- TTFT, TPOT, end-to-end latency, and output throughput at a glance.
- Scrape health, coverage of each stage, latency tails, running requests, and per-replica queue depth.
- Tokenization duration and throughput, live pod CPU usage, and prompt length percentiles.
- Internal token embedding lookup duration and throughput.
- Prefill duration, queue time, prompt throughput, mean time by server phase, and scheduled tokens per engine iteration.
- Decode duration, TPOT versus inter-token latency, output length/caps, and length-limited completion fractions.
- KV occupancy/headroom, prefix hit/miss token rates, preemption rates/totals, newly computed KV tokens, optional block residency/reuse gaps, and reported cache configuration.
- Optional NVIDIA DCGM compute utilization, used/free framebuffer memory, and DRAM activity.
- A separate OpenLIT client view with operation duration, token usage, first streamed chunk and chunk cadence, plus links to Tempo traces and Loki logs.

Each stage has a visible reading guide, and every panel has an expanded info tooltip linked to [Part 1: the inference overview](../../content/blog/llm-platform-engineering-1-inference-overview.md). The explanations connect token IDs and learned embeddings to Q/K/V, parallel prefill, autoregressive decode, context growth, and the GPU's compute/capacity/bandwidth constraints. They also explain measurement boundaries, percentile estimates and common causes of misleading comparisons.

**Model** and **Engine pod** filter engine metrics. **Model** and **OTLP service** filter explicit stage timers; the client view uses `gen_ai.response.model` and the service filter. CPU panels follow **Engine pod** independently of Model/Service; All includes every pod in the sandbox namespace. GPU and scrape-health panels cover the namespace independently of those filters. Variables use the selected time range so historical workloads remain selectable after removal. The default time range is one hour, refresh is 15 seconds, and Prometheus retains approximately one day of history, subject to its 512 MB storage cap.

The Collector's kubelet metrics preset reads pod CPU usage from the single minikube node every 15 seconds, using service-account authentication and read access to `nodes/stats`. No additional exporter image is installed. One reported core means one fully busy logical CPU. Whole-pod CPU includes HTTP handling, scheduling, model execution and other processes; it does not isolate the tokenizer or express usage relative to a CPU limit. CPU history starts when this receiver is enabled and is not backfilled for previously removed workloads. The local kubelet uses a self-signed certificate, so this receiver skips certificate verification.

KV headroom is the remaining fraction of the runtime's active cache-block capacity, rather than free GPU bytes. Cache configuration comes from reported labels and is joined to the model's engine inventory, including when viewing historical deployments. Settings such as `kv_cache_memory_bytes` are budgets, not current tensor usage. An idle engine can retain reusable prefixes in an allocated pool while active occupancy falls to zero. Preemption totals use `increase()` over the selected interval and are estimates, including counter-reset handling.

Block lifetime, idle-before-eviction and reuse-gap histograms require a compatible vLLM version with `--kv-cache-metrics` enabled. The optional `--kv-cache-metrics-sample` setting controls sampling; these panels describe sampled blocks and can stay empty until reuse or eviction produces observations. `request_prefill_kv_computed_tokens` and requested output-cap histograms also depend on runtime version. Unsupported or unobserved metrics remain unmeasured. Setup does not change a model server's arguments.

### Connect server metrics

Prometheus discovers opted-in **pods in `NAMESPACE` only**, using a service account with namespace-scoped, read-only pod discovery permissions. On a vLLM Deployment, put this under `spec.template` (use the actual model-server port):

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics # optional; /metrics is the default
spec:
  containers:
    - name: model
      # image, args, resources, etc. belong here
      ports:
        - name: metrics
          containerPort: 8000
```

The **container port must be named `metrics`**. Only that port is scraped, avoiding duplicate scrapes of multi-port pods. `prometheus.io/port` is not used. For another namespace, add that namespace to discovery and grant the corresponding read permissions. For a host model, configure an explicit reachable scrape target; localhost inside Prometheus refers to its own pod.

The engine queries use native [`vllm:*` metrics](https://docs.vllm.ai/en/latest/usage/metrics/) and `model_name`. Current `kv_cache_usage_perc` and older `gpu_cache_usage_perc` are supported. TPOT uses the request-level histogram; ITL uses `inter_token_latency_seconds`. Older runtimes without those metrics leave the corresponding panels unmeasured. The dashboard does not treat legacy ITL as per-request TPOT.

Other runtimes can expose the same suffixes under `llm_inference_` with the same units/types and `model_name` label. For example, `llm_inference_request_prefill_time_seconds` must be a histogram of actual prefill duration and `llm_inference_kv_cache_usage_perc` a gauge of used cache capacity as a fraction from 0 to 1. Native vLLM series take precedence when both names represent the same series. Histogram queries aggregate bucket rates before computing percentiles; prefix hit rate divides token counter rates. Idle or missing measurements are not filled with zeros.

A DCGM exporter can opt in through the same pod annotation and named port. GPU utilization uses `DCGM_FI_DEV_GPU_UTIL` (percent); framebuffer panels use `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` (MiB). The optional DRAM panel uses `DCGM_FI_PROF_DRAM_ACTIVE` (or its newer `DRAM_UTIL_RATIO` name), an activity ratio rather than measured GB/s. Profiling support depends on hardware and exporter configuration. Setup does not install a GPU exporter; those panels remain unavailable on macOS or until one is connected.

### Measure tokenization and internal embeddings

Client instrumentation and vLLM's standard metrics do not isolate the tokenizer or the model's input embedding lookup. Setup writes `inference_metrics.py` into `STATE_DIR`. Copy it alongside your model code (or add the state directory to `PYTHONPATH`). Initialize OpenLIT or an OpenTelemetry SDK with an OTLP metric reader and tracer provider, then wrap the actual work:

```python
import openlit
from inference_metrics import observe_phase

openlit.init(otlp_endpoint="http://127.0.0.1:4318")
model_name = "Qwen/Qwen2.5-0.5B-Instruct"

with observe_phase("tokenization", model_name) as measured:
    inputs = tokenizer(prompt, return_tensors="pt")
    measured["tokens"] = inputs.input_ids.numel()

# Wrap the input embedding operation inside your model's forward path.
# This example assumes synchronous CPU execution.
with observe_phase("embedding", model_name, tokens=inputs.input_ids.numel()):
    vectors = model.get_input_embeddings()(inputs.input_ids)
```

For containerized models, use `http://otel.<namespace>.svc.cluster.local:4318`. Set `OTEL_SERVICE_NAME` to select the workload in the dashboard. The helper uses the configured global SDK; it does not install a second exporter or initialize OpenLIT on import. It creates child spans as well as these metrics, translated by the Collector into:

| Prometheus metric | Type / labels | Meaning |
| --- | --- | --- |
| `llm_inference_stage_duration_seconds` | Histogram / `stage`, `model_name` | Measured execution time; stages are `tokenization` and `embedding` |
| `llm_inference_stage_tokens_total` | Counter / `stage`, `model_name` | Actual token IDs or token vectors processed |
| `llm_inference_stage_errors_total` | Counter / `stage`, `model_name` | Exceptions raised within an observed phase |

Resource conversion adds `service_name`. Keep model/service labels bounded; never use prompt text or request IDs as metric labels. For CUDA, synchronize before and after a timed region, or use CUDA events and call `record_phase(stage, model_name, seconds, tokens)` with the completed event's elapsed time converted to seconds. Synchronization changes performance and is best reserved for focused profiling. Unsynchronized host timing measures kernel dispatch, not GPU execution.

Embedding work can already be included in prefill/decode durations, so those timers must not be added together. A semantic-search embedding API call is a separate operation from the internal token lookup shown here. TTFT includes queueing and other overhead; it is not pure prefill. TPOT and ITL have different sampling weights. Cache block occupancy is not total VRAM usage, and output token throughput is not memory bandwidth.

## Troubleshooting and lifecycle

For the defaults:

```bash
kubectl --context llm-obs -n llm-obs get pods,svc
kubectl --context llm-obs -n llm-obs logs deployment/grafana
kubectl --context llm-obs -n llm-obs logs deployment/otel
```

Background port forwards reconnect after pod/cluster restarts. Their `.log` and `.pid` files are in the state directory. If localhost refuses connections, inspect `grafana.log` and Grafana's pod status. Grafana has a 1 GiB memory limit; heavier usage may require more.

Recover the password:

```bash
kubectl --context llm-obs -n llm-obs get secret grafana-admin -o jsonpath='{.data.admin-password}' |
  python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())'
```

Stop forwarding supervisors by sending TERM to their recorded PIDs, after verifying each still belongs to the matching `forward-supervisor.py` process (or `llm-obs-forward` for older installs). Example:

```bash
ps -p "$(cat "$HOME/.local/state/llm-obs/llm-obs/grafana.pid")" -o pid,args
kill "$(cat "$HOME/.local/state/llm-obs/llm-obs/grafana.pid")"
```

Repeat for `openlit.pid` and `otlp.pid`. Stop the cluster while retaining data:

```bash
minikube stop --profile llm-obs
```

Delete the cluster **and all stored telemetry and user-created dashboards**:

```bash
minikube delete --profile llm-obs
```

Profile deletion does not remove host state or stop forwarding supervisors. Stop those separately. Rerunning setup may upgrade releases; pin versions to retain the same selections.
