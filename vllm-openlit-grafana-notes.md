# Temporary notes: NVIDIA vLLM on Kubernetes with OpenLIT and Grafana

These notes adapt the [vLLM Kubernetes deployment guide](https://docs.vllm.ai/en/stable/deployment/k8s/) to the existing `llm-obs` cluster.

**Historical validation:** tested on the `llm-obs` Minikube cluster with an RTX 2070. The vLLM deployment served Qwen, and the final OpenLIT SDK client run completed 40/40 requests with no exporter errors. The cleanup removes that model deployment; the manifest below remains a reference for redeployment. Grafana data-source checks confirmed server/client metrics, correlated Tempo traces, and Loki request logs. See the validation results below for panels that still need additional instrumentation.

## Approach

Keep the guide's basic NVIDIA deployment, but add two separate instrumentation paths:

1. **vLLM server metrics and traces:** inference throughput, queueing, KV cache, and latency.
2. **OpenLIT instrumentation in the calling application:** GenAI operations, token usage, client latency, and request traces.

Use the OpenLIT Python SDK in the calling application. The observability stack does not deploy the OpenLIT UI/backend or ClickHouse.

## Existing cluster setup

| Component | Observed configuration |
|---|---|
| GPU | One NVIDIA GeForce RTX 2070, 8 GiB VRAM; unallocated at inspection time |
| NVIDIA support | Device plugin running; Kubernetes advertises `nvidia.com/gpu: 1` |
| Environment | Single-node Minikube on WSL2, approximately 15 GiB system RAM |
| Storage class | `standard`, not the guide's `default` |
| OTLP entry point | `otel.llm-obs.svc.cluster.local:4318` for HTTP, `:4317` for gRPC |
| Collector routing | Traces → Tempo; metrics → Prometheus exporter; logs → Loki |
| Prometheus discovery | Annotated pods in `llm-obs`, with a container port named `metrics` |
| Grafana | Prometheus, Tempo, and Loki data sources already configured |
| Dashboard | **LLM Inference · From prompt to token**, UID `llm-inference` |

```text
OpenLIT-instrumented application ──OTLP──┐
                                       ├─> otel collector ─> Tempo / Prometheus ─> Grafana
vLLM native traces ──────────────OTLP───┘

vLLM /metrics ───────────────────────────> Prometheus ──────> Grafana
vLLM container stdout ───────────────────> existing log collector ─> Loki
```

Send application/server OTLP to `otel`. Grafana queries Prometheus, Tempo, and Loki; the OpenLIT SDK needs no separate backend.

Prometheus scrapes native vLLM metrics directly, without passing them through the Collector.

## 1. Keep the existing NVIDIA setup; use a smaller model

Another NVIDIA device-plugin installation is not needed.

Do not start with the guide's unquantized Mistral-7B example on this GPU: FP16 weights alone need roughly 14 GB, before KV cache and other allocations.

This deployment runs `Qwen/Qwen2.5-1.5B-Instruct` in FP16 with a 2,048-token context limit. The tested `vllm/vllm-openai:v0.32.0` image runs on the RTX 2070 (Turing/SM 7.5); vLLM selects its Triton attention backend because FlashAttention requires a newer GPU.

The model argument is a [Hugging Face repository ID](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct). On startup, vLLM downloads the configuration, tokenizer, and weights from Hugging Face Hub into `/root/.cache/huggingface`, which the `vllm-models` PVC persists. The public model needs no token. The container image comes from Docker Hub and does not include the Qwen weights.

See [vLLM GPU requirements](https://docs.vllm.ai/en/stable/getting_started/installation/gpu/).

Because this is WSL2, do not follow bare-metal instructions that install a Linux NVIDIA display driver inside WSL; the GPU driver comes from Windows. See [NVIDIA's WSL guidance](https://docs.nvidia.com/cuda/wsl-user-guide/index.html).

## 2. Cluster-specific deployment template

The manifest pins `vllm/vllm-openai:v0.32.0`, the latest stable [vLLM release](https://github.com/vllm-project/vllm/releases/tag/v0.32.0) at the time of this update. Docker Hub lists this tag for Linux/amd64. The deployment and inference tests below used this image without substituting another tag.

Save as `vllm.yaml` when ready to deploy:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-models
  namespace: llm-obs
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: llm-obs
spec:
  replicas: 1
  # Allow the first image pull plus model download/loading to finish.
  progressDeadlineSeconds: 1800
  # One GPU: avoid a rolling update waiting for a second GPU.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
      annotations:
        # These must be POD annotations for the current scrape configuration.
        prometheus.io/scrape: "true"
        prometheus.io/path: /metrics
    spec:
      # Prevent the vllm Service from injecting VLLM_PORT=tcp://... .
      enableServiceLinks: false
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.32.0
          command: ["vllm"]
          args:
            - serve
            - Qwen/Qwen2.5-1.5B-Instruct
            - --host=0.0.0.0
            - --port=8000
            - --dtype=half
            - --max-model-len=2048
            - --max-num-seqs=8
            - --gpu-memory-utilization=0.80
            - --enforce-eager
            - --otlp-traces-endpoint=http://otel.llm-obs.svc.cluster.local:4318/v1/traces
          env:
            - name: OTEL_SERVICE_NAME
              value: vllm-server
            - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
              value: http/protobuf
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: service.namespace=llm-obs,deployment.environment.name=development
          ports:
            # Required by the existing Prometheus relabel configuration.
            # This port serves both the API and /metrics.
            - name: metrics
              containerPort: 8000
          resources:
            requests:
              cpu: "2"
              memory: 3Gi
              nvidia.com/gpu: "1"
            limits:
              cpu: "4"
              memory: 8Gi
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: models
              mountPath: /root/.cache/huggingface
            - name: shm
              mountPath: /dev/shm
          startupProbe:
            httpGet:
              path: /health
              port: metrics
            periodSeconds: 10
            failureThreshold: 120
          readinessProbe:
            httpGet:
              path: /health
              port: metrics
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: metrics
            periodSeconds: 20
            failureThreshold: 3
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: vllm-models
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: llm-obs
spec:
  selector:
    app: vllm
  ports:
    - name: http
      port: 8000
      targetPort: metrics
```

### Differences from the original guide

- **`namespace: llm-obs`:** the existing Prometheus discovery sees this namespace.
- **Pod scrape annotations and port named `metrics`:** a `prometheus.io/port` annotation alone would not satisfy the current scrape configuration.
- **Native tracing enabled explicitly:** the HTTP signal endpoint ends in `/v1/traces`.
- **Smaller model, FP16, and conservative memory settings:** a starting point for the RTX 2070, not a guarantee that every image/backend combination will work.
- **Startup probe:** allows model download/loading before liveness checks can restart the container. Increase its budget if downloads take longer.
- **No HF token required for this public model**, and no need for `--trust-remote-code`.
- **Pinned image rather than `latest`.**
- **`Recreate` strategy:** avoids needing a second GPU during updates, at the cost of downtime.
- **`enableServiceLinks: false`:** prevents Kubernetes from injecting `VLLM_PORT=tcp://...` for the `vllm` Service. vLLM expects an integer and otherwise crashes after loading the model.
- **30-minute progress deadline:** covers the initial image pull and model startup. The first image pull took about 7.5 minutes on this machine.

Current vLLM documentation says core OpenTelemetry dependencies are bundled. For an older selected release, check its matching documentation; bake any missing dependencies into the image rather than installing them on every pod startup.

See [vLLM's OpenTelemetry example](https://docs.vllm.ai/en/stable/examples/observability/opentelemetry/).

For short diagnostic sessions, you can add this argument under the container's `args` list. This excerpt is not a standalone Kubernetes manifest:

```yaml
- --collect-detailed-traces=all
```

Leave detailed tracing off initially: vLLM warns that it can introduce costly/blocking operations. See [engine arguments](https://docs.vllm.ai/en/stable/configuration/engine_args/).

## 3. Instrument the application calling vLLM with OpenLIT

This populates the **Client perspective · OpenLIT via OTLP** section of the existing dashboard.

OpenLIT's current Python vLLM instrumentor wraps `LLM.generate`, the offline Python API. That is not equivalent to instrumenting every request handled by `vllm serve`. For HTTP serving, use native vLLM server tracing plus OpenLIT's OpenAI-client instrumentation.

See the [OpenLIT vLLM instrumentor source](https://github.com/openlit/openlit/blob/main/sdk/python/src/openlit/instrumentation/vllm/__init__.py) and [Python SDK documentation](https://github.com/openlit/openlit/blob/main/sdk/python/README.md).

Use the tested client: [`code/llm-platform-eng-1/vllm-openlit-client.py`](code/llm-platform-eng-1/vllm-openlit-client.py). Run these commands from the repository root.

Create a Python environment with the versions used for the test:

```bash
CLIENT_VENV="${XDG_STATE_HOME:-$HOME/.local/state}/llm-obs/vllm-client-venv"
python3 -m venv "$CLIENT_VENV"
"$CLIENT_VENV/bin/python" -m pip install openlit==1.45.0 openai==2.54.0
```

On your workstation, cluster DNS names do not resolve. Forward both services, each in its own terminal. Skip a forward if it is already running:

```bash
kubectl --context llm-obs -n llm-obs port-forward --address 127.0.0.1 svc/vllm 8000:8000
kubectl --context llm-obs -n llm-obs port-forward --address 127.0.0.1 svc/otel 4318:4318
```

Send 40 requests, alternating regular and streaming responses:

```bash
"$CLIENT_VENV/bin/python" code/llm-platform-eng-1/vllm-openlit-client.py \
  --requests 40 --interval 2 --max-tokens 96
```

For a longer live demonstration, use `--requests 120 --interval 2`. The client prints a trace ID per request. It does not run the model locally.

### Reading the client

Start with `main()`: it reads the options, configures OpenLIT, opens the OpenAI client, and runs the requests. Its `finally` block flushes telemetry even if a request interrupts the run.

`request_completion()` handles the two response formats. Regular calls return the answer text; streaming calls collect text chunks and skip the final usage-only chunk. `send_request()` adds the parent span, propagates trace headers, and prints the result. `run_requests()` alternates modes, counts request failures, and waits between calls. Unexpected programming errors stop the script instead of being counted as API failures.

The script keeps the command-line options separate from the request examples so you can read the instrumentation without stepping through argument parsing.

Important details:

- The defaults target `http://localhost:8000/v1` and the **base OTLP URL** `http://localhost:4318`, without `/v1/traces`.
- The client uses the service name `vllm-demo-client` and leaves prompt/response capture disabled for telemetry. It prints a short answer excerpt to your terminal.
- It requests streaming usage with `stream_options={"include_usage": True}` so OpenLIT can record token counts for streamed responses.
- It exports metrics every five seconds unless you override `OTEL_METRIC_EXPORT_INTERVAL`, and flushes metrics and traces before exit.
- It propagates the enclosing `chat-request` span to vLLM. Tempo contains the client and native server spans under the same trace ID; the server span need not be a direct child of OpenLIT's SDK span.
- A successful completion count proves inference worked, not that telemetry arrived. Check exporter errors and Grafana's data sources too.

To run the same client from an environment inside the cluster, pass these URLs instead:

```bash
python vllm-openlit-client.py \
  --base-url http://vllm.llm-obs.svc.cluster.local:8000/v1 \
  --otlp-endpoint http://otel.llm-obs.svc.cluster.local:4318 \
  --requests 40 --interval 2
```

If a workstation forward prints `lost connection to pod`, restart it before rerunning the client. During testing, the OTLP forward exited after a broken pipe; a supervised forward restored it. The final 40-request run had no telemetry exporter errors.

## 4. Expected Grafana coverage and limitations

| Dashboard area | Expected result |
|---|---|
| Requests, queueing, throughput, TTFT, decode, basic KV-cache metrics | Native vLLM `/metrics`; availability varies by vLLM release |
| Pod CPU usage | Existing kubelet metrics pipeline |
| Client operation latency and token usage | OpenLIT-instrumented application |
| Request traces | Tempo, including native vLLM spans |
| Container logs | Existing Loki pipeline |
| Tokenization and internal embedding lookup timings | Not automatically supplied by this setup |
| GPU hardware panels | Not populated yet: no DCGM exporter was installed at inspection time |

### Custom stage metrics

The dashboard queries `llm_inference_stage_*` metrics for tokenization and internal embedding lookup. Neither basic OpenLIT client instrumentation nor standard vLLM `/metrics` guarantees these metrics.

Those panels need explicit server-side instrumentation, or should be marked unavailable. Enabling detailed traces alone does not create these custom Prometheus metric families.

### GPU telemetry

The hardware panels query `DCGM_FI_*` metrics. An OpenLIT/NVML GPU collector emits different metric names, requiring dashboard changes.

Check DCGM/profiling support for this GeForce/WSL2 environment rather than assuming datacenter-GPU capabilities. Get inference telemetry working first.

### Optional KV-block metrics

For releases that support it, `--kv-cache-metrics` enables additional KV-block residency/reuse metrics used by some dashboard panels. This is separate from basic KV-cache occupancy.

### Metric compatibility

Pin the OpenLIT and vLLM versions and compare the emitted metric names and labels with the dashboard queries. A functioning telemetry pipeline does not guarantee every panel matches every SDK/server release.

## 5. Deploy and validate

These commands change the cluster. The test deployed the manifest above, including the service-link and progress-deadline fixes.

After saving the manifest as `vllm.yaml`:

```bash
kubectl --context llm-obs apply -f vllm.yaml
kubectl --context llm-obs -n llm-obs rollout status deployment/vllm --timeout=30m
kubectl --context llm-obs -n llm-obs logs deployment/vllm -f
```

In separate terminals:

```bash
# Skip forwards that are already running.
kubectl --context llm-obs -n llm-obs port-forward --address 127.0.0.1 svc/vllm 8000:8000
kubectl --context llm-obs -n llm-obs port-forward --address 127.0.0.1 svc/grafana 3000:80
```

Generate requests:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 64
  }'
```

Check the following:

- **Grafana dashboard:** `http://localhost:3000/d/llm-inference?from=now-30m&to=now`. Select Model `Qwen/Qwen2.5-1.5B-Instruct`, Engine pod `vllm-…` (or All), and OTLP service `vllm-demo-client`. Set refresh to 5s while the client runs. After traffic stops, keep a time range containing the run; recent rate panels will become idle.
- **Prometheus Explore:** `up{job="inference"}` should be `1` for the new target.
- **Server metrics:** `vllm:num_requests_running` should exist.
- **Tempo Explore:** search `{ resource.service.name = "vllm-server" }`.
- **Loki Explore:** select the vLLM pod's logs.
- Run the **OpenLIT-instrumented client**, not only `curl`, to populate client-side GenAI metrics.

Allow a few scrape intervals and sustained traffic for rate/percentile panels. Check collector logs for export failures if telemetry does not arrive:

```bash
kubectl --context llm-obs -n llm-obs logs deployment/otel --since=5m
```

### Observed validation results

- At the end of the historical validation, the model PVC was Bound, `deployment/vllm` was 1/1 available with zero restarts after the fix, and all 16 cluster pods were Ready.
- The final OpenLIT run completed **40/40 requests: 20 regular and 20 streaming**, with no exporter errors. Prometheus recorded 40 client operations, 20 first-chunk observations, 1,570 input tokens, and 3,326 output tokens for that run. Counts vary on subsequent runs.
- Checks through Grafana's Prometheus proxy returned measured data for **37 of 47 metric panels**, with no query errors. This included TTFT, TPOT, end-to-end latency, prefill/decode duration, throughput, prefix-cache reuse, KV occupancy, pod CPU, client token usage, and both streaming timing panels.
- Tempo returned a distributed trace containing `vllm-demo-client` and `vllm-server`, including `chat-request`, OpenLIT's chat span, and vLLM's `llm_request` span. One example trace ID is `37ec80741e98f8002a96044ae6e53386`.
- Loki returned vLLM `POST /v1/chat/completions` logs with HTTP 200. Example LogQL: `{k8s_namespace_name="llm-obs",k8s_pod_name=~"vllm-.*"} |= "POST /v1/chat/completions"`.
- The collector briefly retried Loki exports after an ingestion-rate-limit burst. The retries cleared, request logs remained queryable, and no export/drop errors appeared in the final one-minute check. No ingestion-limit change was needed.

The ten empty metric panels cover custom tokenization/embedding stage signals, optional KV-block residency/reuse, and DCGM GPU hardware metrics. The client cannot supply these server-internal measurements. Basic KV-cache and pod CPU measurements do work; zero preemptions or no waiting requests are valid readings, not missing telemetry.

## Bottom line

The collector routing and Grafana data sources already exist. The essential changes are **scrape opt-in, native vLLM tracing to `otel`, OpenLIT instrumentation in the caller, and a model that fits the GPU**—not another observability-stack installation.
