# parrotsec-ai

A custom build of [`parrotsec/security`](https://hub.docker.com/r/parrotsec/security)
bundled with [Claude Code](https://docs.claude.com/en/docs/claude-code) and
[llama.cpp](https://github.com/ggml-org/llama.cpp) for security analysis backed
by either the Claude API or self-hosted GGUF models.

## Purpose

`parrotsec-ai` is a containerized workspace for **authorized** offensive-
security engagements: Claude Code as a red-team pair operator, backed by
either the hosted Anthropic API or a locally-served abliterated model, with
the full Parrot Security toolkit on `PATH`. It is built for:

- Penetration tests against systems you own or have written authorization
  to assess
- CTF and capture-the-flag work
- Security research in isolated lab environments
- Drafting reports, payloads, and tooling for engagements with a documented
  Rules of Engagement (ROE)

It is **not** a general-purpose AI coding container. The repo ships
[`workspace/CLAUDE.md`](workspace/CLAUDE.md), which is bind-mounted into
the container at `/workspace/CLAUDE.md` and governs how Claude Code
operates inside an engagement: scope and authorization checks, PTES-style
workflow, audit-trail discipline in `notes.md`, and a preference for
Parrot's distro-shipped tooling over ad-hoc pip/clone installs. Mount
your own directory at `/workspace` to swap in a different operating
guide for a specific engagement.

## Disclaimer

This image is intended to be paired with abliterated or otherwise
reduced-safety models (e.g. `mradermacher/Huihui-Qwen3.6-27B-abliterated-GGUF`)
that will produce content — exploit code, shellcode, phishing pretexts,
credential-attack harnesses — that mainstream models refuse. Read these
warnings before running it. They are adapted from the warnings shipped
with the recommended abliterated model.

- **Sensitive or controversial outputs.** The recommended models have had
  most of their safety tuning removed. They will produce content that is
  illegal to deploy outside an authorized scope. Treat every output as
  raw material requiring human review before execution against a target.
- **Not for general audiences.** This is a security professional's tool.
  Do not expose it to end users, customer-facing applications, minors, or
  unsupervised environments.
- **Legal and ethical responsibility is yours.** You are solely responsible
  for ensuring every action taken from this container — recon, exploitation,
  data collection, payload deployment — is covered by written authorization
  (engagement ROE, lab ownership, CTF rules, bug-bounty scope) and complies
  with applicable law. Absence of an ROE is a stop signal, not an obstacle.
- **Research and experimental use only.** Use in lab, CTF, or authorized
  engagement contexts. Do not embed this image in production pipelines or
  expose its endpoints to untrusted networks.
- **Monitor and review outputs.** Do not auto-execute model-generated
  commands or payloads. Read what the model produced; if a generated tool
  or payload would have a destructive blast radius, confirm explicit written
  approval before running it.
- **No safety guarantees.** Neither the abliterated model authors, the
  llama.cpp project, nor this image's maintainers warrant the safety,
  legality, or correctness of generated outputs. Use is at your own risk.

The workspace `CLAUDE.md` reinforces these constraints at the agent level —
authorization, ROE, and deconfliction govern every action regardless of
whether the underlying model would refuse on its own.

## What's inside

- `parrotsec/security:latest` base image (full Parrot Security toolset)
- Node.js 20 + `@anthropic-ai/claude-code` (the `claude` CLI)
- `llama-server` (llama.cpp) compiled with CUDA, started on container launch
  when `LLAMA_MODEL` is set; listens on port `8001`
- An entrypoint that wires Claude Code to the local llama.cpp endpoint and
  applies the Claude Code KV-cache fix described by Unsloth (see below)

## Build

```sh
docker compose build
```

The first build compiles `llama.cpp` from source against CUDA 12.6 — expect
5–15 minutes depending on host. Rebuilds are cached.

## Run

Pick a model first (a local GGUF file in `./models/` or a HuggingFace repo
spec) and pass it as `LLAMA_MODEL`:

```sh
LLAMA_MODEL=mradermacher/Huihui-Qwen3.6-27B-abliterated-GGUF:Q4_K_M docker compose up -d
docker compose exec parrotsec-ai bash
```

Inside the container you land in `/workspace` with `claude` and `llama-server`
on `PATH` and `ANTHROPIC_BASE_URL` already pointing at the local server.

## Volumes

All persistence is done through bind mounts so state survives container
rebuilds. The compose file wires these up for you; the directories are created
on first run.

| Host path     | Container path  | Purpose                                                 |
| ------------- | --------------- | ------------------------------------------------------- |
| `./workspace` | `/workspace`    | Your working directory — projects, reports, loot.       |
| `./models`    | `/models`       | GGUF models. Doubles as the HuggingFace download cache. |
| `./claude`    | `/root/.claude` | Claude Code auth tokens, history, and settings.         |

Swap `./workspace` for any absolute path you prefer (e.g. an existing
engagement directory): `-v /srv/engagements/acme:/workspace`.

## Choosing a model

Drop GGUF files in `./models/` or let llama.cpp pull from HuggingFace on
first run. `LLAMA_MODEL` accepts three forms:

```sh
# 1. A filename in /models (./models on the host)
LLAMA_MODEL=Huihui-Qwen3.6-27B-abliterated.Q4_K_M.gguf

# 2. An absolute path (when mounting a single GGUF directly)
LLAMA_MODEL=/models/some/sub/dir/model.gguf

# 3. A HuggingFace repo spec — pulled on first run, cached under /models
LLAMA_MODEL=mradermacher/Huihui-Qwen3.6-27B-abliterated-GGUF:Q4_K_M
```

Other knobs, all overridable via shell env or `.env`:

| Variable           | Default     | Purpose                                                   |
| ------------------ | ----------- | --------------------------------------------------------- |
| `LLAMA_MODEL`      | _empty_     | Skip starting `llama-server` if unset.                    |
| `LLAMA_PORT`       | `8001`      | Port `llama-server` binds to (and the host port mapping). |
| `LLAMA_HOST`       | `0.0.0.0`   | Bind address inside the container.                        |
| `LLAMA_CTX_SIZE`   | `131072`    | Context window. Claude Code requires ≥ 64k.               |
| `LLAMA_CACHE`      | `/models`   | Where `-hf` downloads land.                               |
| `LLAMA_EXTRA_ARGS` | _empty_     | Extra flags appended to `llama-server` (e.g. sampling).   |

If `LLAMA_MODEL` is unset the container starts but `llama-server` does not.
You can launch it manually after attaching, or rely on `claude` against the
hosted Anthropic API.

The entrypoint passes `--reasoning off` to `llama-server` so the
recommended thinking-by-default Qwen3 abliterated models reply
directly. Override with `LLAMA_EXTRA_ARGS=--reasoning=on` if you want
chain-of-thought.

## Using Claude Code

`ANTHROPIC_BASE_URL=http://localhost:8001` and `ANTHROPIC_API_KEY=sk-no-key-required`
are pre-set, so:

```sh
claude --model llama
```

`llama-server` only serves a single model at a time, so the value passed to
`--model` is just a label — anything works. Use whatever name you'll
recognize in the session UI.

To talk to the real Anthropic API instead, just unset the base URL/key for
that session:

```sh
unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
claude
```

### The Claude Code KV-cache fix

By default Claude Code injects an attribution header on every request, which
defeats the local KV cache and slows inference by ~90% — see
[Unsloth's writeup](https://unsloth.ai/docs/basics/claude-code#fixing-90-slower-inference-in-claude-code).
The fix has two halves and the entrypoint applies both for you:

1. `~/.claude/settings.json` is patched with:
   ```json
   {
     "env": {
       "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
       "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
       "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
     }
   }
   ```
   The `CLAUDE_CODE_ATTRIBUTION_HEADER` flag has to live in `settings.json` —
   exporting it from the shell does not take effect.
2. `llama-server` is started with `--kv-unified` (plus `--cache-type-k q8_0`,
   `--cache-type-v q8_0`, `--flash-attn on`, `--fit on`) so the KV cache is
   reusable across requests.

The patch merges into any existing `settings.json` so your other Claude Code
preferences are preserved.

### Recommended model for offensive-security work

Mainstream instruction-tuned models refuse legitimate pentest requests
(payload generation, reverse shells, password cracking, etc.) even inside
an authorized engagement. `mradermacher/Huihui-Qwen3.6-27B-abliterated-GGUF`
ships GGUFs of `huihui_ai`'s abliterated Qwen 3.6 27B in quants from `Q2_K`
(10.8 GB) to `Q8_0` (28.7 GB); `Q4_K_M` (16.6 GB) is a good default for
24 GB VRAM cards.

```sh
LLAMA_MODEL=mradermacher/Huihui-Qwen3.6-27B-abliterated-GGUF:Q4_K_M docker compose up -d
```

On Apple Silicon the 27B doesn't fit comfortably in unified memory; see
[Running on Apple Silicon](#running-on-apple-silicon-m-series-macs) for
the 9B Qwen3.5 abliterated build used there instead.

Read the [Disclaimer](#disclaimer) before using an abliterated model.

## Running on Apple Silicon (M-series) Macs

Docker Desktop on macOS cannot pass Metal/MPS into containers, so the
bundled CUDA llama.cpp build doesn't help you on a Mac. The Mac flow runs
`llama-server` natively on the host (with full Metal acceleration) and
points the container at it via `host.docker.internal`. Use the 9B
Qwen3.5 abliterated build — the 27B used on Linux+CUDA is too large for
typical M-series unified memory.

1. **Install and start `llama-server` on the Mac.** Either install via
   Homebrew (`brew install llama.cpp`) or download a precompiled macOS
   build from <https://github.com/ggml-org/llama.cpp/releases>. Then,
   from the repo root:

   ```sh
   LLAMA_CACHE=$(pwd)/models llama-server \
       -hf mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF:Q4_K_M \
       --port 8001 \
       --kv-unified \
       --cache-type-k q8_0 --cache-type-v q8_0 \
       --flash-attn on --fit on \
       --reasoning off \
       --ctx-size 131072
   ```

   `LLAMA_CACHE=$(pwd)/models` redirects HuggingFace downloads into
   `./models/`, matching the Linux flow. `--reasoning off` skips the
   model's thinking phase — the recommended abliterated builds are
   thinking-by-default and Claude Code stalls waiting on the chain-of-
   thought block. `--kv-unified` is the llama.cpp half of the
   [Claude Code KV-cache fix](#the-claude-code-kv-cache-fix); keep it.

2. **Build and run the macOS variant of the container** in another terminal.
   It uses [`Dockerfile.macos`](Dockerfile.macos) (no CUDA, no in-container
   `llama-server`) and routes Claude Code at the host's `llama-server`:

   ```sh
   docker compose -f docker-compose.macos.yml up -d --build
   docker compose -f docker-compose.macos.yml exec parrotsec-ai bash
   # inside: claude --model llama
   ```

The macOS image ships the same Parrot toolset, Claude Code, workspace
`CLAUDE.md`, and entrypoint-side KV-cache fix — it just outsources the
model server to the host so inference uses Apple Silicon's GPU instead of
running CPU-only inside Docker Desktop's Linux VM.

To bring it down:
```sh
docker compose -f docker-compose.macos.yml down
```

## GPU acceleration (Linux + NVIDIA)

NVIDIA GPU passthrough is enabled by default in `docker-compose.yml`. The host
must have the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
installed and configured (`sudo nvidia-ctk runtime configure --runtime=docker
&& sudo systemctl restart docker`). Verify with:

```sh
docker compose exec parrotsec-ai nvidia-smi
```

The image bundles CUDA 12.6 runtime libraries. The driver libs come from the
host through the container toolkit, so the host driver only needs to be new
enough for CUDA 12.x (≥ 560 series).

If you need to run on a host without a GPU, remove (or comment out) the
`runtime: nvidia` line and the `deploy.resources` block in
`docker-compose.yml`; `llama-server` will fall back to CPU inference (slow).

## Exposed ports

- `8001` — `llama-server` HTTP API. Reachable from the host at
  `http://localhost:8001`. Do not expose to untrusted networks; it has no
  auth.

## Updating

```sh
docker compose build --pull     # refresh base image, claude, llama.cpp
docker compose up -d
```

Your `workspace/`, `claude/`, and `models/` directories are untouched. To bump
the bundled `llama.cpp` build, set `LLAMACPP_REF` (a git tag, e.g. `b8950`):

```sh
docker compose build --build-arg LLAMACPP_REF=b8950
```
