for i in 1 2 3; do
  ./build/bin/llama-batched-bench \
    -m ~/models/phi-3-mini-q4_k_m.gguf \
    -c 4096 -b 2048 -ub 512 \
    -npp 128 -ntg 128 \
    -npl 1,2,4,8,16 \
    -t 4
done