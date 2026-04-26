#!/bin/bash
set -e

LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
LLAMA_PORT="${LLAMA_PORT:-8001}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-131072}"
LLAMA_MODEL="${LLAMA_MODEL:-}"
LLAMA_EXTRA_ARGS="${LLAMA_EXTRA_ARGS:-}"
LLAMA_CACHE="${LLAMA_CACHE:-/models}"
SETTINGS_FILE=/root/.claude/settings.json

export LLAMA_CACHE
mkdir -p "$LLAMA_CACHE"

# Claude Code KV-cache fix.
#
# Claude Code re-injects an attribution header on every request. With a local
# llama.cpp backend that breaks prompt caching (KV reuse), and inference slows
# down by ~90% — see https://unsloth.ai/docs/basics/claude-code#fixing-90-slower-inference-in-claude-code .
# CLAUDE_CODE_ATTRIBUTION_HEADER must be disabled via settings.json; exporting
# it from the shell does not take effect.
mkdir -p "$(dirname "$SETTINGS_FILE")"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
tmp="$(mktemp)"
jq '.env = (.env // {}) + {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
echo "[entrypoint] applied Claude Code KV-cache fix to $SETTINGS_FILE"

if [ -z "$LLAMA_MODEL" ]; then
    cat <<'EOF'
[entrypoint] LLAMA_MODEL is not set — llama-server will not start.
[entrypoint] Set it to a GGUF file or HuggingFace repo, e.g.
[entrypoint]   LLAMA_MODEL=Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf       (resolved against /models)
[entrypoint]   LLAMA_MODEL=/models/my-model.gguf                  (absolute path)
[entrypoint]   LLAMA_MODEL=unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_XL   (HuggingFace -hf)
EOF
else
    if [ -f "$LLAMA_MODEL" ]; then
        MODEL_ARGS=( --model "$LLAMA_MODEL" )
    elif [ -f "$LLAMA_CACHE/$LLAMA_MODEL" ]; then
        MODEL_ARGS=( --model "$LLAMA_CACHE/$LLAMA_MODEL" )
    else
        echo "[entrypoint] '$LLAMA_MODEL' not found locally — treating as a HuggingFace repo"
        MODEL_ARGS=( -hf "$LLAMA_MODEL" )
    fi

    echo "[entrypoint] starting llama-server on ${LLAMA_HOST}:${LLAMA_PORT} (ctx=${LLAMA_CTX_SIZE})"

    # --kv-unified is the llama.cpp half of the Claude Code KV-cache fix; it
    # pairs with the settings.json env vars above. Quantized KV cache + flash
    # attention come from Unsloth's recommended llama-server invocation.
    # shellcheck disable=SC2086
    llama-server \
        "${MODEL_ARGS[@]}" \
        --host "$LLAMA_HOST" \
        --port "$LLAMA_PORT" \
        --ctx-size "$LLAMA_CTX_SIZE" \
        --kv-unified \
        --cache-type-k q8_0 --cache-type-v q8_0 \
        --flash-attn on --fit on \
        $LLAMA_EXTRA_ARGS \
        >/var/log/llama-server.log 2>&1 &

    echo "[entrypoint] waiting for llama.cpp api..."
    for _ in $(seq 1 90); do
        if curl -fs "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
            echo "[entrypoint] llama-server is ready on :${LLAMA_PORT}"
            break
        fi
        sleep 1
    done
fi

exec "$@"
