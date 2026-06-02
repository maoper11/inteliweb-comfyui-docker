Run ComfyUI. ComfyUI-Manager pre-installed in the image. On first boot, ComfyUI is copied to your workspace — when you see `[ComfyUI-Manager] All startup tasks have been completed.` in the logs, it's ready to use.

## Version

- ComfyUI: v0.23.0
- Python: 3.12
- Torch: 2.10.0+cu130
- Torchvision: 0.25.0+cu130
- Torchaudio: 2.10.0+cu130
- CUDA profile: cu130

## Pre-installed custom nodes:

- ComfyUI-Manager

## Access

- `8188`: ComfyUI web UI
- `8080`: FileBrowser
- `8888`: JupyterLab
- `22`: SSH

## Custom Arguments

Edit `/workspace/runpod-slim/comfyui_args.txt` (one arg per line):

```
--max-batch-size 8
--preview-method auto
```

## Directory Structure

- `/workspace/runpod-slim/ComfyUI`: ComfyUI install
- `/workspace/runpod-slim/comfyui_args.txt`: ComfyUI args
- `/workspace/runpod-slim/filebrowser.db`: FileBrowser DB

---

Built with ❤️ by [Inteliweb AI](https://www.youtube.com/@InteliwebAI)
