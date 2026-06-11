# Inteliweb ComfyUI Docker – Developer Context

This document describes the current developer conventions for this repository: build targets, Docker image recipes, runtime behavior, dependency management, customization points, quality gates, and troubleshooting.

This repository is based on the official RunPod ComfyUI Docker template, customized by Inteliweb AI to provide clean ComfyUI Docker images with only **ComfyUI-Manager** preinstalled.

The current approach follows a recipe-based Docker Buildx Bake workflow similar to `ashleykleynhans/comfyui-docker`: one parametrized `Dockerfile`, multiple explicit targets in `docker-bake.hcl`, and clearly named image tags per ComfyUI / Torch / CUDA / Python combination.

---

## Stack Overview

### Primary stack

- **Base OS**: Ubuntu 24.04
- **Base images**:
  - `nvidia/cuda:13.0.0-cudnn-devel-ubuntu24.04` for the `cu130` recipe
  - `nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04` for the `cu128` recipe

- **ComfyUI**: `v0.24.0`
- **Python**: 3.12
- **Torch**: 2.10.0
- **Triton**: 3.6.0
- **xformers**: intentionally not installed
- **Preinstalled custom nodes**:
  - ComfyUI-Manager only

### GPU targets

The `cu130` recipe is the primary target for RTX 50 / Blackwell GPUs.

Recommended GPUs:

```text
NVIDIA RTX 5090
NVIDIA RTX 5080
NVIDIA RTX 4090
NVIDIA RTX 3090
NVIDIA RTX 3090 Ti
```

The `cu128` recipe is maintained as a CUDA 12.8 alternative for environments where CUDA 13 is not desired or where CUDA 12.8 is more compatible.

---

## Repository Layout

```text
Dockerfile
docker-bake.hcl
start.sh
README.md
docs/context.md
scripts/prebake-manager-cache.py
```

### File roles

- `Dockerfile`  
  Parametrized image definition. Receives the base image, ComfyUI version, Torch stack, Triton version, ComfyUI-Manager SHA, and FileBrowser version from `docker-bake.hcl`.

- `docker-bake.hcl`  
  Recipe catalog. Defines production and dev targets for each CUDA/Python/Torch/ComfyUI combination.

- `start.sh`  
  Runtime bootstrap script. Starts SSH, FileBrowser, JupyterLab, creates the ComfyUI workspace if needed, creates `.venv`, and launches ComfyUI.

- `scripts/prebake-manager-cache.py`  
  Pre-populates ComfyUI-Manager cache during build to reduce first-start latency.

- `docs/context.md`  
  Developer conventions and implementation notes.

---

## Docker Image Repository

Main Docker Hub repository:

```text
maoper/inteliweb-comfyui
```

Use explicit tags. Do not rely on `latest`.

Current production tags:

```text
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
```

Current local dev tags:

```text
maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu130-py312
maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu128-py312
```

---

## Build Targets

Use Docker Buildx Bake with `docker-bake.hcl`.

### Default target

The default build target is:

```text
cu130-py312
```

Command:

```bash
docker buildx bake
```

Equivalent explicit command:

```bash
docker buildx bake cu130-py312
```

Because the production targets use:

```hcl
output = ["type=registry"]
```

they push to Docker Hub when the build succeeds.

---

### `cu130-py312`

Production target for CUDA 13.0 / cu130.

```text
ComfyUI: v0.24.0
Python: 3.12
Torch: 2.10.0+cu130
Torchvision: 0.25.0+cu130
Torchaudio: 2.10.0+cu130
Triton: 3.6.0
Base image: nvidia/cuda:13.0.0-cudnn-devel-ubuntu24.04
Tag: maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
Output: registry
```

Build and publish:

```bash
docker login
docker buildx bake cu130-py312 --no-cache
```

---

### `dev-cu130-py312`

Local testing target for CUDA 13.0 / cu130.

```text
Tag: maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu130-py312
Output: local Docker image
```

Build locally:

```bash
docker buildx bake dev-cu130-py312 --no-cache
```

Run locally:

```bash
docker run --rm -it --gpus=all \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu130-py312
```

---

### `cu128-py312`

Production target for CUDA 12.8 / cu128.

```text
ComfyUI: v0.24.0
Python: 3.12
Torch: 2.10.0+cu128
Torchvision: 0.25.0+cu128
Torchaudio: 2.10.0+cu128
Triton: 3.6.0
Base image: nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04
Tag: maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
Output: registry
```

Build and publish:

```bash
docker login
docker buildx bake cu128-py312 --no-cache
```

---

### `dev-cu128-py312`

Local testing target for CUDA 12.8 / cu128.

```text
Tag: maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu128-py312
Output: local Docker image
```

Build locally:

```bash
docker buildx bake dev-cu128-py312 --no-cache
```

Run locally:

```bash
docker run --rm -it --gpus=all \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu128-py312
```

---

## Docker Bake Conventions

Keep recipe values visible inside each target.

The repository intentionally avoids a large set of global version variables for fast-moving components. The goal is for each target to read like a complete recipe.

Global variables should only be used for values that rarely change:

```hcl
REGISTRY
REGISTRY_USER
APP
RELEASE
RELEASE_SUFFIX
MANAGER_SHA
FILEBROWSER_VERSION
```

Version values that define a specific recipe should stay directly inside each target:

```hcl
BASE_IMAGE
INDEX_URL
TORCH_VERSION
TORCHVISION_VERSION
TORCHAUDIO_VERSION
TRITON_VERSION
```

This makes it easier to add future combinations such as:

```text
ComfyUI v0.25.0 + Torch 2.11 + cu130 + Python 3.12
ComfyUI v0.24.0 + Torch 2.10 + cu128 + Python 3.12
ComfyUI v0.24.0 + Torch 2.10 + cu130 + Python 3.12
```

---

## Version Pins

Current shared pins:

```hcl
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
  default = "v0.24.0"
}

variable "RELEASE_SUFFIX" {
  default = ""
}

variable "MANAGER_SHA" {
  default = "395bb2442798b804ae672a12eb5433bc10af0212"
}

variable "FILEBROWSER_VERSION" {
  default = "v2.63.14"
}
```

Important convention:

```text
MANAGER_SHA is used only as a build input.
Do not include the Manager SHA in the public Docker Hub tag.
```

Public tags should stay clean:

```text
v0.24.0-torch2.10-cu130-py312
v0.24.0-torch2.10-cu128-py312
```

---

## Dependency Management

The current Dockerfile intentionally avoids the older `pip-compile` / `requirements.lock` / `--require-hashes` workflow.

The previous approach was more strict but made Torch/CUDA overrides fragile. The current approach is simpler and more stable for CUDA-specific images.

### Current dependency flow

1. Start from a NVIDIA CUDA + cuDNN development base image.
2. Install Python 3.12 and system tools.
3. Install the pinned Torch stack directly from the correct PyTorch wheel index:
   - `https://download.pytorch.org/whl/cu130`
   - `https://download.pytorch.org/whl/cu128`

4. Install pinned Triton:
   - `triton==3.6.0`

5. Download pinned ComfyUI source by tag:
   - `v0.24.0`

6. Download pinned ComfyUI-Manager source by commit SHA.

7. Initialize Git metadata for ComfyUI and ComfyUI-Manager so ComfyUI-Manager can detect versions and repositories.

8. Install ComfyUI requirements using constraints to prevent Torch from being upgraded or downgraded:

```text
torch
torchvision
torchaudio
triton
```

9. Install ComfyUI-Manager requirements.

10. Install extra utilities:
    - GitPython
    - opencv-python
    - jupyter
    - jupyter-resource-usage
    - jupyterlab-nvdashboard

11. Print the installed Python/Torch stack for information only.

### Important rules

Do not use:

```bash
pip install torch ... --no-deps
```

Torch must be installed with dependencies so the required NVIDIA runtime wheels are available.

Do not install:

```text
xformers
```

Triton is intentionally installed instead:

```text
triton==3.6.0
```

The version print block is informational only and should not compare expected values or fail the build.

---

## FileBrowser

FileBrowser is installed by version only.

Current version:

```text
v2.63.14
```

The Dockerfile downloads:

```text
https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz
```

The FileBrowser tarball is not currently validated with SHA256.

Reason:

```text
The goal is to simplify version updates.
To update FileBrowser, change only FILEBROWSER_VERSION in docker-bake.hcl.
```

Runtime defaults:

```text
Port: 8080
Root: /workspace
User: admin
Password: adminadmin12
```

---

## Runtime Behavior

Startup is handled by `start.sh`.

At container start:

1. SSH host keys are generated if needed.
2. If `PUBLIC_KEY` is provided, it is added to root `authorized_keys`.
3. If `PUBLIC_KEY` is not provided, a random root password is generated and printed to logs.
4. Environment variables are exported broadly for shell and SSH sessions.
5. FileBrowser is initialized if needed and started on port `8080`.
6. JupyterLab is started on port `8888`.
7. `comfyui_args.txt` is created if missing.
8. On first boot:
   - Baked ComfyUI is copied from `/opt/comfyui-baked` to the persistent workspace.
   - A Python 3.12 virtual environment is created at `.venv`.
   - The virtual environment is created with `--system-site-packages`, so it can use the preinstalled Torch stack from the image.

9. On subsequent boots:
   - Existing ComfyUI files are reused.
   - Existing `.venv` is reused.
   - No network install is required.

10. ComfyUI starts with:

```bash
python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header
```

Additional args can be added through `comfyui_args.txt`.

---

## Runtime Paths

Current runtime layout:

```text
/workspace/ComfyUI
/workspace/ComfyUI/.venv
/workspace/comfyui_args.txt
/workspace/filebrowser.db
```

---

## Ports

Expose these ports in RunPod, Vast.ai, or any compatible Docker platform:

| Service     | Port | Protocol |
| ----------- | ---: | -------- |
| ComfyUI     | 8188 | HTTP     |
| FileBrowser | 8080 | HTTP     |
| JupyterLab  | 8888 | HTTP     |
| SSH         |   22 | TCP      |

For RunPod templates, configure:

```text
HTTP ports:
8188
8080
8888

TCP ports:
22
```

---

## RunPod Template Configuration

### CUDA 13 / cu130 template

```text
Template Name:
ComfyUI 0.24.0 - Torch 2.10 CU130

Container Image:
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312

Container Start Command:
leave empty

Container Disk:
50 GB minimum
100 GB or more recommended

Volume Disk:
150 GB recommended

Volume Mount Path:
/workspace
```

### CUDA 12.8 / cu128 template

```text
Template Name:
ComfyUI 0.24.0 - Torch 2.10 CU128

Container Image:
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312

Container Start Command:
leave empty

Container Disk:
50 GB minimum
100 GB or more recommended

Volume Disk:
150 GB recommended

Volume Mount Path:
/workspace
```

---

## Environment Variables

Recognized at runtime:

### `PUBLIC_KEY`

If set, enables SSH key-based login for root.

If not set, a random root password is generated and printed to logs.

### `JUPYTER_PASSWORD`

If set, used as the JupyterLab token.

If not set, JupyterLab starts without a token.

### GPU/CUDA-related variables

These are propagated when present:

```text
CUDA*
LD_LIBRARY_PATH
PYTHONPATH
RUNPOD_*
```

---

## Preinstalled Custom Nodes

Only this custom node is baked into the image:

```text
ComfyUI-Manager
```

The following nodes are intentionally not baked:

```text
ComfyUI-KJNodes
Civicomfy
ComfyUI-RunpodDirect
EasyUse
rgthree
Crystools
```

Users can install additional custom nodes later through ComfyUI-Manager. Those installations are user-managed and may affect compatibility.

---

## Customization Points

### ComfyUI startup args

Edit:

```text
/workspace/runpod-slim/comfyui_args.txt
```

Example:

```text
--preview-method auto
--disable-smart-memory
```

If the workspace is later simplified, use:

```text
/workspace/comfyui_args.txt
```

### Add baked custom nodes

To add a custom node permanently:

1. Add version variables or recipe args in `docker-bake.hcl`.
2. Add a download block in the Dockerfile.
3. Add Git initialization if ComfyUI-Manager should detect it as a repository.
4. Install the node requirements with the Torch constraints file.
5. Rebuild the image.

### Change Torch version

To change the Torch stack:

1. Update the target recipe in `docker-bake.hcl`:
   - `BASE_IMAGE`
   - `INDEX_URL`
   - `TORCH_VERSION`
   - `TORCHVISION_VERSION`
   - `TORCHAUDIO_VERSION`
   - `TRITON_VERSION`

2. Rebuild the dev target:

```bash
docker buildx bake dev-cu130-py312 --no-cache
```

or:

```bash
docker buildx bake dev-cu128-py312 --no-cache
```

3. Verify the runtime result inside the container.

### Change ComfyUI version

Update:

```hcl
variable "RELEASE" {
  default = "v0.24.0"
}
```

or create a new target with a different `COMFYUI_VERSION`.

### Change ComfyUI-Manager version

Update:

```hcl
variable "MANAGER_SHA" {
  default = "395bb2442798b804ae672a12eb5433bc10af0212"
}
```

Keep the Manager SHA out of Docker Hub tags.

### Change FileBrowser version

Update only:

```hcl
variable "FILEBROWSER_VERSION" {
  default = "v2.63.14"
}
```

No SHA256 value is currently required.

---

## Local Development Tips

### Inspect Bake output

```bash
docker buildx bake --print
docker buildx bake all --print
docker buildx bake dev --print
```

### Build locally

```bash
docker buildx bake dev-cu130-py312 --no-cache
```

or:

```bash
docker buildx bake dev-cu128-py312 --no-cache
```

### Run locally

```bash
docker run --rm -it --gpus=all \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  -e JUPYTER_PASSWORD=yourtoken \
  -v "$PWD/workspace":/workspace \
  maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu130-py312
```

### Check installed stack

Inside the container:

```bash
python3 - <<'PY'
import sys
import torch
import torchvision
import torchaudio
import triton

print("python:", sys.version)
print("python exe:", sys.executable)
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("torchaudio:", torchaudio.__version__)
print("triton:", triton.__version__)
print("cuda:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
PY
```

Expected for cu130:

```text
torch: 2.10.0+cu130
torchvision: 0.25.0+cu130
torchaudio: 2.10.0+cu130
triton: 3.6.0
cuda: 13.0
```

Expected for cu128:

```text
torch: 2.10.0+cu128
torchvision: 0.25.0+cu128
torchaudio: 2.10.0+cu128
triton: 3.6.0
cuda: 12.8
```

---

## Quality Gates

Before publishing a new image:

1. Inspect Bake output:

```bash
docker buildx bake --print
```

2. Build the local dev target:

```bash
docker buildx bake dev-cu130-py312 --no-cache
```

or:

```bash
docker buildx bake dev-cu128-py312 --no-cache
```

3. Verify Docker image exists locally:

```bash
docker images | grep inteliweb-comfyui
```

4. Run the image locally or in RunPod.

5. Confirm ComfyUI starts on port `8188`.

6. Confirm FileBrowser starts on port `8080`.

7. Confirm JupyterLab starts on port `8888`.

8. Confirm SSH is available on port `22` if needed.

9. Confirm only ComfyUI-Manager is present in:

```text
/workspace/runpod-slim/ComfyUI/custom_nodes
```

or, after workspace simplification:

```text
/workspace/ComfyUI/custom_nodes
```

10. Confirm the Python executable path is:

```text
/workspace/runpod-slim/ComfyUI/.venv/bin/python
```

or, after workspace simplification:

```text
/workspace/ComfyUI/.venv/bin/python
```

11. Confirm the installed Torch stack matches the image tag.

12. Test a basic ComfyUI workflow.

---

## Troubleshooting

### ComfyUI not reachable on port 8188

Check container logs. ComfyUI runs in the foreground, so logs should go directly to stdout.

Check custom args:

```text
/workspace/runpod-slim/comfyui_args.txt
```

Remove invalid CLI args if necessary.

---

### Torch version does not match the tag

Run:

```bash
python3 - <<'PY'
import torch, torchvision, torchaudio
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("torchaudio:", torchaudio.__version__)
print("cuda:", torch.version.cuda)
PY
```

If Torch is not the intended version, rebuild without cache:

```bash
docker buildx bake dev-cu130-py312 --no-cache
```

or:

```bash
docker buildx bake dev-cu128-py312 --no-cache
```

---

### Missing CUDA libraries

Do not reinstall Torch with `--no-deps`.

The current build intentionally allows PyTorch to install its required NVIDIA runtime wheels.

If errors appear such as:

```text
libcufile.so.0 not found
libcupti.so.12 not found
```

check that the Dockerfile still installs Torch without `--no-deps` and uses the correct `INDEX_URL`.

---

### Wrong Triton version

For Torch 2.10, use:

```text
triton==3.6.0
```

Do not use:

```text
triton-windows
```

inside Linux Docker images.

---

### Old `.venv-cu128` or `.venv-cu130` still appears

This usually means the Pod is using an old persistent volume created before the generic `.venv` convention.

For a clean test, use a new volume or delete the old venvs:

```bash
rm -rf /workspace/runpod-slim/ComfyUI/.venv-cu128
rm -rf /workspace/runpod-slim/ComfyUI/.venv-cu130
rm -rf /workspace/runpod-slim/ComfyUI/.venv
```

Then restart the Pod.

---

### FileBrowser login

Default FileBrowser settings are initialized on first boot.

FileBrowser runs on:

```text
8080
```

Default login:

```text
username: admin
password: adminadmin12
```

---

### JupyterLab token

Set:

```text
JUPYTER_PASSWORD
```

in the template environment variables if a fixed token is desired.

---

### SSH access

Expose TCP port:

```text
22
```

If `PUBLIC_KEY` is provided, it is used for root SSH login. Otherwise, a generated root password should appear in logs.

---

## Release & Tagging

Use explicit tags. Avoid relying only on `latest`.

Recommended tag format:

```text
v<COMFYUI_VERSION>-torch<TORCH_VERSION>-cu<CUDA_PROFILE>-py312
```

Current production images:

```text
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
```

Current dev images:

```text
maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu130-py312
maoper/inteliweb-comfyui:dev-v0.24.0-torch2.10-cu128-py312
```

Future variants should use separate explicit tags:

```text
maoper/inteliweb-comfyui:v0.25.0-torch2.11-cu130-py312
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
maoper/inteliweb-comfyui:v0.24.0-torch2.12-cu130-py312
```

---

## Git Workflow

Recommended flow:

```bash
git status
git add Dockerfile docker-bake.hcl start.sh README.md docs/context.md
git commit -m "Update ComfyUI Docker context for v0.24 Torch 2.10 recipes"
git push
```

If working in a feature branch:

```bash
git push origin comfy024-torch210-recipes
```

Then create a Pull Request into `main`.

---

## Notes on Image Size

The current images are larger than the earlier Ubuntu-only multi-stage image because they start from NVIDIA CUDA + cuDNN `devel` base images and install Torch with its dependencies.

This is intentional for stability.

Possible future optimization:

```text
Use a multi-stage build:
- Builder: nvidia/cuda:*cudnn-devel-ubuntu24.04
- Runtime: nvidia/cuda:*cudnn-runtime-ubuntu24.04
```

Do not optimize image size until both `cu130` and `cu128` recipes are validated in RunPod.

---

## License

This repository is derived from the official RunPod ComfyUI Docker template and retains the original GPLv3 license unless otherwise changed in `LICENSE`.
