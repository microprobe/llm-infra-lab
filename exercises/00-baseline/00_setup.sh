#!/bin/bash

# 00_setup.sh
# Purpose: Install dependencies, build llama.cpp, download model
# Concept: Reproducible environment setup from a clean Ubuntu instance
# Tested:  Ubuntu 22.04 / 26.04 LTS, AWS c5.2xlarge (AVX-512)
# Output:  ~/llama.cpp (built), ~/models/phi-3-mini-q4_k_m.gguf

set -e  # exit on any error

# ── Config ────────────────────────────────────────────────────────────────────

MODEL_DIR=~/models
MODEL_FILE=$MODEL_DIR/phi-3-mini-q4_k_m.gguf
MODEL_URL="https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
LLAMA_DIR=~/llama.cpp

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
fail() { echo "[ERROR] $1"; exit 1; }

# ── Step 0: Verify this is a supported platform ───────────────────────────────

log "Checking platform..."

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] || fail "This script requires x86_64. Found: $ARCH"

AVX2=$(grep -c 'avx2' /proc/cpuinfo || true)
[ "$AVX2" -gt 0 ] || fail "AVX2 not found. llama.cpp requires at least AVX2."

AVX512=$(grep -c 'avx512f' /proc/cpuinfo || true)
if [ "$AVX512" -gt 0 ]; then
  log "AVX-512 detected — will compile with AVX-512 support"
  USE_AVX512=ON
else
  log "AVX-512 not detected — compiling with AVX2 only"
  USE_AVX512=OFF
fi

RAM_MB=$(free -m | awk 'NR==2{print $2}')
[ "$RAM_MB" -gt 7000 ] || fail "Less than 8 GB RAM detected (${RAM_MB} MB). Model requires at least 8 GB."

log "Platform check passed."
log "  Arch:    $ARCH"
log "  AVX512:  $USE_AVX512"
log "  RAM:     ${RAM_MB} MB"

# ── Step 1: Install dependencies ─────────────────────────────────────────────

log "Installing dependencies..."

sudo apt-get update -qq
sudo apt-get install -y \
  git \
  build-essential \
  cmake \
  curl \
  wget \
  htop \
  sysstat \
  jq \
  bc \
  linux-tools-common \
  linux-tools-generic 2>/dev/null || true

log "Dependencies installed."

# ── Step 2: Clone llama.cpp ───────────────────────────────────────────────────

if [ -d "$LLAMA_DIR" ]; then
  log "llama.cpp already exists at $LLAMA_DIR — skipping clone"
else
  log "Cloning llama.cpp..."
  git clone https://github.com/ggerganov/llama.cpp $LLAMA_DIR
  log "Cloned."
fi

# ── Step 3: Build llama.cpp ───────────────────────────────────────────────────

log "Building llama.cpp (this takes 3–5 minutes)..."

cd $LLAMA_DIR

cmake -B build \
  -DGGML_AVX512=$USE_AVX512 \
  -DGGML_AVX2=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF \
  > /tmp/cmake_config.log 2>&1

cmake --build build --config Release -j$(nproc) \
  > /tmp/cmake_build.log 2>&1

log "Build complete."

# ── Step 4: Verify binaries ───────────────────────────────────────────────────

log "Verifying binaries..."

BINS=(llama-cli llama-server llama-bench)
for BIN in "${BINS[@]}"; do
  BIN_PATH=$LLAMA_DIR/build/bin/$BIN
  [ -f "$BIN_PATH" ] || fail "Binary not found: $BIN_PATH"
  log "  $BIN — OK"
done

VERSION=$($LLAMA_DIR/build/bin/llama-cli --version 2>&1)
log "  Version: $VERSION"

# ── Step 5: Download model ────────────────────────────────────────────────────

mkdir -p $MODEL_DIR

if [ -f "$MODEL_FILE" ]; then
  log "Model already exists at $MODEL_FILE — skipping download"
  ls -lh $MODEL_FILE
else
  log "Downloading Phi-3-mini Q4_K_M (~2.3 GB)..."
  log "This will take 2–4 minutes depending on network speed..."

  wget \
    --progress=bar:force \
    --tries=3 \
    --timeout=60 \
    -O $MODEL_FILE \
    "$MODEL_URL"

  log "Download complete."
fi

# ── Step 6: Verify model ──────────────────────────────────────────────────────

log "Verifying model file..."

MODEL_SIZE=$(stat -c%s "$MODEL_FILE")
MIN_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB minimum

[ "$MODEL_SIZE" -gt "$MIN_SIZE" ] || fail "Model file too small (${MODEL_SIZE} bytes). Download may be incomplete."

log "  Model: $(ls -lh $MODEL_FILE | awk '{print $5, $9}')"
log "  Size check: PASS (${MODEL_SIZE} bytes)"

# ── Step 7: Quick smoke test ──────────────────────────────────────────────────

log "Running smoke test (single token generation)..."

SMOKE=$($LLAMA_DIR/build/bin/llama-cli \
  --model $MODEL_FILE \
  --n-gpu-layers 0 \
  --threads 4 \
  --n-predict 1 \
  --log-disable \
  -p "Hello" 2>/dev/null || true)

if [ -n "$SMOKE" ]; then
  log "  Smoke test: PASS"
else
  log "  Smoke test: WARNING — no output. Run manually to verify."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
echo "  Setup Complete"
echo "════════════════════════════════════════════"
echo ""
echo "  llama.cpp:  $LLAMA_DIR/build/bin/"
echo "  Model:      $MODEL_FILE"
echo "  Version:    $VERSION"
echo ""
echo "  Binaries available:"
for BIN in "${BINS[@]}"; do
  echo "    $LLAMA_DIR/build/bin/$BIN"
done
echo ""
echo "  Next: run 01_model_load.sh"
echo ""