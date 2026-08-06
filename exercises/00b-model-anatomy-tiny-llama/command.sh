#!/usr/bin/env bash
set -euox pipefail
cd "$(dirname "$0")"

# --- 1. Python environment (skipped if already set up) ---
if [ ! -d venv ]; then
  python3 -m venv venv
fi
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet huggingface_hub gguf safetensors transformers torch sentencepiece protobuf

# --- 2. Download tiny Llama-family model (skipped if already present) ---
if [ ! -d tiny-llama ]; then
  hf download yujiepan/llama-2-tiny-random --local-dir ./tiny-llama
fi

# --- 3. Get llama.cpp's conversion script (skipped if already cloned) ---
if [ ! -d llama.cpp ]; then
  git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
fi

# --- 4. Convert to GGUF (skipped if already converted) ---
if [ ! -f tiny-llama.gguf ]; then
  python3 llama.cpp/convert_hf_to_gguf.py ./tiny-llama --outfile tiny-llama.gguf --outtype f16
fi

# --- 5. Dump the GGUF file: metadata + tensors, correctly typed ---
python3 -c "
from gguf import GGUFReader

r = GGUFReader('tiny-llama.gguf')

print('--- METADATA ---')
for f in r.fields.values():
    val = f.contents()
    if isinstance(val, list) and len(val) > 10:
        val = f'[array, {len(val)} entries, first 3: {val[:3]}]'
    print(f.name, '=', val)

print()
print('--- TENSORS ---')
for t in r.tensors:
    print(t.name, [int(x) for x in t.shape])
"