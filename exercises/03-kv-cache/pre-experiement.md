## The formula being tested
 
Phi-3-mini-4k-instruct config: hidden_size 3072, 32 layers, 32 attention heads, 32 key-value heads (no GQA — full multi-head attention, so `head_dim = 3072 / 32 = 96`).
 
```
Per token, per layer:   K + V  =  2 × (32 heads × 96 dims)  =  6,144 numbers
Per token, all 32 layers:       =  32 × 6,144               =  196,608 numbers
Bytes per token (F16 KV cache): =  196,608 × 2 bytes         ≈  384 KB
```
 
**Question:** total KV memory ≈ `(prompt_tokens + generated_tokens) × 384 KB`, and — critically — **input tokens and output tokens should cost identically**, since the formula makes no distinction between where a token came from.
 
**Sanity check against EXP-02 data (not yet measured, just estimated):** at B=1, N_KV=256 → ≈96 MB. At B=16, N_KV=4096 → ≈1.5 GB. Both far under 15GB, consistent with EXP-02 never approaching a memory wall.
 
## Question
 
Does actual measured peak memory (RSS) scale linearly with token count, at the ~384 KB/token rate predicted — for both prompt length and generation length independently?
 
## Fixed variables
 
- Threads: 4 (EXP-01's ceiling)
- Concurrency: 1 (isolate token-length effect only; concurrency itself is EXP-03's job, not this one)
- Model: Phi-3-mini Q4_K_M, same as all prior experiments
## What's being measured
 
- **Maximum resident set size**, via `/usr/bin/time -v` (reports this directly) — not before/after snapshots, since those miss the actual peak during the run.
## Method
 
**Part A — vary prompt length, fixed generation length (128):**
```bash
for npp in 128 512 1024 2048; do
  /usr/bin/time -v ./build/bin/llama-batched-bench \
    -m ~/models/phi-3-mini-q4_k_m.gguf -c 4096 -b 2048 -ub 512 \
    -npp $npp -ntg 128 -npl 1 -t 4 2>&1 | tee -a results-raw-input-len.txt
done
```
 
**Part B — vary generation length, fixed prompt length (128):**
```bash
for ntg in 128 512 1024 2048; do
  /usr/bin/time -v ./build/bin/llama-batched-bench \
    -m ~/models/phi-3-mini-q4_k_m.gguf -c 4096 -b 2048 -ub 512 \
    -npp 128 -ntg $ntg -npl 1 -t 4 2>&1 | tee -a results-raw-output-len.txt
done
```
 
Note: `-c` (total KV budget) must stay ≥ `npp + ntg` for each run or llama.cpp will error/truncate before reaching the real number — increase `-c` for the 2048 cases if needed.
 
## Predictions (pre-registered)
 
1. **Part A and Part B will show the same slope** — roughly 384 KB of RSS growth per additional token, regardless of whether that token came from the prompt or from generation. This is the main thing being tested: input and output tokens should be interchangeable in memory cost.
2. **The relationship will be linear**, not stepped or exponential — RSS vs. token count should form a straight line in both parts.
3. **Possible failure mode to watch for:** llama.cpp may pre-allocate the full `-c` (context budget) up front regardless of how many tokens are actually used, in which case RSS would look flat across all `-npp`/`-ntg` values in this experiment (since `-c 4096` is fixed) rather than scaling with actual token count. If this happens, it's a more useful finding than confirmation — it means EXP-03's real lever is `-c`, not `-npl` alone.