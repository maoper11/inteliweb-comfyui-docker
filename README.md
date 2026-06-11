# Inteliweb ComfyUI Docker

Run ComfyUI in a ready-to-use GPU Docker image with **ComfyUI-Manager pre-installed**.

This image is designed for RunPod, Vast.ai, and local Docker environments. On first boot, the baked ComfyUI installation is copied into your persistent workspace. When you see this message in the logs, ComfyUI is ready:

```text
[ComfyUI-Manager] All startup tasks have been completed.
```

Built and maintained by [Inteliweb AI](https://www.youtube.com/@InteliwebAI).

---

## Available Images

Docker Hub repository:

```text
maoper/inteliweb-comfyui
```

### CUDA 13 / cu130

Recommended for RTX 50 series / Blackwell and environments where CUDA 13 is preferred.

```text
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
```

### CUDA 12.8 / cu128

Recommended for broader compatibility with RTX 30 / RTX 40 / RTX 50 environments where CUDA 12.8 is preferred.

```text
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
```

---

## Version

Current release:

- **ComfyUI**: `v0.24.0`
- **Python**: `3.12`
- **Torch**: `2.10.0`
- **Torchvision**: `0.25.0`
- **Torchaudio**: `2.10.0`
- **Triton**: `3.6.0`
- **Custom nodes pre-installed**: `ComfyUI-Manager`
- **xFormers**: not installed

CUDA-specific builds:

| Image Tag                       | CUDA Profile      | Torch Wheel           |
| ------------------------------- | ----------------- | --------------------- |
| `v0.24.0-torch2.10-cu130-py312` | CUDA 13.0 / cu130 | `torch==2.10.0+cu130` |
| `v0.24.0-torch2.10-cu128-py312` | CUDA 12.8 / cu128 | `torch==2.10.0+cu128` |

---

## Pre-installed Custom Nodes

Only the following custom node is baked into the image:

```text
ComfyUI-Manager
```

No additional workflow-specific custom nodes are pre-installed.

This keeps the image clean and flexible. You can install additional custom nodes later through ComfyUI-Manager.

---

## Access

Expose these ports in RunPod, Vast.ai, or your local Docker environment:

| Service        |   Port |
| -------------- | -----: |
| ComfyUI Web UI | `8188` |
| FileBrowser    | `8080` |
| JupyterLab     | `8888` |
| SSH            |   `22` |

Default URLs when running locally:

```text
http://localhost:8188
http://localhost:8080
http://localhost:8888
```

---

## Runtime Directory Structure

The container uses `/workspace` as the main persistent workspace.

```text
/workspace/ComfyUI
/workspace/ComfyUI/.venv
/workspace/ComfyUI/models
/workspace/ComfyUI/custom_nodes
/workspace/comfyui_args.txt
/workspace/filebrowser.db
```

Main paths:

| Path                              | Purpose                                    |
| --------------------------------- | ------------------------------------------ |
| `/workspace/ComfyUI`              | ComfyUI installation                       |
| `/workspace/ComfyUI/.venv`        | Python virtual environment used by ComfyUI |
| `/workspace/ComfyUI/models`       | Model storage                              |
| `/workspace/ComfyUI/custom_nodes` | Custom nodes                               |
| `/workspace/comfyui_args.txt`     | Optional ComfyUI startup arguments         |
| `/workspace/filebrowser.db`       | FileBrowser database                       |

---

## First Boot Behavior

On first boot:

1. SSH is configured.
2. FileBrowser starts on port `8080`.
3. JupyterLab starts on port `8888`.
4. ComfyUI is copied from the baked image into:

```text
/workspace/ComfyUI
```

5. A virtual environment is created at:

```text
/workspace/ComfyUI/.venv
```

6. ComfyUI starts on port `8188`.

The image installs the base Python packages during the Docker build. The runtime virtual environment uses `--system-site-packages`, so packages such as Torch, Torchvision, Torchaudio, Triton, and ComfyUI dependencies are available immediately without reinstalling them on every boot.

---

## Custom Arguments

You can add custom ComfyUI startup arguments by editing:

```text
/workspace/comfyui_args.txt
```

Add one argument per line:

```text
--preview-method auto
--disable-smart-memory
```

These arguments are appended to the default ComfyUI startup command:

```bash
python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header
```

Lines starting with `#` are ignored.

---

## Run Locally

Example for CUDA 13 / cu130:

```bash
docker run --rm -it --gpus=all \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
```

Example with a persistent local workspace:

```bash
docker run --rm -it --gpus=all \
  -p 8188:8188 \
  -p 8080:8080 \
  -p 8888:8888 \
  -p 2222:22 \
  -v "$PWD/workspace:/workspace" \
  maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
```

On Windows PowerShell:

```powershell
docker run --rm -it --gpus=all `
  -p 8188:8188 `
  -p 8080:8080 `
  -p 8888:8888 `
  -p 2222:22 `
  -v "${PWD}\workspace:/workspace" `
  maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312
```

---

## RunPod Template Settings

Recommended RunPod Pod Template settings:

```text
Container Image:
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu130-py312

Container Start Command:
leave empty

HTTP Ports:
8188, 8080, 8888

TCP Ports:
22

Volume Mount Path:
/workspace
```

Recommended storage:

```text
Container Disk:
50 GB minimum

Volume Disk:
150 GB or more recommended
```

Recommended GPUs for the `cu130` image:

```text
RTX 5090
RTX 5080
RTX 4090
RTX 3090
```

For maximum compatibility with RTX 30 / RTX 40 machines, you can also test the `cu128` image:

```text
maoper/inteliweb-comfyui:v0.24.0-torch2.10-cu128-py312
```

---

## Verify Installed Versions

Inside the container:

```bash
python3 - <<'PY'
import sys
import torch
import torchvision
import torchaudio
import triton

print("python:", sys.version)
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

Expected for the cu130 image:

```text
torch: 2.10.0+cu130
torchvision: 0.25.0+cu130
torchaudio: 2.10.0+cu130
triton: 3.6.0
cuda: 13.0
cuda available: True
```

Expected for the cu128 image:

```text
torch: 2.10.0+cu128
torchvision: 0.25.0+cu128
torchaudio: 2.10.0+cu128
triton: 3.6.0
cuda: 12.8
cuda available: True
```

---

## Build Targets

This repository uses Docker Buildx Bake.

Check the resolved build configuration:

```bash
docker buildx bake --print
```

Build local dev images:

```bash
docker buildx bake dev-cu130-py312 --no-cache
docker buildx bake dev-cu128-py312 --no-cache
```

Publish production images:

```bash
docker login

docker buildx bake cu130-py312 --no-cache
docker buildx bake cu128-py312 --no-cache
```

Build all production targets:

```bash
docker buildx bake all --no-cache
```

Build all dev targets:

```bash
docker buildx bake dev --no-cache
```

---

## Notes

- FileBrowser runs on port `8080`.
- JupyterLab runs on port `8888`.
- SSH runs on port `22`.
- ComfyUI runs on port `8188`.
- If `PUBLIC_KEY` is provided, SSH key login is enabled.
- If `PUBLIC_KEY` is not provided, a random root password is generated and printed in the logs.
- If `JUPYTER_PASSWORD` is provided, it is used as the JupyterLab token.

---

## Troubleshooting

### ComfyUI does not open

Check the container logs and verify that ComfyUI printed:

```text
To see the GUI go to: http://0.0.0.0:8188
```

When running locally, open:

```text
http://localhost:8188
```

### FileBrowser login

Default FileBrowser credentials:

```text
Username: admin
Password: adminadmin12
```

Change the password after first login if the container is exposed publicly.

### ComfyUI arguments break startup

Edit:

```text
/workspace/comfyui_args.txt
```

Remove invalid arguments and restart the container.

### Models are missing after restart

Make sure your persistent volume is mounted to:

```text
/workspace
```

Models should be placed under:

```text
/workspace/ComfyUI/models
```

---

## Built by Inteliweb AI

Built with ❤️ by [Inteliweb AI](https://www.youtube.com/@InteliwebAI)
