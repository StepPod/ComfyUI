# Set the base image
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Set the shell and enable pipefail for better error handling
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Set basic environment variables
ARG PYTHON_VERSION
ARG TORCH_VERSION
ARG CUDA_VERSION
ARG SKIP_CUSTOM_NODES

# Set basic environment variables
ENV SHELL=/bin/bash 
ENV PYTHONUNBUFFERED=True 
ENV DEBIAN_FRONTEND=noninteractive

# Set the default workspace directory
ENV RP_WORKSPACE=/workspace

# Override the default huggingface cache directory.
ENV HF_HOME="${RP_WORKSPACE}/.cache/huggingface/"

# Faster transfer of models from the hub to the container
ENV HF_HUB_ENABLE_HF_TRANSFER=1
ENV HF_XET_HIGH_PERFORMANCE=1

# Shared python package cache
ENV VIRTUALENV_OVERRIDE_APP_DATA="${RP_WORKSPACE}/.cache/virtualenv/"
ENV PIP_CACHE_DIR="${RP_WORKSPACE}/.cache/pip/"
ENV UV_CACHE_DIR="${RP_WORKSPACE}/.cache/uv/"

# modern pip workarounds
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore

# Set TZ and Locale
ENV TZ=Etc/UTC

# Set working directory
WORKDIR /

# Update and upgrade
RUN apt-get update --yes && \
    apt-get upgrade --yes

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen

# Install essential packages
RUN apt-get install --yes --no-install-recommends \
        git wget curl bash nginx-light rsync sudo binutils ffmpeg lshw nano tzdata file build-essential cmake nvtop \
        libgl1 libglib2.0-0 clang libomp-dev ninja-build \
        openssh-server ca-certificates && \
    apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install the UV tool from astral-sh
ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh
ENV PATH="/root/.local/bin/:$PATH"

# Install Python and create virtual environment
RUN uv python install ${PYTHON_VERSION} --default --preview && \
    uv venv --seed /venv
ENV PATH="/workspace/venv/bin:/venv/bin:$PATH"

# Install essential Python packages and dependencies
RUN pip install --no-cache-dir -U \
    pip setuptools wheel \
    jupyterlab jupyterlab_widgets ipykernel ipywidgets \
    huggingface_hub hf_transfer \
    numpy scipy matplotlib pandas scikit-learn seaborn requests tqdm pillow pyyaml \
    triton \
    torch==${TORCH_VERSION} torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/${CUDA_VERSION}

# Install ComfyUI and ComfyUI Manager
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd ComfyUI && \
    pip install --no-cache-dir -r requirements.txt && \
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager && \
    cd custom_nodes/ComfyUI-Manager && \
    pip install --no-cache-dir -r requirements.txt

COPY custom_nodes.txt /custom_nodes.txt

RUN if [ -z "$SKIP_CUSTOM_NODES" ]; then \
        cd /ComfyUI/custom_nodes && \
        xargs -n 1 git clone --recursive < /custom_nodes.txt && \
        find /ComfyUI/custom_nodes -name "requirements.txt" -exec pip install --no-cache-dir -r {} \; && \
        find /ComfyUI/custom_nodes -name "install.py" -exec python {} \; ; \
    else \
        echo "Skipping custom nodes installation because SKIP_CUSTOM_NODES is set"; \
    fi

# Install Runpod CLI
#RUN wget -qO- cli.runpod.net | sudo bash

# Install code-server
RUN curl -fsSL https://code-server.dev/install.sh | sh

EXPOSE 22 3000 8080 8888

# NGINX Proxy
COPY proxy/nginx.conf /etc/nginx/nginx.conf
COPY proxy/snippets /etc/nginx/snippets
COPY proxy/readme.html /usr/share/nginx/html/readme.html

# Remove existing SSH host keys
RUN rm -f /etc/ssh/ssh_host_*

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# Start Scripts
COPY --chmod=755 scripts/start.sh /
COPY --chmod=755 scripts/pre_start.sh /
COPY --chmod=755 scripts/post_start.sh /

COPY --chmod=755 scripts/download_presets.sh /
COPY --chmod=755 scripts/install_custom_nodes.sh /

# Welcome Message
COPY logo/steppod.txt /etc/steppod.txt
RUN echo 'cat /etc/steppod.txt' >> /root/.bashrc
RUN echo 'echo -e "Nice to meet you and We are Steppod administrator, Thank you."' >> /root/.bashrc

# Set entrypoint to the start script
CMD ["/bin/bash", "-c", " \
    echo '[Auto-Mount] /mnt 경로 하위에서 storage 패턴을 찾는 중...'; \
    \
    TARGET_MNT=$(find /mnt -maxdepth 1 -name 'storage*' -type d | head -n 1); \
    \
    if [ -z \"$TARGET_MNT\" ]; then \
        echo '[Auto-Mount] 경고: /mnt/storage* 패턴과 일치하는 경로를 찾지 못했습니다.'; \
        echo '[Auto-Mount] ComfyUI는 내부 기본 경로를 사용합니다.'; \
    else \
        echo \"[Auto-Mount] 스토리지 발견: $TARGET_MNT\"; \
        \
        # 2. 필수 폴더 생성 \
        mkdir -p \"$TARGET_MNT/checkpoints\" \"$TARGET_MNT/loras\" \"$TARGET_MNT/vae\" \
                 \"$TARGET_MNT/controlnet\" \"$TARGET_MNT/upscale_models\" \"$TARGET_MNT/embeddings\" \"$TARGET_MNT/output\"; \
        \
        # 3. 설정 파일 생성 (/ComfyUI 위치 확인 필) \
        printf \"comfyui:\\n    base_path: %s\\n    checkpoints: checkpoints/\\n    loras: loras/\\n    vae: vae/\\n    controlnet: controlnet/\\n    upscale_models: upscale_models/\\n    embeddings: embeddings/\\n\" \"$TARGET_MNT\" > /workspace/ComfyUI/extra_model_paths.yaml; \
        \
        echo '[Auto-Mount] extra_model_paths.yaml 설정 완료'; \
    fi; \
    \
    # 4. 원래의 시작 스크립트로 제어권 이양 \
    exec /start.sh \
"]