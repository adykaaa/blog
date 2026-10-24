# Local LLM observability sandbox

[llm-obs-setup.sh](./llm-obs-setup.sh) detects Linux or macOS, creates a minikube cluster, and installs OpenTelemetry Collector, OpenLIT Community Edition with ClickHouse, Loki, Tempo, Grafana, and a small Prometheus instance for metrics.

Grafana comes with Loki, Tempo, and Prometheus data sources. **No dashboards or sample telemetry are created.** The script checks service readiness and Grafana HTTP health, without a telemetry smoke test.

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
bash ./llm-obs-setup.sh
```

Or download just the script from `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/adykaaa/blog/main/code/llm-platform-eng-1/llm-obs-setup.sh -o llm-obs-setup.sh
bash llm-obs-setup.sh
```

Replace `main` with a commit SHA or release tag to download a fixed script revision. Application/chart versions still resolve dynamically unless overridden.

The script enables storage add-ons, waits for the services, checks Grafana HTTP health, and prints the admin password. On Linux it also enables the NVIDIA device-plugin and waits for an allocatable GPU. Dashboards start empty; telemetry appears when you connect your agents.

| Endpoint             | Default URL/address                               |
| -------------------- | ------------------------------------------------- |
| Grafana              | http://localhost:3000                             |
| OpenLIT              | http://localhost:3001 — create your local account |
| OTLP HTTP            | http://127.0.0.1:4318                             |
| OTLP gRPC            | 127.0.0.1:4317                                    |
| In-cluster OTLP HTTP | http://otel.llm-obs.svc.cluster.local:4318        |

Forwarding binds to `127.0.0.1`; access these URLs on the machine running the script. For remote access, use an SSH tunnel, for example `ssh -L 3000:127.0.0.1:3000 user@host` for Grafana.

Removing dashboard provisioning and the smoke test does not erase data or dashboards from an existing installation. For an entirely fresh installation, use a new `PROFILE`, or explicitly delete the old cluster and its data as described below.

## Configuration

```bash
CPUS=6 MEMORY=12288 GRAFANA_PORT=3002 bash ./llm-obs-setup.sh
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
RENDER_ONLY=1 bash ./llm-obs-setup.sh
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

OpenLIT instruments supported frameworks when launched this way; installation alone does not instrument existing processes. The enterprise eBPF controller is disabled. Create your own Grafana dashboards or query the configured data sources in Explore.

The Collector reads Kubernetes stdout/stderr from the single minikube node, including on macOS where the node runs inside Docker Desktop. Host processes must explicitly export OTLP logs, for example with an OpenTelemetry logging handler. SDK traces do not automatically capture stdout. Include `trace_id` in structured logs for log-to-trace links.

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
