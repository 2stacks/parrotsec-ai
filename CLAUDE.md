# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker image (no application code, no tests, no linter) that layers Claude Code and llama.cpp onto `parrotsec/security:latest` for authorized offensive-security work. Two build variants ship side-by-side:

- **Linux + NVIDIA** — `Dockerfile` + `docker-compose.yml`. Compiles `llama-server` from source against CUDA 12.6, runs it inside the container, GPU passthrough via the NVIDIA Container Toolkit.
- **macOS / Apple Silicon** — `Dockerfile.macos` + `docker-compose.macos.yml`. Skips the CUDA build entirely; the user runs `llama-server` natively on the Mac (Metal-accelerated) and the container reaches it via `host.docker.internal`.

When making changes that affect the runtime (entrypoint, env vars, ports), update **both** compose files and **both** Dockerfiles unless the change is platform-specific. The macOS variant intentionally lacks `LLAMA_*` env vars and the GPU/`/models` plumbing.

## Build / run

```sh
# Linux + NVIDIA
docker compose build
LLAMA_MODEL=<gguf-or-hf-spec> docker compose up -d
docker compose exec parrotsec-ai bash

# macOS — start llama-server on the host first (`brew install llama.cpp`), then:
docker compose -f docker-compose.macos.yml up -d --build
docker compose -f docker-compose.macos.yml exec parrotsec-ai bash

# Bump the bundled llama.cpp build
docker compose build --build-arg LLAMACPP_REF=b8950
```

The first Linux build takes 5–15 minutes (compiling llama.cpp with CUDA). Rebuilds are layer-cached.

## Architecture notes that aren't obvious from a single file

**Three-stage Linux build.** `Dockerfile` stages: (1) `nvidia/cuda:*-devel` to compile static llama.cpp binaries with `-DGGML_CUDA=ON`, (2) `nvidia/cuda:*-runtime` purely as a source for `libcudart`/`libcublas*`/`libnccl` shared libs, (3) `parrotsec/security:latest` as the actual final image. Only the binaries from (1) and the runtime libs from (2) are copied forward — the CUDA dev image is never the runtime base.

**The libcuda.so.1 stub trick.** llama-server links against `libcuda.so.1`, but the CUDA dev image only ships the stub `libcuda.so`. A symlink (`ln -sf libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1`) lets the linker resolve the SONAME at build time; at runtime the **host** driver provides the real `libcuda.so.1` through the NVIDIA Container Toolkit. This is why the host driver only needs to be new enough for CUDA 12.x — the runtime userspace libs come from the image, the kernel-side driver from the host.

**Two halves of the Claude Code KV-cache fix.** Without both, local inference is ~90% slower (Unsloth's writeup is the canonical reference, linked in `entrypoint.sh`):
1. `entrypoint.sh` patches `/root/.claude/settings.json` via `jq` with three env keys, of which `CLAUDE_CODE_ATTRIBUTION_HEADER=0` is the load-bearing one. **It must live in `settings.json`** — exporting it from the shell is silently ignored by the Claude Code runtime.
2. `llama-server` is launched with `--kv-unified` plus quantized KV cache (`--cache-type-{k,v} q8_0`), `--flash-attn on`, `--fit on`. If you change the launch flags, preserve `--kv-unified`.

The `jq` patch **merges** into any existing `settings.json` (because `./claude` is a bind mount that persists across container rebuilds), so user preferences are kept.

**`--reasoning off` is mandatory for the recommended models.** The recommended Qwen3-family abliterated GGUFs (the 27B Qwen3.6 on Linux/CUDA and the 9B Qwen3.5 on Apple Silicon) are thinking-by-default. Without `--reasoning off`, llama-server returns Anthropic-shaped responses with a `thinking` content block but no `text` block until the model finishes its chain-of-thought, which Claude Code reads as an empty response and stalls on. The Linux entrypoint passes the flag by default; the README's macOS llama-server invocation includes it explicitly. Override via `LLAMA_EXTRA_ARGS=--reasoning=on` (the last `--reasoning` on the command line wins). If you swap to a non-thinking model the flag is harmless, so don't strip it from the entrypoint defensively.

**`LLAMA_CACHE` controls llama.cpp's `-hf` download path on both platforms.** Inside the Linux container it defaults to `/models` (set in the Dockerfile). On the macOS host the env var is *unset* by default — llama.cpp falls back to `~/.cache/huggingface/hub/`. The macOS README invocation prepends `LLAMA_CACHE=$(pwd)/models` so downloads land in the project's `./models/` directory like the Linux flow. Keep that prefix on any new macOS llama-server invocations you document.

**LLAMA_MODEL resolution order** (`entrypoint.sh`): absolute path → filename in `$LLAMA_CACHE` (default `/models`) → assumed HuggingFace repo spec passed to `llama-server -hf`. If `LLAMA_MODEL` is unset, the container starts but `llama-server` does **not** — Claude Code can still hit the hosted Anthropic API after the user unsets `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` for that session.

**Two CLAUDE.md files, two purposes.**
- This file (repo root) — guidance for Claude Code instances working **on the image itself**.
- `workspace/CLAUDE.md` — bind-mounted to `/workspace/CLAUDE.md` inside the container; governs Claude Code instances running **inside** the container during an engagement (ROE/scope discipline, PTES workflow, `notes.md` audit trail). Do not conflate the two; edits to one rarely belong in the other.

**Bind mounts and gitignore.** Linux compose mounts all three of `./workspace`, `./models`, `./claude`. macOS compose mounts only `./workspace` and `./claude` — the macOS path runs `llama-server` on the host, so the container has no use for `./models/`. All three directories' contents are gitignored (only `workspace/CLAUDE.md`, `models/.gitkeep`, `claude/.gitkeep` are tracked). Persistence survives container rebuilds.

## When changing the entrypoint

- Both Dockerfiles `COPY entrypoint.sh` and use it as `ENTRYPOINT`. The macOS variant doesn't start `llama-server` (no model flow), but it still runs the script for the `settings.json` KV-cache fix — the `LLAMA_MODEL` empty branch handles that case.
- The script ends with `exec "$@"` so the `CMD ["/bin/bash"]` (or whatever the user runs via `docker compose exec`) takes over PID 1's slot. Don't break that contract.
