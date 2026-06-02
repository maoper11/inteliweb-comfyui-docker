# Inteliweb ComfyUI Docker – Developer Conventions

This document outlines how to work in this repository from a developer point of view: build targets, runtime behavior, environment, dependency management, customization points, quality gates, and troubleshooting.

This repository is based on the official RunPod ComfyUI Docker template, customized by Inteliweb AI to provide a clean CUDA 13 / cu130 ComfyUI image with only ComfyUI-Manager preinstalled.

---

## Stack Overview

- **Base OS**: Ubuntu 24.04
- **GPU stack**:
  - CUDA 13.0
  - PyTorch cu130 wheels
  - Targeted primarily for RTX 5090 / Blackwell and other NVIDIA GPUs compatible with the selected CUDA/PyTorch stack

- **Python**: 3.12, set as the default system Python inside the image
- **Package manager**: pip + pip-tools
- **Dependency approach**:
  - ComfyUI and ComfyUI-Manager requirements are installed during the Docker build
  - Torch, torchvision, torchaudio, and Triton are then force-reinstalled to the required cu130 stack
  - A non-blocking Torch stack verification is printed during build

- **Tools bundled**:
  - FileBrowser on port `8080`
  - JupyterLab on port `8888`
  - OpenSSH server on port `22`
  - FFmpeg
  - Common CLI tools

- **Primary app**: ComfyUI
- **Preinstalled custom nodes**:
  - ComfyUI-Manager only

---

## Repository Layout

- `Dockerfile` – Main Dockerfile for the cu130 image
- `start.sh` – Runtime bootstrap script
- `docker-bake.hcl` – Docker Buildx Bake targets and version pins
- `README.md` – User-facing overview
- `docs/context.md` – Developer conventions and internal implementation notes

At runtime, the container uses:

- `/workspace/runpod-slim/ComfyUI` – ComfyUI checkout and virtual environment
- `/workspace/runpod-slim/ComfyUI/.venv-cu130` – Python virtual environment used by ComfyUI
- `/workspace/runpod-slim/comfyui_args.txt` – Optional line-delimited ComfyUI startup args
- `/workspace/runpod-slim/filebrowser.db` – FileBrowser database

---

## Docker Image

Main Docker Hub repository:

```text
maoper/inteliweb-comfyui
```

Recommended production tag:

```text
maoper/inteliweb-comfyui:v0.23.0-torch2.10-cu130-py312
```

This tag name indicates the intended stack:

- ComfyUI `v0.23.0`
- Torch `2.10.0+cu130`
- Python `3.12`
- CUDA / PyTorch wheel profile `cu130`

The build includes a verification step that prints the installed Torch stack. The verification is intentionally non-blocking: it warns if versions do not match but does not stop the Docker build.

---

## Build Targets

Use Docker Buildx Bake with the provided `docker-bake.hcl`.

### `dev`

Local testing target.

- Platform: `linux/amd64`
- Output: local Docker image
- Tag:

```text
maoper/inteliweb-comfyui:dev-cu130
```

Command:

```bash
docker buildx bake dev
```

For a clean rebuild:

```bash
docker buildx bake dev --no-cache
```

---

### `cu130`

Production target.

- Platform: `linux/amd64`
- Output: Docker registry
- Tag:

```text
maoper/inteliweb-comfyui:v0.23.0-torch2.10-cu130-py312
```

Command:

```bash
docker buildx bake cu130
```

If the target does not define `output = ["type=registry"]`, use:

```bash
docker buildx bake cu130 --push
```

---

## Version Pins

The main version pins live in `docker-bake.hcl`.

Expected key variables:

```hcl
variable "DOCKER_REPO" {
  default = "maoper/inteliweb-comfyui"
}

variable "TAG" {
  default = "v0.23.0-torch2.10-cu130-py312"
}

variable "COMFYUI_VERSION" {
  default = "v0.23.0"
}

variable "MANAGER_SHA" {
  default = "66108ccdbc8c"
}

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
```

The cu130 build target should pass:

```hcl
CUDA_VERSION_DASH = "13-0"
TORCH_INDEX_SUFFIX = "cu130"
```

---

## Dependency Management

Python dependencies are installed at image build time.

The Dockerfile follows this general flow:

1. Download ComfyUI source archive based on `COMFYUI_VERSION`.
2. Download ComfyUI-Manager source archive based on `MANAGER_SHA`.
3. Initialize Git metadata for ComfyUI and ComfyUI-Manager so ComfyUI-Manager can detect repositories correctly.
4. Build a `requirements.in` file from:
   - `ComfyUI/requirements.txt`
   - `ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt`
   - extra tools such as JupyterLab and OpenCV

5. Use `pip-compile` to generate a hashed `requirements.lock`.
6. Install the locked requirements.
7. Uninstall any previously resolved Torch stack.
8. Force-install the required cu130 Torch stack:
   - `torch==2.10.0+cu130`
   - `torchvision==0.25.0+cu130`
   - `torchaudio==2.10.0+cu130`

9. Install Triton:
   - `triton>=3.6,<3.7`

10. Run a non-blocking verification that prints the actual installed Torch stack.

The Torch verification should not raise an exception or stop the build. It should only print warnings if the installed versions do not match the expected values.

Example expected output:

```text
Torch stack verification
Expected: {'torch': '2.10.0+cu130', 'torchvision': '0.25.0+cu130', 'torchaudio': '2.10.0+cu130', 'cuda': '13.0'}
Actual:   {'torch': '2.10.0+cu130', 'torchvision': '0.25.0+cu130', 'torchaudio': '2.10.0+cu130', 'cuda': '13.0'}
OK: Torch 2.10.0+cu130 stack pinned correctly.
```

If the result does not match, the build should continue but print warnings.

---

## Runtime Behavior

Startup is handled by `start.sh`.

At container start:

1. SSH host keys are generated if needed.
2. Environment variables are exported broadly for shell and SSH sessions.
3. FileBrowser is initialized and started on port `8080`.
4. JupyterLab is started on port `8888`.
5. `/workspace/runpod-slim/comfyui_args.txt` is created if missing.
6. On first boot:
   - Baked ComfyUI is copied from `/opt/comfyui-baked` to `/workspace/runpod-slim/ComfyUI`
   - A Python 3.12 virtual environment is created at:

```text
/workspace/runpod-slim/ComfyUI/.venv-cu130
```

7. On subsequent boots:
   - The existing `.venv-cu130` environment is reused
   - No network install should be required

8. ComfyUI starts in the foreground with:

```bash
python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header
```

Additional args can be added through:

```text
/workspace/runpod-slim/comfyui_args.txt
```

One argument per line. Lines starting with `#` are ignored.

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

Recommended RunPod Pod Template values:

```text
Template Name:
ComfyUI 0.23.0 - Torch 2.10 CU130

Container Image:
maoper/inteliweb-comfyui:v0.23.0-torch2.10-cu130-py312

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

Recommended GPUs:

```text
NVIDIA RTX 5090
NVIDIA RTX 4090
NVIDIA RTX 3090
NVIDIA RTX 3090 Ti
```

The image is primarily built for CUDA 13 / cu130. RTX 5090 is the main target, but other NVIDIA GPUs may also run the image if the driver and stack are compatible.

---

## Environment Variables

Recognized at runtime:

- `PUBLIC_KEY`
  - If set, enables SSH key-based login for root.
  - If not set, a random root password is generated and printed to logs.

- `JUPYTER_PASSWORD`
  - If set, used as the JupyterLab token.

GPU/CUDA-related variables are propagated when present:

- `CUDA*`
- `LD_LIBRARY_PATH`
- `PYTHONPATH`
- `RUNPOD_*`

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
```

Users can install additional custom nodes later through ComfyUI-Manager. Those installations are user-managed and may affect compatibility.

---

## Customization Points

### ComfyUI args

Edit:

```text
/workspace/runpod-slim/comfyui_args.txt
```

Example:

```text
--preview-method auto
--disable-smart-memory
```

### Add baked custom nodes

To add a custom node permanently:

1. Add an `ARG` or version variable in `docker-bake.hcl`.
2. Add a download block in the Dockerfile.
3. Add Git initialization if ComfyUI-Manager should detect it as a repository.
4. Rebuild the image.

### Change Torch version

To change the Torch stack:

1. Edit these variables in `docker-bake.hcl`:

```hcl
TORCH_VERSION
TORCHVISION_VERSION
TORCHAUDIO_VERSION
TORCH_INDEX_SUFFIX
```

2. Update the expected values in the non-blocking verification block inside the Dockerfile.
3. Rebuild with:

```bash
docker buildx bake dev --no-cache
```

4. Verify the runtime result inside the container.

---

## Local Development Tips

Build locally:

```bash
docker buildx bake dev
```

Run locally:

```bash
docker run --rm -it \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  -e JUPYTER_PASSWORD=yourtoken \
  -v "$PWD/workspace":/workspace \
  maoper/inteliweb-comfyui:dev-cu130
```

Check the installed Torch stack:

```bash
docker run --rm -it maoper/inteliweb-comfyui:dev-cu130 bash
```

Inside the container:

```bash
python3 - <<'PY'
import torch, torchvision, torchaudio
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("torchaudio:", torchaudio.__version__)
print("cuda:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())
PY
```

Expected result:

```text
torch: 2.10.0+cu130
torchvision: 0.25.0+cu130
torchaudio: 2.10.0+cu130
cuda: 13.0
```

---

## Quality Gates

Before publishing a new image:

1. Build the local dev target:

```bash
docker buildx bake dev --no-cache
```

2. Verify Docker image exists locally:

```bash
docker images | grep inteliweb-comfyui
```

3. Run the image and verify:

```bash
python3 - <<'PY'
import torch, torchvision, torchaudio
print(torch.__version__)
print(torchvision.__version__)
print(torchaudio.__version__)
print(torch.version.cuda)
PY
```

4. Confirm ComfyUI starts on port `8188`.
5. Confirm FileBrowser starts on port `8080`.
6. Confirm JupyterLab starts on port `8888`.
7. Confirm SSH is available on port `22` if needed.
8. Confirm only ComfyUI-Manager is present in:

```text
/workspace/runpod-slim/ComfyUI/custom_nodes
```

9. Confirm the Python executable path is:

```text
/workspace/runpod-slim/ComfyUI/.venv-cu130/bin/python
```

---

## Troubleshooting

### ComfyUI not reachable on port 8188

Check container logs. ComfyUI runs in the foreground, so logs should go directly to stdout.

Also check:

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
docker buildx bake dev --no-cache
```

Then check the Docker build logs for the “Torch stack verification” section.

---

### Old `.venv-cu128` still appears

This usually means the Pod is using an old persistent volume created before the `.venv-cu130` rename.

For a clean test, use a new volume or delete the old venvs:

```bash
rm -rf /workspace/runpod-slim/ComfyUI/.venv-cu128
rm -rf /workspace/runpod-slim/ComfyUI/.venv-cu130
```

Then restart the Pod.

---

### FileBrowser login

Default FileBrowser settings are initialized on first boot. Check container logs for initialization messages.

FileBrowser runs on:

```text
8080
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
v<COMFYUI_VERSION>-torch<TORCH_VERSION>-cu130-py312
```

Current recommended tag:

```text
v0.23.0-torch2.10-cu130-py312
```

Production image:

```text
maoper/inteliweb-comfyui:v0.23.0-torch2.10-cu130-py312
```

For future variants, use separate tags:

```text
maoper/inteliweb-comfyui:v0.23.0-torch2.12-cu130-py312
maoper/inteliweb-comfyui:v0.23.0-torch2.10-cu128-py312
maoper/inteliweb-comfyui:v0.22.0-torch2.10-cu130-py312
```

---

## Git Workflow

Recommended flow:

```bash
git status
git add Dockerfile docker-bake.hcl start.sh README.md docs/context.md
git commit -m "Update cu130 ComfyUI Docker developer conventions"
git push
```

If working in a feature branch:

```bash
git push origin comfy023-cu130-manager-only
```

Then create a Pull Request into `main`.

---

## License

This repository is derived from the official RunPod ComfyUI Docker template and retains the original GPLv3 license unless otherwise changed in `LICENSE`.
