# syntax=docker/dockerfile:1
#
# Build a static CUDA-enabled llama-server, layer it onto parrotsec/security
# alongside Claude Code, and link to the host CUDA driver at runtime via the
# NVIDIA Container Toolkit. Build recipe follows
# https://unsloth.ai/docs/basics/claude-code#install-llama.cpp.

ARG CUDA_VERSION=12.6.3
ARG UBUNTU_VERSION=24.04
ARG LLAMACPP_REF=b8931
ARG CUDA_ARCHITECTURES="75;80;86;89;90"

# Stage 1: build llama.cpp with CUDA support (static binaries).
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS llamacpp_build

ARG LLAMACPP_REF
ARG CUDA_ARCHITECTURES
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        pciutils \
        build-essential \
        cmake \
        curl \
        libcurl4-openssl-dev \
        libssl-dev \
        git \
    && rm -rf /var/lib/apt/lists/*

# The CUDA driver stub ships only as libcuda.so but its SONAME is libcuda.so.1.
# Provide the alias so the linker can satisfy llama-server's NEEDED entry;
# libcuda.so.1 is supplied at runtime by the NVIDIA container toolkit.
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}
RUN ln -sf libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1

WORKDIR /
RUN git clone --depth 1 --branch "${LLAMACPP_REF}" \
        https://github.com/ggml-org/llama.cpp

RUN cmake llama.cpp -B llama.cpp/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=OFF \
        -DLLAMA_OPENSSL=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,/usr/local/cuda/lib64/stubs" \
    && cmake --build llama.cpp/build --config Release -j --clean-first \
        --target llama-cli llama-mtmd-cli llama-server llama-gguf-split

# Stage 2: source for the userspace CUDA runtime libs.
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS cuda_runtime

# Stage 3: final image — parrotsec + Node + claude + llama.cpp binaries.
FROM parrotsec/security:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LLAMACPP_DIR=/opt/llama.cpp
ENV CUDA_RUNTIME_DIR=/opt/cuda-runtime
ENV PATH=${LLAMACPP_DIR}:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_RUNTIME_DIR}:${LD_LIBRARY_PATH}

ENV LLAMA_HOST=0.0.0.0
ENV LLAMA_PORT=8001
ENV LLAMA_CTX_SIZE=131072
ENV LLAMA_CACHE=/models

# ANTHROPIC_AUTH_TOKEN is empty so the SDK falls through to ANTHROPIC_API_KEY.
ENV ANTHROPIC_BASE_URL=http://localhost:8001
ENV ANTHROPIC_API_KEY=sk-no-key-required
ENV ANTHROPIC_AUTH_TOKEN=

RUN echo 'deb https://bunny.deb.parrot.sh/parrot echo main contrib non-free non-free-firmware' > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/*.list \
    && apt-get update \
    && apt-get upgrade -y --fix-missing \
    && apt-get install -y --no-install-recommends \
        jq \
        ripgrep \
        zstd \
        ca-certificates \
        curl \
        libgomp1 \
        libcurl4 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

RUN mkdir -p ${LLAMACPP_DIR} ${CUDA_RUNTIME_DIR}
COPY --from=llamacpp_build /llama.cpp/build/bin/llama-server     ${LLAMACPP_DIR}/
COPY --from=llamacpp_build /llama.cpp/build/bin/llama-cli        ${LLAMACPP_DIR}/
COPY --from=llamacpp_build /llama.cpp/build/bin/llama-mtmd-cli   ${LLAMACPP_DIR}/
COPY --from=llamacpp_build /llama.cpp/build/bin/llama-gguf-split ${LLAMACPP_DIR}/

# CUDA runtime libs. libcuda.so.1 comes from the host driver at runtime.
COPY --from=cuda_runtime /usr/local/cuda/targets/x86_64-linux/lib/libcudart.so.12   ${CUDA_RUNTIME_DIR}/
COPY --from=cuda_runtime /usr/local/cuda/targets/x86_64-linux/lib/libcublas.so.12   ${CUDA_RUNTIME_DIR}/
COPY --from=cuda_runtime /usr/local/cuda/targets/x86_64-linux/lib/libcublasLt.so.12 ${CUDA_RUNTIME_DIR}/
COPY --from=cuda_runtime /usr/lib/x86_64-linux-gnu/libnccl.so.2                     ${CUDA_RUNTIME_DIR}/

RUN chmod +x ${LLAMACPP_DIR}/llama-server \
             ${LLAMACPP_DIR}/llama-cli \
             ${LLAMACPP_DIR}/llama-mtmd-cli \
             ${LLAMACPP_DIR}/llama-gguf-split

WORKDIR /workspace

EXPOSE 8001

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
