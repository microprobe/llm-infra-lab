# EXP-01 — Thread Scaling

**Question:** How does prefill (pp512) and decode (tg128) throughput scale as thread count increases, on a 4-physical-core / 8-logical-core CPU?

**Hardware:** AWS EC2 c5.2xlarge (4 physical cores, 8 vCPUs via hyperthreading), Ubuntu 22.04
**Model:** Phi-3-mini, 3.82B params, Q4_K_M quantization, 2.23 GiB
**Command:**
```
./build/bin/llama-bench -m ~/models/phi-3-mini-q4_k_m.gguf -p 512 -n 128 -r 5 -t 1,2,3,4,6,8
```
**Method:** 5 repetitions per thread count, mean ± stddev reported by llama-bench.

---

## Raw Results

| Threads | pp512 (t/s) | tg128 (t/s) |
|---|---|---|
| 1 | 8.08 ± 0.05 | 3.17 ± 0.02 |
| 2 | 16.06 ± 0.07 | 6.07 ± 0.02 |
| 3 | 24.08 ± 0.06 | 8.71 ± 0.02 |
| 4 | 32.23 ± 0.08 | 11.15 ± 0.03 |
| 6 | 33.46 ± 0.05 | 11.79 ± 0.03 |
| 8 | 36.80 ± 0.03 | 14.03 ± 0.02 |

## Scaling Factor (relative to 1 thread)

| Threads | pp512 scaling | tg128 scaling |
|---|---|---|
| 1 | 1.00x | 1.00x |
| 2 | 1.99x | 1.92x |
| 3 | 2.98x | 2.75x |
| 4 | 3.99x | 3.52x |
| 6 | 4.14x | 3.72x |
| 8 | 4.55x | 4.43x |

---

## Finding

**Prefill (pp512) scales almost perfectly linearly from 1 to 4 threads** — 2 threads ≈ 2x, 3 threads ≈ 3x, 4 threads ≈ 4x. This matches the 4 physical cores on the instance: each additional thread up to 4 gets its own independent core, so throughput scales close to 1:1.

**Past 4 threads, scaling flattens sharply.** Adding 2 more threads (4→6) buys only 0.15x more; adding 4 more (4→8) buys only 0.56x more — nowhere near another 2x. Threads 5–8 are hyperthreads sharing the same 4 physical cores' execution units, cache, and memory bandwidth, not independent workers. Hyperthreading fills idle pipeline gaps (cache-miss stalls, data dependencies) rather than adding real parallel compute capacity, so the gain is real but partial.

**Decode (tg128) shows the same pattern, but softer even before the hyperthreading cliff** — at 4 threads it's already at 3.52x rather than a clean 4x, versus prefill's near-perfect 3.99x. Decode is more memory-bound (streaming weights for one token at a time) and has less raw compute to parallelize, so it doesn't scale quite as cleanly even across genuine physical cores. Interestingly, decode gains *more* from hyperthreading specifically (4→8: +25.8%) than prefill does (4→8: +14.2%) — consistent with decode leaving more idle execution-unit gaps for a second hyperthread to fill.

## Production Implication

For capacity planning on this instance class: **allocate compute assuming ~4 effective cores' worth of throughput, not 8.** Setting a Kubernetes CPU limit or thread count above 4 on this hardware buys a modest (15–55%) improvement, not a proportional one — useful headroom, but don't budget for it as if it were real linear scaling.