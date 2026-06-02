variable "DOCKER_REPO" {
  default = "maoper/inteliweb-comfyui"
}

variable "TAG" {
  default = "v0.23.0-torch2.10-cu130-py312"
}

# === Version Pins ===
variable "COMFYUI_VERSION" {
  default = "v0.23.0"
}

variable "MANAGER_SHA" {
  default = "66108ccdbc8c"
}

# CUDA 13 / cu130 image
variable "TORCH_VERSION" {
  default = "2.10.0+cu130"
}

variable "TORCHVISION_VERSION" {
  default = "0.25.0+cu130"
}

variable "TORCHAUDIO_VERSION" {
  default = "2.10.0+cu130"
}

variable "FILEBROWSER_VERSION" {
  default = "v2.59.0"
}

variable "FILEBROWSER_SHA256" {
  default = "8cd8c3baecb086028111b912f252a6e3169737fa764b5c510139e81f9da87799"
}

group "default" {
  targets = ["cu130"]
}

target "common" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64"]

  args = {
    COMFYUI_VERSION = COMFYUI_VERSION
    MANAGER_SHA = MANAGER_SHA
    TORCH_VERSION = TORCH_VERSION
    TORCHVISION_VERSION = TORCHVISION_VERSION
    TORCHAUDIO_VERSION = TORCHAUDIO_VERSION
    FILEBROWSER_VERSION = FILEBROWSER_VERSION
    FILEBROWSER_SHA256 = FILEBROWSER_SHA256
    CUDA_VERSION_DASH = "13-0"
    TORCH_INDEX_SUFFIX = "cu130"
  }
}

target "cu130" {
  inherits = ["common"]
  tags = [
    "${DOCKER_REPO}:${TAG}",
  ]
  output = ["type=registry"]
}

target "dev" {
  inherits = ["common"]
  tags = [
    "${DOCKER_REPO}:dev-cu130"
  ]
  output = ["type=docker"]
}