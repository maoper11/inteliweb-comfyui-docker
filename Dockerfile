ARG BASE_IMAGE=nvidia/cuda:13.0.0-cudnn-devel-ubuntu24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg
ENV FILEBROWSER_CONFIG=/workspace/.filebrowser.json

# Make pip less noisy and more reliable during runtime custom-node installs.
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV PIP_DEFAULT_TIMEOUT=120

# ---------------------------------------------------------------------------
# Build args from docker-bake.hcl
# ---------------------------------------------------------------------------

ARG RELEASE
ARG COMFYUI_VERSION
ARG MANAGER_SHA

ARG INDEX_URL
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION
ARG TRITON_VERSION

ARG FILEBROWSER_VERSION

ENV TEMPLATE_VERSION=${RELEASE}
ENV VENV_PATH=/workspace/ComfyUI/.venv

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        git \
        python3.12 \
        python3.12-venv \
        python3.12-dev \
        build-essential \
        libssl-dev \
        wget \
        gnupg \
        xz-utils \
        openssh-client \
        openssh-server \
        nano \
        curl \
        htop \
        tmux \
        ca-certificates \
        less \
        net-tools \
        iputils-ping \
        procps \
        openssl \
        ffmpeg \
        unzip \
        rsync \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# ---------------------------------------------------------------------------
# Python / pip
# ---------------------------------------------------------------------------

RUN curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py && \
    python3.12 /tmp/get-pip.py && \
    rm /tmp/get-pip.py && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --set python3 /usr/bin/python3.12 && \
    python3.12 -m pip install --no-cache-dir --upgrade pip setuptools wheel

# ---------------------------------------------------------------------------
# Install pinned Torch stack
# No --no-deps, so PyTorch can install required NVIDIA runtime wheels.
# No xformers.
# ---------------------------------------------------------------------------

RUN python3.12 -m pip install --no-cache-dir --force-reinstall \
        torch==${TORCH_VERSION} \
        torchvision==${TORCHVISION_VERSION} \
        torchaudio==${TORCHAUDIO_VERSION} \
        --index-url "${INDEX_URL}" && \
    python3.12 -m pip install --no-cache-dir --force-reinstall \
        triton==${TRITON_VERSION}

# ---------------------------------------------------------------------------
# Download pinned ComfyUI source
# ---------------------------------------------------------------------------

WORKDIR /tmp/build

RUN curl -fSL "https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/${COMFYUI_VERSION}.tar.gz" -o comfyui.tar.gz && \
    mkdir -p ComfyUI && \
    tar xzf comfyui.tar.gz --strip-components=1 -C ComfyUI && \
    rm comfyui.tar.gz

# ---------------------------------------------------------------------------
# Download pinned ComfyUI-Manager source
# ---------------------------------------------------------------------------

WORKDIR /tmp/build/ComfyUI/custom_nodes

RUN curl -fSL "https://github.com/Comfy-Org/ComfyUI-Manager/archive/${MANAGER_SHA}.tar.gz" -o manager.tar.gz && \
    mkdir -p ComfyUI-Manager && \
    tar xzf manager.tar.gz --strip-components=1 -C ComfyUI-Manager && \
    rm manager.tar.gz

# ---------------------------------------------------------------------------
# Init git metadata so ComfyUI and Manager can identify versions
# ---------------------------------------------------------------------------

RUN cd /tmp/build/ComfyUI && \
    git init && \
    git add -A && \
    git -c user.name=- -c user.email=- commit -q -m "ComfyUI ${COMFYUI_VERSION}" && \
    git tag "${COMFYUI_VERSION}" && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    cd /tmp/build/ComfyUI/custom_nodes/ComfyUI-Manager && \
    git init && \
    git add -A && \
    git -c user.name=- -c user.email=- commit -q -m "ComfyUI-Manager ${MANAGER_SHA}" && \
    git remote add origin https://github.com/Comfy-Org/ComfyUI-Manager.git

# ---------------------------------------------------------------------------
# Install ComfyUI + Manager requirements with Torch constraints
# This prevents ComfyUI requirements from upgrading/downgrading Torch.
# ---------------------------------------------------------------------------

WORKDIR /tmp/build

RUN printf "torch==%s\n" "${TORCH_VERSION}" > /opt/torch-constraints.txt && \
    printf "torchvision==%s\n" "${TORCHVISION_VERSION}" >> /opt/torch-constraints.txt && \
    printf "torchaudio==%s\n" "${TORCHAUDIO_VERSION}" >> /opt/torch-constraints.txt && \
    printf "triton==%s\n" "${TRITON_VERSION}" >> /opt/torch-constraints.txt && \
    python3.12 -m pip install --no-cache-dir \
        --extra-index-url "${INDEX_URL}" \
        -c /opt/torch-constraints.txt \
        -r /tmp/build/ComfyUI/requirements.txt && \
    if [ -f /tmp/build/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt ]; then \
        python3.12 -m pip install --no-cache-dir \
            --extra-index-url "${INDEX_URL}" \
            -c /opt/torch-constraints.txt \
            -r /tmp/build/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt; \
    fi && \
    python3.12 -m pip install --no-cache-dir \
        GitPython \
        opencv-python \
        jupyter \
        jupyter-resource-usage \
        jupyterlab-nvdashboard && \
    python3.12 -m pip --version && \
    python3.12 -m pip list --format=freeze > /tmp/pip-freeze-build.txt

# Keep Torch/Triton pinned during runtime custom-node installs.
# This prevents ComfyUI-Manager from accidentally upgrading/downgrading the baked CUDA stack.
ENV PIP_CONSTRAINT=/opt/torch-constraints.txt

# ---------------------------------------------------------------------------
# Informational version print only
# ---------------------------------------------------------------------------

RUN python3.12 - <<'PY'
print("============================================================")
print("Installed Python / Torch stack")
import sys
print("python:", sys.version)

try:
    import torch
    print("torch:", torch.__version__)
    print("cuda:", torch.version.cuda)
    print("cuda available during build:", torch.cuda.is_available())
except Exception as e:
    print("WARNING: torch import failed during build:", repr(e))

try:
    import torchvision
    print("torchvision:", torchvision.__version__)
except Exception as e:
    print("WARNING: torchvision import failed during build:", repr(e))

try:
    import torchaudio
    print("torchaudio:", torchaudio.__version__)
except Exception as e:
    print("WARNING: torchaudio import failed during build:", repr(e))

try:
    import triton
    print("triton:", triton.__version__)
except Exception as e:
    print("WARNING: triton import failed during build:", repr(e))

print("============================================================")
PY

# Validate package tooling used later by ComfyUI-Manager.
# pip check is informational only because upstream packages may occasionally declare loose metadata.
RUN python3.12 -m pip --version && \
    python3.12 -m pip list --format=freeze > /tmp/pip-freeze-runtime-check.txt && \
    python3.12 -m pip check || true

# ---------------------------------------------------------------------------
# Pre-populate ComfyUI-Manager cache
# ---------------------------------------------------------------------------

COPY scripts/prebake-manager-cache.py /tmp/prebake-manager-cache.py

RUN python3.12 /tmp/prebake-manager-cache.py /tmp/build/ComfyUI/user/__manager/cache

# ---------------------------------------------------------------------------
# Bake ComfyUI into image
# ---------------------------------------------------------------------------

RUN cp -r /tmp/build/ComfyUI /opt/comfyui-baked

# ---------------------------------------------------------------------------
# Remove uv to match the official RunPod strategy and force ComfyUI-Manager to use pip.
# uv can ignore --system-site-packages in this layout; pip is validated/warmed in start.sh.
# ---------------------------------------------------------------------------

RUN python3.12 -m pip uninstall -y uv 2>/dev/null || true && \
    rm -f /usr/local/bin/uv /usr/local/bin/uvx

# ---------------------------------------------------------------------------
# FileBrowser
# ---------------------------------------------------------------------------

RUN curl -fSL "https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" -o /tmp/fb.tar.gz && \
    tar xzf /tmp/fb.tar.gz -C /usr/local/bin filebrowser && \
    rm /tmp/fb.tar.gz

# ---------------------------------------------------------------------------
# Jupyter extensions
# ---------------------------------------------------------------------------

RUN mkdir -p /usr/local/etc/jupyter/jupyter_server_config.d && \
    echo '{"ServerApp":{"jpserver_extensions":{"jupyter_server_terminals":true,"jupyterlab":true,"jupyter_resource_usage":true,"jupyterlab_nvdashboard":true}}}' \
    > /usr/local/etc/jupyter/jupyter_server_config.d/extensions.json

# ---------------------------------------------------------------------------
# CUDA / NVIDIA runtime environment
# ---------------------------------------------------------------------------

ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64

ENV NVIDIA_REQUIRE_CUDA=""
ENV NVIDIA_DISABLE_REQUIRE=true
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd && \
    rm -f /etc/ssh/ssh_host_*

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

RUN mkdir -p /workspace

WORKDIR /workspace

EXPOSE 8188 22 8888 8080

COPY start.sh /start.sh
RUN chmod +x /start.sh

SHELL ["/bin/bash", "--login", "-c"]

ENTRYPOINT ["/start.sh"]