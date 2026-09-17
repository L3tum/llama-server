# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
ARG CUDA_DEVEL_IMAGE=nvidia/cuda:13.3.1-devel-ubuntu24.04@sha256:4ff859525f99de5782aa73607ce24219b07dddd48d12b97c1c301d7e1cfb0a87
ARG CUDA_RUNTIME_IMAGE=nvidia/cuda:13.3.1-runtime-ubuntu24.04@sha256:63da350831208559df18c7b8f3e0d5d1c984eaa815cdde690aacd6606cd0cb11
ARG LLAMA_CPP_COMMIT=xxx
ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
ARG GO_VERSION="1.26.3"

# ===== STAGE 1: Build llama.cpp =====
FROM ${CUDA_DEVEL_IMAGE} AS llama_cpp_build
ARG LLAMA_CPP_COMMIT
ARG LLAMA_CPP_REPO

# --- Layer 1: Install build tools (cached unless you change this block) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    cmake \
    ninja-build \
    build-essential \
    ccache \
&& rm -rf /var/lib/apt/lists/*

# --- Layer 2: Configure ccache (cached) ---
ENV CCACHE_DIR=/root/.ccache
ENV CC="ccache gcc"
ENV CXX="ccache g++"
ENV NVCC_CCOMPILER="ccache gcc"
ENV NVCC_CXXCOMPILER="ccache g++"
RUN ccache --max-size=2G --set-config=hash_dir=false

# --- Layer 3: CUDA stubs (cached, rarely changes) ---
ENV CUDA_STUBS=/usr/local/cuda/lib64/stubs
RUN test -e "${CUDA_STUBS}/libcuda.so.1" || ln -s "${CUDA_STUBS}/libcuda.so" "${CUDA_STUBS}/libcuda.so.1"
ENV LIBRARY_PATH=${CUDA_STUBS}:${LIBRARY_PATH}
ENV LD_LIBRARY_PATH=${CUDA_STUBS}:${LD_LIBRARY_PATH}

# --- Layer 4: Clone source (INVALIDATES on repo or ref change) ---
WORKDIR /src/llama.cpp
RUN git init \
    && git remote add origin "$LLAMA_CPP_REPO" \
    && git fetch --depth=1 origin "$LLAMA_CPP_COMMIT" \
    && git checkout FETCH_HEAD

# --- Layer 5: CMake configure (separated so cache is reused) ---
RUN cmake -S . -B build -G Ninja \
    -DGGML_CUDA=ON \
    -DGGML_NATIVE=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DCMAKE_CUDA_ARCHITECTURES_NATIVE=120 \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_SCHED_MAX_COPIES=2 \
    -DGGML_CUDA_GRAPHS=ON \
    -DGGML_CUDA_USE_GRAPHS=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-L${CUDA_STUBS} -Wl,-rpath-link,${CUDA_STUBS}"

# --- Layer 6: Build (ccache + ninja cache = fast rebuilds) ---
RUN --mount=type=cache,target=/root/.ccache,sharing=locked \
    cmake --build build -j4 \
    && ccache -s

# --- Layer 7: Copy outputs ---
RUN mkdir -p /out/llama/bin /out/llama/lib && \
    cp -av build/bin/llama-server /out/llama/bin/ && \
    cp -av build/bin/llama-bench /out/llama/bin/ && \
    cp -av build/bin/llama-fit-params /out/llama/bin/ && \
    cp -av build/bin/*.so /out/llama/lib/ 2>/dev/null; true && \
    ldd build/bin/llama-server | tee /out/llama/ldd.txt && \
    for exe in build/bin/llama-server build/bin/llama-bench build/bin/llama-fit-params; do \
      ldd "$exe" | awk '/=> \// { print $3 }' | grep -v '^\s*$'; \
    done | sort -u | while read -r lib; do \
      cp -f "$lib" /out/llama/lib/ 2>/dev/null || true; \
    done; \
    rm -f /out/llama/lib/libcuda.so && rm -f /out/llama/lib/libcuda.so.1

# ===== STAGE 2: Runtime =====
FROM ${CUDA_RUNTIME_IMAGE}
WORKDIR /app
ENTRYPOINT ["llama-server"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    tini \
    libgomp1 \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && . /etc/os-release \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

COPY --from=llama_cpp_build /out/llama/bin/llama-server /usr/local/bin/llama-server
COPY --from=llama_cpp_build /out/llama/lib/ /usr/local/lib/llama/
COPY --from=llama_cpp_build /out/llama/ldd.txt /usr/local/share/llama-server-ldd.txt

RUN echo "/usr/local/lib/llama" > /etc/ld.so.conf.d/llama.conf && ldconfig
RUN set -eux; \
    ldd /usr/local/bin/llama-server | tee /usr/local/share/llama-server-runtime-ldd.txt; \
    missing="$(ldd /usr/local/bin/llama-server | grep 'not found' | \
      grep -v 'libcuda.so.1' || true)"; \
    if [ -n "$missing" ]; then \
      echo "FATAL: missing libraries: $missing"; \
      exit 1; \
    fi
