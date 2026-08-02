variable "REGISTRY" {
  default = "docker.io"
}

variable "REGISTRY_USER" {
  default = "maoper"
}

variable "APP" {
  default = "inteliweb-comfyui"
}

variable "RELEASE" {
  default = "v0.29.2"
}

variable "RELEASE_SUFFIX" {
  default = ""
}

variable "MANAGER_SHA" {
  default = "d404e6234acd609da830ebb9f01e3c975313473e"
}

variable "FILEBROWSER_VERSION" {
  default = "v2.63.18"
}

group "default" {
  targets = ["cu130-py312"]
}

group "all" {
  targets = [
    "cu130-py312",
    "cu128-py312"
  ]
}

group "dev" {
  targets = [
    "dev-cu130-py312",
    "dev-cu128-py312"
  ]
}

# ---------------------------------------------------------------------------
# Python 3.12
# Torch 2.10.0
# CUDA 13.0 / cu130
# Triton 3.6.0
# No xformers
# ---------------------------------------------------------------------------

target "cu130-py312" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]

  tags = [
    "${REGISTRY}/${REGISTRY_USER}/${APP}:${RELEASE}-torch2.10-cu130-py312"
  ]

  args = {
    RELEASE = "${RELEASE}"

    BASE_IMAGE = "nvidia/cuda:13.0.0-cudnn-devel-ubuntu24.04"

    COMFYUI_VERSION = "${RELEASE}"
    MANAGER_SHA = "${MANAGER_SHA}"

    INDEX_URL = "https://download.pytorch.org/whl/cu130"
    TORCH_VERSION = "2.10.0+cu130"
    TORCHVISION_VERSION = "0.25.0+cu130"
    TORCHAUDIO_VERSION = "2.10.0+cu130"
    TRITON_VERSION = "3.6.0"
    FILEBROWSER_VERSION = "${FILEBROWSER_VERSION}"
  }

  output = ["type=registry"]
}

target "dev-cu130-py312" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]

  tags = [
    "${REGISTRY}/${REGISTRY_USER}/${APP}:dev-${RELEASE}-torch2.10-cu130-py312"
  ]

  args = {
    RELEASE = "${RELEASE}"

    BASE_IMAGE = "nvidia/cuda:13.0.0-cudnn-devel-ubuntu24.04"

    COMFYUI_VERSION = "${RELEASE}"
    MANAGER_SHA = "${MANAGER_SHA}"

    INDEX_URL = "https://download.pytorch.org/whl/cu130"
    TORCH_VERSION = "2.10.0+cu130"
    TORCHVISION_VERSION = "0.25.0+cu130"
    TORCHAUDIO_VERSION = "2.10.0+cu130"
    TRITON_VERSION = "3.6.0"
    FILEBROWSER_VERSION = "${FILEBROWSER_VERSION}"
  }

  output = ["type=docker"]
}

# ---------------------------------------------------------------------------
# Python 3.12
# Torch 2.10.0
# CUDA 12.8 / cu128
# Triton 3.6.0
# No xformers
# ---------------------------------------------------------------------------

target "cu128-py312" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]

  tags = [
    "${REGISTRY}/${REGISTRY_USER}/${APP}:${RELEASE}-torch2.10-cu128-py312"
  ]

  args = {
    RELEASE = "${RELEASE}"

    BASE_IMAGE = "nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04"

    COMFYUI_VERSION = "${RELEASE}"
    MANAGER_SHA = "${MANAGER_SHA}"

    INDEX_URL = "https://download.pytorch.org/whl/cu128"
    TORCH_VERSION = "2.10.0+cu128"
    TORCHVISION_VERSION = "0.25.0+cu128"
    TORCHAUDIO_VERSION = "2.10.0+cu128"
    TRITON_VERSION = "3.6.0"
    FILEBROWSER_VERSION = "${FILEBROWSER_VERSION}"
  }

  output = ["type=registry"]
}

target "dev-cu128-py312" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]

  tags = [
    "${REGISTRY}/${REGISTRY_USER}/${APP}:dev-${RELEASE}-torch2.10-cu128-py312"
  ]

  args = {
    RELEASE = "${RELEASE}"

    BASE_IMAGE = "nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04"

    COMFYUI_VERSION = "${RELEASE}"
    MANAGER_SHA = "${MANAGER_SHA}"

    INDEX_URL = "https://download.pytorch.org/whl/cu128"
    TORCH_VERSION = "2.10.0+cu128"
    TORCHVISION_VERSION = "0.25.0+cu128"
    TORCHAUDIO_VERSION = "2.10.0+cu128"
    TRITON_VERSION = "3.6.0"
    FILEBROWSER_VERSION = "${FILEBROWSER_VERSION}"
  }

  output = ["type=docker"]
}