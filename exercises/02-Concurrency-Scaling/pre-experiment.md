# EXP-02 — Concurrency Scaling
 
**Question:** With thread count fixed at the sweet spot found in EXP-01 (4 — physical core count), how do throughput and per-request latency change as the number of *concurrent* requests increases?
 
This is a different axis from EXP-01. EXP-01 asked: one request, how much compute helps? EXP-02 asks: fixed compute, how many requests can share it, and what does each one pay for that sharing?
