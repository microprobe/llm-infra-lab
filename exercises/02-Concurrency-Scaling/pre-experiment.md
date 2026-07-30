# EXP-02 — Concurrency Scaling
 
**Question:** With thread count fixed at the sweet spot found in EXP-01 (4 — physical core count), how do throughput and per-request latency change as the number of *concurrent* requests increases?
 
This is a different axis from EXP-01. EXP-01 asked: one request, how much compute helps? EXP-02 asks: fixed compute, how many requests can share it, and what does each one pay for that sharing?

## Pre-Test Questions
 
**Context from EXP-01:** at 4 threads (physical core count), PP scaled to 3.99x (near-perfect linear) and TG scaled to 3.52x (slightly softer, since decode is memory-bound). Beyond 4 threads, TG actually gained *more* from hyperthreading than PP did (+25.8% vs +14.2% at 8 threads) — hyperthreads fill idle pipeline gaps, and memory-bound decode has more of those gaps to fill.
 
**Fixed variable:** threads held at 4 — the point where physical-core scaling ends, established in EXP-01.
 
**What I'm testing:**
 
1. Does PP throughput stay flat as concurrent requests increase, since compute is already saturated at 4 threads regardless of how many sequences share it?
2. Does TG aggregate throughput rise sub-linearly with concurrency (batching amortizes the memory-bandwidth cost across sequences), while per-request TG latency degrades — and by roughly how much?