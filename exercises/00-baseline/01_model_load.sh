#!/bin/bash

set -e

OUTDIR=~/llm-infra-lab/exercises/00-baseline
OUTFILE=$OUTDIR/01_model_load.md
LLAMA_SERVER=~/llama.cpp/build/bin/llama-server
MODEL=~/models/phi-3-mini-q4_k_m.gguf
PORT=8080

# Cleanup
pkill llama-server 2>/dev/null || true
sleep 3

# RAM before
RAM_BEFORE=$(free -m | awk 'NR==2{print $3}')
echo "RAM before: ${RAM_BEFORE} MB"

# Start server
LOAD_START=$(date +%s%N)

$LLAMA_SERVER \
  --model $MODEL \
  --host 0.0.0.0 \
  --port $PORT \
  --n-gpu-layers 0 \
  --threads 8 \
  --parallel 1 \
  --ctx-size 4096 \
  2>/tmp/llama_server.log &

SERVER_PID=$!

# Wait for model fully loaded — grep server log for the ready line
echo "Waiting for model to fully load..."
until grep -q "server is listening" /tmp/llama_server.log 2>/dev/null; do
  sleep 1
done

LOAD_END=$(date +%s%N)
LOAD_TIME_MS=$(( (LOAD_END - LOAD_START) / 1000000 ))

# Small extra wait for RAM to settle
sleep 2

# RAM after
RAM_AFTER=$(free -m | awk 'NR==2{print $3}')
RAM_DELTA=$(( RAM_AFTER - RAM_BEFORE ))

echo "RAM after:  ${RAM_AFTER} MB"
echo "RAM delta:  ${RAM_DELTA} MB"
echo "Load time:  ${LOAD_TIME_MS} ms"

# Stop server
kill $SERVER_PID 2>/dev/null || true
sleep 2

# Write results
cat > $OUTFILE << MDEOF
# 01 — Model Load Memory Cost
Generated: $(date '+%Y-%m-%d %H:%M:%S')

## Concept
Model load is a one-time memory allocation paid before serving any request.
The process reads the entire model file into RAM and holds it permanently.
This cost is fixed regardless of request volume.

## Results

| Metric | Value |
|--------|-------|
| RAM before load | ${RAM_BEFORE} MB |
| RAM after load | ${RAM_AFTER} MB |
| RAM delta (model footprint) | ${RAM_DELTA} MB |
| Model file on disk | $(ls -lh $MODEL | awk '{print $5}') |
| Time to load | ${LOAD_TIME_MS} ms |

## Hypothesis H1
- Predicted: 3.0 – 4.0 GB used after load
- Actual: ${RAM_AFTER} MB ($(echo "scale=2; $RAM_AFTER/1024" | bc) GB)
- Result: $(if [ $RAM_AFTER -gt 3000 ] && [ $RAM_AFTER -lt 4096 ]; then echo "PASS"; else echo "OUTSIDE range"; fi)

## Notes
- Waited for 'server is listening' in log — guarantees model fully loaded
- RAM delta > disk size due to runtime buffers and KV cache pre-allocation
- Load time includes reading 2.3 GB model file from disk into RAM
- No requests served during this measurement
MDEOF

echo ""
echo "Done → $OUTFILE"