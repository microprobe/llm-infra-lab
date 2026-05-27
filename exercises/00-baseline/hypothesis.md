# Exercise 00 — Baseline Profiling
## Hypothesis Log

> Written before launching the instance.  
> Written before running a single measurement.  
> Do not edit after first commit.

---

## System I Expect to Run On

```
Cloud:        AWS c5.2xlarge
vCPUs:        8
RAM:          16 GB
CPU:          Intel Xeon Platinum 8000 series
SIMD:         AVX-512
OS:           Ubuntu 22.04 LTS
GPU:          None
Model:        Phi-3-mini-4k-instruct Q4_K_M
Model size:   ~2.3 GB on disk
Server:       llama-server (llama.cpp)
```

---

## My Hypotheses

### H1 — Memory at idle (model loaded, zero requests)

**My guess:** 3.0 – 4.0 GB RSS

**Reasoning:**  
Model file is ~2.3 GB. Once loaded into RAM, the process needs additional
memory for runtime buffers, the KV cache allocation, and the server itself.
I expect ~1.0 GB overhead on top of the model size.
OS and other processes will consume the remaining ~12 GB freely.

**What would surprise me:**  
RSS above 6 GB at idle — would mean something is pre-allocating aggressively.  
RSS below 2.5 GB — would mean the model is not fully loaded into RAM.

---

### H2 — Token generation speed (single user, short prompt)

**My guess:** 20 – 35 tokens/sec

**Reasoning:**  
8 vCPUs with AVX-512 is a meaningful step up from AVX2.
llama.cpp uses AVX-512 SIMD intrinsics directly.
Phi-3-mini is a 3.8B parameter model — smaller than Mistral-7B,
so each forward pass is cheaper.
No memory pressure on 16 GB for a 2.3 GB model.

**What would surprise me:**  
Below 15 tokens/sec — would mean CPU frequency scaling is active
or thermal throttling on the cloud instance.  
Above 50 tokens/sec — would mean my mental model of CPU inference is wrong
and I need to understand why.

---

### H3 — Prompt processing speed vs generation speed

**My guess:** Prompt processing will be significantly faster than generation

**Reasoning:**  
During prefill (prompt processing), all input tokens are processed in parallel
as a matrix operation — the CPU handles this efficiently in one batch.
During generation, each new token depends on the previous one — it is
sequential and cannot be parallelised. I expect prefill to be 3–5x faster
than generation in tokens/sec.

**What would surprise me:**  
Prompt processing slower than generation — would fundamentally contradict
my understanding of how transformers work.

---

### H4 — Memory growth under concurrent users

**My guess:** RSS grows roughly linearly with concurrent users

**Reasoning:**  
Each active request builds its own KV cache in memory.
KV cache size is proportional to context length.
2 concurrent users = 2 KV caches = roughly 2x the per-request memory overhead.
Model weights themselves are shared — they do not duplicate per user.

**What would surprise me:**  
Memory staying flat with 4–8 concurrent users — would mean KV caches
are being shared or evicted aggressively.
Memory growing faster than linearly — would mean there is additional
per-request overhead I am not accounting for.

---

### H5 — CPU utilisation pattern

**My guess:** CPU near 100% during generation, near 0% at idle

**Reasoning:**  
LLM inference on CPU is compute-bound — the bottleneck is floating point
matrix multiplication, not I/O or memory bandwidth at this model size.
Between requests, the server is just waiting. There is nothing to compute.

**What would surprise me:**  
High CPU at idle — would mean background threads, memory management,
or a configuration issue.  
CPU never reaching 100% during generation — would mean the bottleneck
is memory bandwidth, not compute. Worth investigating if seen.

---

### H6 — Time to first token (TTFT)

**My guess:** 0.5 – 2.0 seconds for a 100-token prompt

**Reasoning:**  
TTFT is determined by prefill speed. At 100 input tokens and fast prefill,
I expect this to be under 2 seconds. The server needs to process all input
tokens before it can return even one output token.

**What would surprise me:**  
TTFT above 5 seconds for a short prompt — would mean the server is queued
or the prefill is much slower than expected.  
TTFT under 200ms — would mean my prefill speed estimate is too conservative.

---

### H7 — Process behaviour under memory pressure

**My guess:** The process will be killed by the OOM killer (exit 137) rather
than returning a clean error if memory is exhausted

**Reasoning:**  
Linux OOM killer acts at the OS level — it does not give the process a chance
to handle the error gracefully. At 16 GB RAM with a 2.3 GB model, I do not
expect to hit this during normal single-user testing. But under high
concurrency with long contexts, KV caches could push total RSS toward
the 16 GB ceiling.

**What would surprise me:**  
llama-server returning a clean HTTP 503 or 429 before OOM — would mean
it has built-in memory pressure handling I am not aware of. Worth noting
if observed.

---

## What I Do Not Know

Be honest about the gaps.

```
- I do not know how llama.cpp handles request queuing when all slots are full
- I do not know the default KV cache size for llama-server
- I do not know if c5.2xlarge has any CPU frequency scaling active by default
- I do not know if AVX-512 is automatically used or needs a build flag
- I have never run llama-bench before — I do not know its output format
```

---

## What I Will Measure

```
1. RSS at idle                          (before any requests)
2. RSS during single request            (peak during generation)
3. RSS at 2 / 4 / 8 concurrent users   (concurrency scaling)
4. tokens/sec — prompt processing       (llama-bench pp metric)
5. tokens/sec — generation              (llama-bench tg metric)
6. TTFT — single request, 100 tokens    (curl with timing)
7. CPU% at idle and during generation   (htop / top snapshot)
8. Process exit code on clean shutdown  (verify expected 0)
```

---

## Definition of Done

This exercise is complete when:

- [ ] All 8 measurements above have 5 runs each with mean and stddev recorded
- [ ] system_info.md is committed alongside results
- [ ] run.sh can reproduce all measurements on a fresh instance

---

*Committed before instance launch. Do not edit after this point.*