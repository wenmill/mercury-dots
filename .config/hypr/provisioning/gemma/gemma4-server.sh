#!/usr/bin/env bash
# Gemma-4-26B-A4B (256-ish expert MoE, 4B active) launcher — Vulkan build (ROCm-free).
# Mirrors qwable-server.sh: keep attention on GPU, push MoE experts of the first
# N layers to system RAM (--n-cpu-moe) so a 26B model fits 16GB VRAM with a big
# context and a safety margin. Only 4B is active per token, so CPU expert matmul
# is cheap. Tune NCMOE up to free VRAM (more context / more margin), down for speed.
set -euo pipefail

BIN="${LLAMA_BIN:-$HOME/llama-cpp-turboquant/build-vulkan/bin/llama-server}"
MODEL="${GEMMA_MODEL:-$HOME/models/gemma-active.gguf}"  # symlink -> active model (swap + restart)
MMPROJ="${GEMMA_MMPROJ:-}"          # set to the mmproj gguf to enable image input (costs VRAM)
HOST=127.0.0.1
PORT="${GEMMA_PORT:-11434}"
NCMOE="${GEMMA_NCMOE:-14}"          # experts of first N layers kept in RAM (tune vs VRAM)
CTX="${GEMMA_CTX:-32768}"           # context window (raise until VRAM margin is ~1GB)
THREADS="${GEMMA_THREADS:-6}"       # CPU threads for expert matmul
CTK="${GEMMA_CTK:-q8_0}"            # KV cache quant (q8_0 safe on Vulkan; q4_0 = smaller)
CTV="${GEMMA_CTV:-q8_0}"

ARGS=(
  -m "$MODEL"
  -ngl 99
  -fa on
  -c "$CTX"
  -np 1
  --no-warmup
  -ctk "$CTK" -ctv "$CTV"
  --threads "$THREADS" --threads-batch "$THREADS"
  -b 2048 -ub 512
  --cache-reuse 256
  --host "$HOST" --port "$PORT"
)
# Expert-offload only helps MoE models; skip for dense (NCMOE=0).
[ "${NCMOE:-0}" -gt 0 ] 2>/dev/null && ARGS+=( --n-cpu-moe "$NCMOE" )
[ -n "$MMPROJ" ] && ARGS+=( --mmproj "$MMPROJ" )

exec "$BIN" "${ARGS[@]}" "$@"
