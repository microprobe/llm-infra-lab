# llm-infra-lab

> Hands-on infrastructure experiments for LLM serving.  
> Measured. Reproducible. Built from first principles.

---

## Why This Repo Exists

Every engineer who has run production services knows how to monitor a process:  
watch CPU, watch memory, health-check it, restart it when it hangs.

LLMs are processes too. But they behave differently from anything else you have run in production — and those differences will silently destroy your uptime, your budgets, and your benchmarks if you don't understand them first.

This repo is a structured series of experiments to build that understanding from the ground up.  
Not theory. Not tutorials. Measured evidence, reproducible on real infrastructure.

---

## LLMs vs Traditional Services — The Mental Model Shift

### A Traditional Service

```
start process
  → allocates small working memory
  → idles near-zero CPU at rest
  → CPU spikes on request, returns to idle
  → memory stays roughly flat over time
  → scales horizontally: 10 replicas = 10x capacity
  → stateless: any request can go to any replica
  → health check: GET /health → 200 OK
  → hung? SIGKILL, restart, back in 30 seconds
```

### An LLM Inference Server

```
start process
  → immediately allocates 2–20 GB RAM to load model weights
  → idles at near-zero CPU but holds RAM permanently
  → CPU/GPU spikes during generation, drops between requests
  → memory grows per active request (KV cache)
  → scales horizontally BUT: 10 replicas = 10x RAM (each needs full model)
  → stateful per-request: context window must stay on the same replica
  → health check: GET /health → 200 OK (but model may be loaded and broken)
  → hung? SIGKILL works, but cold restart = full model reload = 30–120 seconds
```

The process model is the same. The resource profile is completely different.

---

## Resource Requirements — What Determines Them

### Model Size Is the Starting Point

LLM weights are stored as floating point numbers. The number of parameters
and the precision they are stored at determines the baseline memory floor.

```
Memory required ≈ (parameters × bytes_per_parameter) + runtime_overhead

FP32 (4 bytes/param):   7B model → 7B × 4  = ~28 GB
FP16 (2 bytes/param):   7B model → 7B × 2  = ~14 GB
Q8  (1 byte/param):     7B model → 7B × 1  = ~7 GB
Q4  (0.5 bytes/param):  7B model → 7B × 0.5 = ~3.5 GB  ← common local default
```

This is the memory the process allocates before it serves a single request.
It is non-negotiable. You cannot reduce it by tuning ulimits or cgroups.

### What Happens During Processing

A request arrives with N input tokens. The model:

1. **Prefill phase** — processes all N input tokens at once, builds a KV cache.  
   CPU/GPU pegged. Memory grows by `O(N)`. This is where TTFT comes from.

2. **Generation phase** — generates one output token at a time, appending to KV cache.  
   Lower CPU than prefill. Memory continues growing with each generated token.

3. **Request ends** — KV cache is freed. Memory drops back to baseline.

```
Memory profile of a single request:

[model loaded]──────────────────────────────────────────────────
[request arrives]          ┌──── KV cache grows ────┐
[request ends]             └────────────────────────┘
[back to baseline]──────────────────────────────────────────────
```

With 10 concurrent requests: 10 separate KV caches held simultaneously.  
This is the primary scaling constraint. Not CPU. Memory.

### CPU Requirements

For CPU-only inference (no GPU):

| vCPUs | AVX2/AVX-512 | Expected throughput |
|-------|-------------|---------------------|
| 4     | AVX2        | 5–10 tokens/sec     |
| 8     | AVX2        | 10–18 tokens/sec    |
| 8     | AVX-512     | 18–30 tokens/sec    |
| 16    | AVX-512     | 30–50 tokens/sec    |

AVX-512 support matters significantly. llama.cpp uses SIMD intrinsics directly.  
Check before provisioning: `grep avx512 /proc/cpuinfo | head -1`

### The Minimum Viable Floor

```
RAM  =  model_size_on_disk × 1.25  +  2 GB OS headroom
CPU  =  at least AVX2, 4+ vCPUs for usable throughput
Disk =  model_size + 2 GB working space (SSD preferred for load time)
```

Below these numbers, your benchmark results measure resource starvation, not inference.

---

## Health Checks — What They Mean for LLMs

A standard process health check tells you the port is open.  
For an LLM server, a passing health check tells you almost nothing.

### The Gap

| Health check result | What it means for a normal service | What it means for an LLM server |
|--------------------|-----------------------------------|----------------------------------|
| 200 OK             | Service is working                 | Process is alive, model may still be loading |
| Timeout            | Service is down                    | Service is down OR generating a long response |
| 500 Error          | Application error                  | OOM, CUDA error, or context overflow |

### Meaningful LLM Health Signals

```bash
# 1. Is the process alive?
GET /health

# 2. Is the model actually loaded and responding?
POST /completion  {"prompt": "ping", "n_predict": 1}
# Expect: one token returned in < 5 seconds

# 3. How loaded is it?
GET /slots
# Returns: active slots, KV cache usage percentage

# 4. Is it degrading?
# Track p99 TTFT over time — a rising p99 before OOM is your early warning
```

The single-token completion check is your real readiness probe.  
If that times out, the model is overloaded, restarting, or dead.

---

## Process Exit Codes

llama.cpp server (`llama-server`) is a standard Linux process.  
Kubernetes and Docker restart policies apply identically.

| Exit code | Signal    | Cause                                              |
|-----------|-----------|-----------------------------------------------------|
| 0         | —         | Clean shutdown                                      |
| 1         | —         | Generic error: bad model file, port conflict, config error |
| 134       | SIGABRT   | Assertion failure, CUDA runtime error               |
| 137       | SIGKILL   | **OOM killer** — Linux killed the process silently  |
| 139       | SIGSEGV   | Segfault — memory corruption or llama.cpp bug       |
| 143       | SIGTERM   | Clean shutdown requested (kubectl delete, docker stop) |

**Exit 137 is the one to watch.** At tight memory margins, Linux kills the model
process before it logs a single error line. You see an empty log and exit 137.
That is not a crash. That is the OS protecting other processes from your model.

### Restart Policy Recommendation

```yaml
# Kubernetes
restartPolicy: Always
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 60    # model needs time to load
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3

# Docker Compose
restart: unless-stopped
```

Set `initialDelaySeconds` to at least the model load time.  
Restarting before the model finishes loading creates a restart loop that never resolves.

---

## Network Usage

LLM servers have an asymmetric network profile:

```
Inbound (request):   small — a prompt is usually < 10 KB
Outbound (response): larger — but still small unless streaming
Streaming:           small continuous packets over a long connection
```

The network is rarely the bottleneck for single-user CPU inference.  
It becomes relevant at scale under these conditions:

| Scenario | Network concern |
|----------|----------------|
| Streaming to 100 concurrent users | Many long-lived connections |
| Multi-modal inputs (images + text) | Inbound payload spikes to MBs |
| Model serving across AZs | Cross-AZ latency adds to TTFT |
| Proxy / gateway in front of model | Timeout config must exceed max generation time |

**Timeout configuration is critical.** A 30-second gateway timeout will kill  
long-running generations mid-stream. Your gateway timeout must exceed your  
worst-case generation time, not your average.

---

## How to Measure LLM Performance

Traditional services are measured by RPS and p99 latency.  
LLMs need additional metrics because the response is generated incrementally.

### Core Metrics

| Metric | Definition | Why it matters |
|--------|-----------|----------------|
| **TTFT** | Time To First Token — latency from request to first token returned | User-perceived responsiveness |
| **Tokens/sec (generation)** | Output tokens generated per second | Throughput, model serving capacity |
| **Tokens/sec (prompt processing)** | Input tokens processed per second during prefill | Cost of long contexts |
| **KV cache utilization** | % of cache slots occupied | Leading indicator of OOM risk |
| **Request queue depth** | Requests waiting for a free slot | Scaling signal |

### What to Collect Per Run

```
1. system_info     →  lscpu, free -h, uname -a, llama.cpp version
2. baseline_idle   →  RSS memory, CPU% before any requests
3. single_request  →  TTFT, tokens/sec, peak RSS during generation
4. ramp_test       →  1, 2, 4, 8 concurrent users — tokens/sec and RSS at each level
5. endurance       →  100 sequential requests — does throughput degrade over time?
```

Always run each measurement **5 times minimum** and record mean and standard deviation.  
A single run is not a benchmark. It is a guess with a timestamp.

### The Benchmark That Matters

```bash
# llama-bench ships with llama.cpp
# Runs standardized prompt + generation benchmark

./llama-bench \
  -m model.gguf \
  -p 512 \        # prompt tokens
  -n 128 \        # generation tokens
  -r 5            # repeat 5 times

# Output: pp (prompt processing) and tg (token generation) in tokens/sec
# This is your reproducible baseline number
```

---

## What Breaks Things

```
MEMORY
├── Model too large for available RAM     → process never starts
├── Too many concurrent requests          → KV cache fills, OOM kill (exit 137)
├── Context length too long               → single request exhausts KV cache
└── Memory leak in llama.cpp             → slow RSS growth, OOM hours later

COMPUTE
├── Thermal throttling (laptops / shared) → tokens/sec drops silently mid-benchmark
├── CPU frequency scaling (power save)   → inconsistent benchmark results
└── NUMA topology ignored                → memory latency penalty on multi-socket

CONFIGURATION
├── Wrong thread count                   → underutilizes cores or causes contention
├── Context size set too large           → pre-allocates KV cache you won't use
├── Model file corruption                → loads fine, produces garbage output silently
└── Quantization mismatch               → loads wrong format, crashes on first request

PROCESS / ORCHESTRATION
├── Liveness probe fires during model load → restart loop
├── Gateway timeout < generation time     → mid-stream 504 to client
├── No readiness probe                    → traffic routed before model is ready
└── Retry on timeout without backoff      → thundering herd against recovering model
```

---

## Exercises

| # | Name | What you measure |
|---|------|-----------------|
| [00](./exercises/00-baseline/) | Baseline Profiling | CPU, memory, tokens/sec at rest and under single-user load |
| 01 | Concurrency Scaling | How metrics change from 1 → 8 concurrent users |
| 02 | Context Length Impact | TTFT and memory as prompt length grows |
| 03 | Health Check Design | Building a meaningful readiness probe |
| 04 | Failure Injection | OOM behaviour, exit codes, restart recovery time |

---

## Principles

- Write the hypothesis before running anything
- Record system info alongside every result
- Mean and stddev, never a single number
- If you cannot reproduce it, it did not happen

---

## Stack

- [llama.cpp](https://github.com/ggerganov/llama.cpp) — inference engine
- Models from [Hugging Face](https://huggingface.co) in GGUF format
- AWS c5.2xlarge (8 vCPU, 16 GB, AVX-512) as reference hardware
- Linux — all measurements on Ubuntu 22.04 LTS