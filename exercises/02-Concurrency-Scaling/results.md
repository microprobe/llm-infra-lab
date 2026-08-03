# EXP-02 — Concurrency Scaling

**Question:** Threads fixed at 4 (EXP-01's sweet spot). As more requests run *at the same time*, what happens to speed and to how long each user waits?

**Hardware:** AWS EC2 c5.2xlarge (4 physical cores, 8 vCPUs, 16 GB RAM)
**Model:** Phi-3-mini 3.82B, Q4_K_M

---

## Quick glossary (for future me / readers)

| Term | Meaning |
|---|---|
| **B** | Concurrency. Number of requests running at the same time. |
| **PP (prefill)** | Reading the input prompt, before any reply starts. |
| **TG (decode)** | Generating the reply, one word-piece (token) at a time. |
| **TTFT** | Time To First Token — how long until the reply *starts* appearing. Equals PP time. |
| **Per-token latency** | Once the reply has started, time for each new token. |
| **Total latency** | TTFT + (per-token latency × reply length). What a user actually feels, end to end. |

---

## Command

```bash
./build/bin/llama-batched-bench \
  -m ~/models/phi-3-mini-q4_k_m.gguf \
  -c 4096 -b 2048 -ub 512 \
  -npp 128 -ntg 128 \
  -npl 1,2,4,8,16 \
  -t 4
```

Run 3 times (tool has no built-in repeat flag), mean ± stddev below.

**Warnings seen (harmless):** Phi-3 GGUF metadata quirk on 2 special tokens; context-size note. Neither affects results.

---

## Pre-Test Questions

From EXP-01: PP scales near-linearly with threads (compute-bound). TG scales a bit softer (memory-bound).

1. Will PP speed stay flat as B rises, since 4 threads are already maxed out?
2. Will total TG speed rise, but each user's per-token speed drop, since memory bandwidth is now shared across more requests?
3. *(Not tested here — see EXP-03)* At what B does 16 GB RAM run out?

---

## Results (mean ± stddev, 3 runs)

**PP — total speed stays flat.** Confirms Q1.

| B | PP speed (t/s) |
|---|---|
| 1 | 33.06 ± 0.28 |
| 2 | 33.16 ± 0.26 |
| 4 | 33.36 ± 0.06 |
| 8 | 33.42 ± 0.15 |
| 16 | 30.40 ± 0.20 |

**TG — total speed rises, but slower than B rises.** Confirms Q2.

| B | TG speed, total (t/s) |
|---|---|
| 1 | 10.03 ± 0.04 |
| 2 | 11.90 ± 0.01 |
| 4 | 16.54 ± 0.07 |
| 8 | 17.91 ± 0.09 |
| 16 | 20.41 ± 0.07 |

16x more concurrent users → only ~2x more total output. The rest is lost to sharing.

---

## What one user actually feels

| B | TTFT (s) | Per-token (ms) | Total for 128-token reply (s) |
|---|---|---|---|
| 1 | 3.9 | 100 | 16.6 |
| 2 | 3.9 | 168 | 25.4 |
| 4 | 3.8 | 242 | 34.8 |
| 8 | 3.8 | 447 | 61.0 |
| 16 | 4.2 | 784 | 104.5 |

**TTFT barely changes** — reading the prompt stays fast no matter how many others are waiting.
**Per-token time gets much worse** — this is the real cost of concurrency.
**End result:** at 16 users, one reply takes ~6x longer than at 1 user.

---

## Why PP stays cheap and TG doesn't

- **PP** reads the whole prompt at once — many tokens processed together in one big matrix multiply. Adding more requests just makes that multiply wider. Nearly free.
- **TG** makes one token at a time per request. Each step pulls the *entire* model from memory for very little math. More requests = more memory traffic sharing the same bus = each one slows down. This is the same compute-bound vs. memory-bound split seen in EXP-01, showing up again here.

---

## One surprise, confirmed real (not noise)

Total TG speed gain from B4→B8 (+8.3%) is much smaller than B2→B4 (+39%) or B8→B16 (+14%) — a dip, not a smooth curve. Seen identically in **all 3 runs**, so it's a real effect (likely batch-size/ubatch interaction at B=8), not random noise. Not fully explained yet — flagged for later investigation, not solved here.

---

## Not answered here → EXP-03

This experiment never measured RAM. Each concurrent user needs their own memory slice. On a 16 GB box, memory — not speed — may be the real hard limit on "how many users fit." That question is EXP-03.

---

## Bottom line

More concurrent users → more total work done, but each user waits much longer per reply. On this machine, past ~8 concurrent users, growth in total speed is small while per-user wait time keeps climbing sharply. Any latency target (e.g. "reply in under 20s") should set a concurrency limit well below where raw throughput keeps rising.