#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["openlit==1.45.0", "openai==2.54.0"]
# ///
"""Send regular and streaming requests to vLLM with OpenLIT telemetry.

First, forward vLLM to localhost:8000 and the OTLP collector to
localhost:4318. Then run this script to populate the Grafana dashboard.
Prompt/response capture is disabled; answer excerpts go to the terminal.
"""

import argparse
import os
import time
from collections.abc import Sequence

import openlit
from openai import OpenAI, OpenAIError
from openai.types.chat import ChatCompletionMessageParam
from opentelemetry import metrics, trace
from opentelemetry.propagate import inject
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.trace import TracerProvider

MODEL = "Qwen/Qwen2.5-1.5B-Instruct"
SERVICE_NAME = "vllm-demo-client"
PROMPTS = (
    "Explain Kubernetes in three short sentences.",
    "Explain how a language model's KV cache helps generation.",
    "Give five practical tips for monitoring a small Kubernetes cluster.",
    "Compare prefill and decode in language model inference.",
)


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read connection settings and the size of the demonstration run."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--requests",
        type=int,
        default=40,
        help="Number of requests (default: 40)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="Seconds between requests (default: 2)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=96,
        help="Maximum output tokens per request (default: 96)",
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1"),
        help="vLLM API URL; also configurable with VLLM_BASE_URL",
    )
    parser.add_argument(
        "--otlp-endpoint",
        default=os.getenv(
            "OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"
        ),
        help="Base OTLP HTTP URL, without /v1/traces",
    )
    parser.add_argument("--model", default=MODEL, help="Model served by vLLM")
    options = parser.parse_args(argv)

    if options.requests < 1:
        parser.error("--requests must be positive")
    if options.max_tokens < 1:
        parser.error("--max-tokens must be positive")
    if options.interval < 0:
        parser.error("--interval must be nonnegative")
    return options


def configure_telemetry(endpoint: str) -> trace.Tracer:
    """Instrument OpenAI calls and export telemetry to the collector."""
    # Export during the run, rather than waiting for the default interval.
    os.environ.setdefault("OTEL_METRIC_EXPORT_INTERVAL", "5000")
    openlit.init(
        application_name=SERVICE_NAME,
        service_name=SERVICE_NAME,
        environment="development",
        otlp_endpoint=endpoint,
        capture_message_content=False,
        collect_gpu_stats=False,
    )
    return trace.get_tracer("vllm-demo")


def request_completion(
    client: OpenAI,
    *,
    model: str,
    prompt: str,
    max_tokens: int,
    streaming: bool,
    headers: dict[str, str],
) -> str:
    """Return the answer text from a regular or streaming chat request."""
    messages: list[ChatCompletionMessageParam] = [
        {"role": "user", "content": prompt}
    ]
    if not streaming:
        response = client.chat.completions.create(
            model=model,
            messages=messages,
            max_tokens=max_tokens,
            extra_headers=headers,
        )
        return response.choices[0].message.content or ""

    text_chunks: list[str] = []
    with client.chat.completions.create(
        model=model,
        messages=messages,
        max_tokens=max_tokens,
        stream=True,
        # Include token counts so OpenLIT can measure streamed token usage.
        stream_options={"include_usage": True},
        extra_headers=headers,
    ) as response_stream:
        for chunk in response_stream:
            # The final usage-only chunk has no choices.
            if not chunk.choices:
                continue
            text = chunk.choices[0].delta.content
            if text:
                text_chunks.append(text)
    return "".join(text_chunks)


def send_request(
    client: OpenAI,
    tracer: trace.Tracer,
    options: argparse.Namespace,
    request_number: int,
) -> None:
    """Trace one request and print its timing, trace ID, and answer excerpt."""
    streaming = request_number % 2 == 0
    # Use the same prompt for each regular/streaming pair.
    prompt_index = ((request_number - 1) // 2) % len(PROMPTS)
    started_at = time.monotonic()

    with tracer.start_as_current_span("chat-request") as span:
        span.set_attribute("demo.request_number", request_number)
        span.set_attribute("demo.streaming", streaming)
        trace_id = f"{span.get_span_context().trace_id:032x}"

        # Propagate this trace to vLLM's native server instrumentation.
        headers: dict[str, str] = {}
        inject(headers)
        answer = request_completion(
            client,
            model=options.model,
            prompt=PROMPTS[prompt_index],
            max_tokens=options.max_tokens,
            streaming=streaming,
            headers=headers,
        )
        if not answer.strip():
            raise ValueError("vLLM returned no text")

    elapsed_seconds = time.monotonic() - started_at
    mode = "stream" if streaming else "regular"
    print(
        f"{request_number}/{options.requests} {mode} "
        f"{elapsed_seconds:.2f}s trace={trace_id}",
        flush=True,
    )
    print(answer[:200].replace("\n", " "), flush=True)


def run_requests(
    client: OpenAI, tracer: trace.Tracer, options: argparse.Namespace
) -> int:
    """Run the demonstration and return the number of failed requests."""
    failures = 0
    for request_number in range(1, options.requests + 1):
        try:
            send_request(client, tracer, options, request_number)
        except (OpenAIError, ValueError) as error:
            failures += 1
            print(f"Request {request_number} failed: {error}", flush=True)

        if request_number < options.requests:
            time.sleep(options.interval)
    return failures


def flush_telemetry() -> None:
    """Export pending metrics and traces before this short-lived client exits."""
    providers = (metrics.get_meter_provider(), trace.get_tracer_provider())
    for provider in providers:
        if not isinstance(provider, (MeterProvider, TracerProvider)):
            continue
        if not provider.force_flush(timeout_millis=30_000):
            raise RuntimeError("Telemetry flush timed out")


def main() -> None:
    """Configure the client, generate traffic, and flush its telemetry."""
    options = parse_arguments()
    tracer = configure_telemetry(options.otlp_endpoint)
    try:
        with OpenAI(
            base_url=options.base_url,
            api_key="unused",
            timeout=180.0,
            max_retries=0,
        ) as client:
            failures = run_requests(client, tracer, options)
    finally:
        flush_telemetry()

    successes = options.requests - failures
    print(f"Finished: {successes}/{options.requests} requests succeeded.")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
