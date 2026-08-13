#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/filebrowser.db"
ARGS_FILE="/workspace/comfyui_args.txt"
CUDA_PREFLIGHT_LOG="/workspace/CUDA_PREFLIGHT.txt"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Prioritize CUDA runtime libraries shipped with the PyTorch/NVIDIA Python wheels.
#
# Why this is needed:
# - PyTorch wheels install matching NVIDIA runtime libraries under site-packages/nvidia/.
# - CUDA devel base images also install runtime libraries under /usr/local/cuda/lib64.
# - If LD_LIBRARY_PATH loads libcublas from the wheel but libcublasLt from the system CUDA
#   toolkit, simple torch matmul calls can fail with CUBLAS_STATUS_INVALID_VALUE.
#
# Keep /usr/local/cuda/bin in PATH for nvcc/headers/compilation, but prefer wheel libraries
# at runtime for torch, ComfyUI, and custom nodes.
configure_torch_cuda_runtime_libs() {
    echo "Configuring PyTorch CUDA runtime library priority..."

    local pybin="${PYTHON_BIN:-python3.12}"
    if ! command -v "$pybin" >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            pybin="python3"
        elif command -v python >/dev/null 2>&1; then
            pybin="python"
        else
            echo "WARNING: No Python interpreter found while configuring CUDA runtime libraries."
            return 0
        fi
    fi

    local torch_cuda_libs=""
    torch_cuda_libs="$($pybin - <<'PY' 2>/dev/null || true
import site
import sys
from pathlib import Path

roots = []
for item in site.getsitepackages() + [site.getusersitepackages()] + sys.path:
    if not item:
        continue
    try:
        p = Path(item)
    except TypeError:
        continue
    if p.exists() and p not in roots:
        roots.append(p)

# Prefer a stable, explicit order for the common NVIDIA wheel layouts.
# CUDA 13+ wheels commonly use nvidia/cu13/lib for most runtime libs.
# CUDA 12 wheels commonly use separate package directories such as nvidia/cublas/lib.
preferred_names = [
    "cu13", "cu14", "cu12", "cu11",
    "cublas", "cuda_runtime", "cuda_nvrtc", "cuda_cupti",
    "cudnn", "cufft", "cufile", "curand", "cusolver", "cusparse",
    "cusparselt", "nccl", "nvjitlink", "nvshmem", "nvtx",
]

found = []
seen = set()

def add_dir(path: Path):
    if not path.is_dir():
        return
    if not any(path.glob("*.so*")):
        return
    s = str(path)
    if s not in seen:
        seen.add(s)
        found.append(s)

for root in roots:
    nvidia_root = root / "nvidia"
    if not nvidia_root.exists():
        continue

    for name in preferred_names:
        add_dir(nvidia_root / name / "lib")

    # Future-proof fallback for new NVIDIA wheel package names.
    for d in sorted(nvidia_root.glob("*/lib")):
        add_dir(d)

print(":".join(found))
PY
)"

    local cupti_dir="/usr/local/cuda/extras/CUPTI/lib64"

    if [ -n "$torch_cuda_libs" ]; then
        if [ -d "$cupti_dir" ]; then
            export LD_LIBRARY_PATH="$torch_cuda_libs:$cupti_dir"
        else
            export LD_LIBRARY_PATH="$torch_cuda_libs"
        fi

        echo "Using PyTorch/NVIDIA wheel CUDA libraries first."
        echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    else
        echo "WARNING: No NVIDIA Python wheel CUDA libraries were found."
        echo "Leaving LD_LIBRARY_PATH unchanged: ${LD_LIBRARY_PATH:-}"
    fi
}

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh

    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    grep -qxF "PermitUserEnvironment yes" /etc/ssh/sshd_config || echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables for SSH sessions without persisting fragile GPU visibility values.
# CUDA_VISIBLE_DEVICES / NVIDIA_VISIBLE_DEVICES are runtime-assigned by the container platform;
# persisting stale values can make CUDA behave inconsistently after restarts or SSH login.
export_env_vars() {
    echo "Exporting environment variables..."

    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_FILE="/root/.ssh/environment"
    RP_ENV_FILE="/etc/rp_environment"

    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_FILE"
    > "$RP_ENV_FILE"

    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^NVIDIA_' \
        | grep -Ev '^(CUDA_VISIBLE_DEVICES|NVIDIA_VISIBLE_DEVICES|RUNPOD_API_KEY|RUNPOD_TOKEN|RUNPOD_SECRET)=' \
        | while IFS='=' read -r name value; do
            echo "$name=\"$value\"" >> "$ENV_FILE"
            echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
            echo "$name=\"$value\"" >> "$SSH_ENV_FILE"
            echo "export $name=\"$value\"" >> "$RP_ENV_FILE"
        done

    grep -qxF 'source /etc/rp_environment' ~/.bashrc || echo 'source /etc/rp_environment' >> ~/.bashrc
    grep -qxF 'source /etc/rp_environment' /etc/bash.bashrc || echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE" "$RP_ENV_FILE"
    chmod 600 "$SSH_ENV_FILE"
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

# Make pip checks less fragile for ComfyUI-Manager on cold RunPod starts.
# This does not upgrade or reinstall packages at runtime; it only validates and warms pip.
ensure_package_tools() {
    echo "Checking pip for ComfyUI-Manager..."

    export PATH="$VENV_DIR/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    export PIP_ROOT_USER_ACTION=ignore
    export PIP_DEFAULT_TIMEOUT="${PIP_DEFAULT_TIMEOUT:-120}"

    cd "$COMFYUI_DIR"
    source "$VENV_DIR/bin/activate"
    hash -r || true

    local pip_ok=0
    for attempt in 1 2 3; do
        if python -m pip --version; then
            pip_ok=1
            break
        fi

        echo "WARNING: python -m pip failed on attempt ${attempt}/3. Running ensurepip..."
        python -m ensurepip --upgrade || true
        sleep 2
    done

    if [ "$pip_ok" != "1" ]; then
        echo "ERROR: pip is not available inside $VENV_DIR"
        echo "ComfyUI may start, but ComfyUI-Manager custom node dependency installation will fail."
        return 1
    fi

    python - <<'PY' || true
import os
import sys
print("Python executable:", sys.executable)
print("PATH:", os.environ.get("PATH"))
try:
    import pip
    print("pip import OK:", pip.__file__)
except Exception as e:
    print("pip import failed:", repr(e))
PY

    # Manager may call pip list, not only pip --version. Warm that path too.
    python -m pip list --format=freeze > /dev/null || true
    echo "pip OK for ComfyUI-Manager"
}

# Small defensive patch: older ComfyUI-Manager builds use a very short pip probe timeout.
# On slow first boots this can produce a false "python -m pip not available" error.
patch_manager_pip_timeout() {
    local manager_util="$COMFYUI_DIR/custom_nodes/ComfyUI-Manager/glob/manager_util.py"

    if [ -f "$manager_util" ]; then
        if grep -q "timeout=5" "$manager_util"; then
            echo "Patching ComfyUI-Manager pip detection timeout from 5s to 30s..."
            sed -i 's/timeout=5/timeout=30/g' "$manager_util" || true
        fi
    fi
}

# CUDA preflight with staged diagnostics.
#
# The checks are intentionally ordered so the log can distinguish:
#   41: NVIDIA driver library cannot be loaded
#   42: CUDA Driver API call itself raised an exception
#   43: cuInit() failed before PyTorch (host / driver / GPU runtime problem)
#   44: CUDA Driver API initialized, but PyTorch cannot use CUDA
#   45: PyTorch sees CUDA, but a real CUDA/cuBLAS operation failed
#
# The preflight is passive: it does not install packages, modify Torch, or repair the host.
cuda_preflight() {
    if [ "${SKIP_CUDA_PREFLIGHT:-0}" = "1" ]; then
        echo "SKIP_CUDA_PREFLIGHT=1 set — skipping CUDA preflight."
        return 0
    fi

    echo "Running CUDA preflight..."

    cd "$COMFYUI_DIR"
    source "$VENV_DIR/bin/activate"

    python - <<'PY'
import ctypes
import os
import subprocess
import sys
from pathlib import Path


def safe_env(name, default="unknown"):
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def run_text(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        out = (p.stdout or "").strip()
        err = (p.stderr or "").strip()
        if out and err:
            return f"{out}\n{err}"
        return out or err or f"(exit {p.returncode}, no output)"
    except Exception as e:
        return f"unavailable: {e!r}"


def cuda_error(libcuda, rc):
    try:
        name_ptr = ctypes.c_char_p()
        desc_ptr = ctypes.c_char_p()
        libcuda.cuGetErrorName.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
        libcuda.cuGetErrorString.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
        libcuda.cuGetErrorName(rc, ctypes.byref(name_ptr))
        libcuda.cuGetErrorString(rc, ctypes.byref(desc_ptr))
        name = name_ptr.value.decode(errors="replace") if name_ptr.value else "unknown"
        desc = desc_ptr.value.decode(errors="replace") if desc_ptr.value else "unknown error"
        return name, desc
    except Exception:
        return "unknown", "unknown error"


print("============================================================")
print("Inteliweb AI - CUDA Preflight Diagnostics")
print("============================================================")
print("Stage: platform / host information")
print("Pod ID:", safe_env("RUNPOD_POD_ID"))
print("Pod hostname:", safe_env("RUNPOD_POD_HOSTNAME"))
print("RunPod GPU:", safe_env("RUNPOD_GPU_NAME"))
print("RunPod GPU count:", safe_env("RUNPOD_GPU_COUNT"))
print("RunPod RAM (GB):", safe_env("RUNPOD_MEM_GB"))
print("RunPod CPU count:", safe_env("RUNPOD_CPU_COUNT"))
print("RunPod cloud type:", safe_env("RUNPOD_CLOUD_TYPE"))
print("CUDA toolkit env:", safe_env("CUDA_VERSION"))
print("CUDA_HOME:", safe_env("CUDA_HOME"))
print("CUDA_VISIBLE_DEVICES:", os.environ.get("CUDA_VISIBLE_DEVICES"))
print("NVIDIA_VISIBLE_DEVICES:", os.environ.get("NVIDIA_VISIBLE_DEVICES"))
print("LD_LIBRARY_PATH:", os.environ.get("LD_LIBRARY_PATH"))
print()

print("Stage: NVIDIA host visibility")
print("nvidia-smi query:")
print(run_text([
    "nvidia-smi",
    "--query-gpu=index,uuid,pci.bus_id,driver_version,name,memory.total",
    "--format=csv,noheader",
]))
print("NVIDIA device nodes:")
try:
    nodes = sorted(str(p) for p in Path("/dev").glob("nvidia*"))
    print(" ".join(nodes) if nodes else "none")
except Exception as e:
    print("unavailable:", repr(e))
print()

print("Stage: CUDA Driver API")
try:
    libcuda = ctypes.CDLL("libcuda.so.1")
    print("libcuda.so.1: loaded")
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED_STAGE: DRIVER_LIBRARY")
    print("CUDA_PREFLIGHT_FAILED: libcuda.so.1 not available:", repr(e))
    sys.exit(41)

try:
    libcuda.cuInit.argtypes = [ctypes.c_uint]
    libcuda.cuInit.restype = ctypes.c_int
    rc = libcuda.cuInit(0)
    name, desc = cuda_error(libcuda, rc) if rc != 0 else ("CUDA_SUCCESS", "success")
    print("cuInit(0):", rc)
    print("cuInit name:", name)
    print("cuInit description:", desc)
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED_STAGE: CUDA_DRIVER_API")
    print("CUDA_PREFLIGHT_FAILED: cuInit exception:", repr(e))
    sys.exit(42)

if rc != 0:
    print("CUDA_PREFLIGHT_FAILED_STAGE: CUDA_DRIVER_INIT")
    print("CUDA_PREFLIGHT_FAILED: CUDA Driver API initialization failed before PyTorch was imported.")
    print("Interpretation: the GPU may still appear in nvidia-smi, but CUDA compute cannot initialize it.")
    print("Most likely area: host GPU state, NVIDIA driver, device injection/runtime, or host configuration.")
    print("Recommended action: terminate this Pod and deploy another GPU/host. If it repeats, report the Pod ID, GPU UUID and driver version to the provider.")
    sys.exit(43)

print()
print("Stage: PyTorch CUDA")
try:
    import torch
    print("torch:", torch.__version__)
    print("torch file:", getattr(torch, "__file__", None))
    print("torch.version.cuda:", torch.version.cuda)
    available = torch.cuda.is_available()
    count = torch.cuda.device_count()
    print("torch.cuda.is_available():", available)
    print("torch.cuda.device_count():", count)

    if not available:
        print("CUDA_PREFLIGHT_FAILED_STAGE: PYTORCH_CUDA")
        print("CUDA_PREFLIGHT_FAILED: CUDA Driver API initialized, but torch.cuda.is_available() returned False.")
        sys.exit(44)

    print("GPU:", torch.cuda.get_device_name(0))
    print("CUDA capability:", torch.cuda.get_device_capability(0))
    print("cuDNN:", torch.backends.cudnn.version())
except SystemExit:
    raise
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED_STAGE: PYTORCH_CUDA")
    print("CUDA_PREFLIGHT_FAILED: PyTorch CUDA initialization failed:", repr(e))
    sys.exit(44)

print()
print("Stage: real CUDA/cuBLAS smoke test")
try:
    dtypes = [torch.float32, torch.float16]
    try:
        if torch.cuda.is_bf16_supported():
            dtypes.append(torch.bfloat16)
    except Exception as e:
        print("BF16 support check warning:", repr(e))

    for dtype in dtypes:
        print("Testing CUDA matmul:", dtype)
        a = torch.randn((128, 128), device="cuda", dtype=dtype)
        y = a @ a
        torch.cuda.synchronize()
        print("CUDA matmul OK:", dtype)

except Exception as e:
    print("CUDA_PREFLIGHT_FAILED_STAGE: CUDA_RUNTIME")
    print("CUDA_PREFLIGHT_FAILED: PyTorch can see CUDA, but a real CUDA/cuBLAS operation failed:", repr(e))
    print("Interpretation: inspect CUDA runtime libraries and LD_LIBRARY_PATH before blaming the host.")
    sys.exit(45)

print()
print("CUDA_PREFLIGHT_STAGE: OK")
print("CUDA preflight OK.")
print("============================================================")
PY
}

show_cuda_error_page() {
    local failure_code="$1"
    mkdir -p /workspace/cuda-error

    CUDA_FAILURE_CODE="$failure_code" CUDA_PREFLIGHT_LOG="$CUDA_PREFLIGHT_LOG" \
    "${PYTHON_BIN:-python3.12}" - <<'PY'
import html
import os
import re
from pathlib import Path

failure_code = int(os.environ.get("CUDA_FAILURE_CODE", "1"))
log_path = Path(os.environ.get("CUDA_PREFLIGHT_LOG", "/workspace/CUDA_PREFLIGHT.txt"))
try:
    diagnostics = log_path.read_text(errors="replace")
except Exception as e:
    diagnostics = f"Unable to read diagnostics: {e!r}"

# Defense in depth: redact common credential/token patterns if they ever appear in the log.
diagnostics = re.sub(
    r"(?im)^((?:RUNPOD_)?(?:API_KEY|TOKEN|SECRET|PASSWORD)\s*[:=]\s*).+$",
    r"\1[REDACTED]",
    diagnostics,
)

profiles = {
    41: {
        "title": "NVIDIA driver library is unavailable",
        "category": "Driver library / container runtime",
        "summary": "The container could not load libcuda.so.1, so CUDA cannot reach the NVIDIA driver.",
        "action": "Stop this Pod and deploy another host. If the problem repeats, report the Pod ID and diagnostics to your GPU provider.",
        "host_likely": True,
    },
    42: {
        "title": "CUDA Driver API could not be called",
        "category": "CUDA Driver API",
        "summary": "The CUDA driver call failed before PyTorch and ComfyUI were loaded.",
        "action": "Stop this Pod and try another GPU/host. If it repeats across hosts, review the container runtime and driver integration.",
        "host_likely": True,
    },
    43: {
        "title": "GPU detected, but CUDA compute cannot initialize",
        "category": "Host / NVIDIA driver / GPU runtime",
        "summary": "The GPU may be visible in nvidia-smi, but cuInit() failed before PyTorch was imported. ComfyUI was intentionally not started on this unhealthy CUDA host.",
        "action": "Terminate this Pod and deploy another GPU/host. If the same failure repeats, send the Pod ID, GPU UUID and driver version from the diagnostics to your provider.",
        "host_likely": True,
    },
    44: {
        "title": "PyTorch cannot initialize CUDA",
        "category": "PyTorch / CUDA integration",
        "summary": "The CUDA Driver API initialized successfully, but PyTorch could not use the GPU.",
        "action": "Review the PyTorch/CUDA build and container runtime. Trying another host can help distinguish a host issue from an image compatibility issue.",
        "host_likely": False,
    },
    45: {
        "title": "CUDA runtime smoke test failed",
        "category": "CUDA runtime / cuBLAS libraries",
        "summary": "PyTorch detected the GPU, but a real CUDA matrix operation failed. This commonly points to runtime library conflicts or an unhealthy GPU runtime.",
        "action": "Inspect LD_LIBRARY_PATH and CUDA runtime libraries. If the same image works on another host, report this host to the provider.",
        "host_likely": False,
    },
}

p = profiles.get(failure_code, {
    "title": "CUDA preflight failed",
    "category": "GPU / CUDA",
    "summary": "The container started, but the GPU health check did not pass.",
    "action": "Review the diagnostics below and try another GPU/host.",
    "host_likely": False,
})

# Pull a few safe fields from the diagnostic log for the summary cards.
def field(label):
    m = re.search(rf"(?m)^{re.escape(label)}:\s*(.+)$", diagnostics)
    return m.group(1).strip() if m else "unknown"

pod_id = field("Pod ID")
gpu = field("RunPod GPU").replace("+", " ")
if gpu == "unknown":
    m = re.search(r"(?m)^\d+,\s*[^,]+,\s*[^,]+,\s*[^,]+,\s*([^,]+),", diagnostics)
    if m:
        gpu = m.group(1).strip()

driver = "unknown"
gpu_uuid = "unknown"
m = re.search(r"(?m)^\d+,\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^\n]+)$", diagnostics)
if m:
    gpu_uuid = m.group(1).strip()
    driver = m.group(3).strip()

cuda_version = field("CUDA toolkit env")

host_note = (
    "This failure happened before PyTorch and ComfyUI were loaded, so your workflow and models are not the cause of this specific failure."
    if p["host_likely"]
    else
    "The preflight stopped ComfyUI early to avoid a misleading crash later in the workflow."
)

cards = [
    ("Pod ID", pod_id),
    ("GPU", gpu),
    ("GPU UUID", gpu_uuid),
    ("Driver", driver),
    ("CUDA toolkit", cuda_version),
    ("Failure code", str(failure_code)),
]

card_html = "".join(
    f'<div class="card"><span>{html.escape(label)}</span><strong>{html.escape(value)}</strong></div>'
    for label, value in cards
)

page = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{html.escape(p["title"])}</title>
  <style>
    :root {{ color-scheme: dark; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: radial-gradient(circle at top, #1d2945 0, #0b1020 42%, #070a12 100%);
      color: #eef2ff;
    }}
    main {{ max-width: 1040px; margin: 0 auto; padding: 52px 24px 72px; }}
    .hero {{
      background: rgba(16, 23, 42, .86);
      border: 1px solid rgba(148, 163, 184, .22);
      border-radius: 22px;
      padding: 32px;
      box-shadow: 0 24px 80px rgba(0,0,0,.35);
    }}
    .badge {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 7px 11px;
      border-radius: 999px;
      background: rgba(239, 68, 68, .12);
      border: 1px solid rgba(248, 113, 113, .35);
      color: #fecaca;
      font-size: 13px;
      font-weight: 700;
      letter-spacing: .02em;
    }}
    h1 {{ margin: 18px 0 10px; font-size: clamp(30px, 5vw, 48px); line-height: 1.06; }}
    .lead {{ margin: 0; color: #cbd5e1; font-size: 18px; line-height: 1.65; max-width: 850px; }}
    .category {{ margin-top: 18px; color: #93c5fd; font-weight: 700; }}
    .grid {{ display: grid; grid-template-columns: repeat(3, minmax(0,1fr)); gap: 12px; margin-top: 26px; }}
    .card {{ background: rgba(15,23,42,.7); border: 1px solid rgba(148,163,184,.18); border-radius: 14px; padding: 15px; min-width: 0; }}
    .card span {{ display:block; color:#94a3b8; font-size:12px; text-transform:uppercase; letter-spacing:.06em; margin-bottom:7px; }}
    .card strong {{ display:block; color:#f8fafc; font-size:14px; word-break:break-word; }}
    .section {{ margin-top: 18px; background: rgba(15,23,42,.62); border:1px solid rgba(148,163,184,.17); border-radius:18px; padding:22px; }}
    .section h2 {{ margin:0 0 10px; font-size:18px; }}
    .section p {{ color:#cbd5e1; line-height:1.65; margin:7px 0; }}
    .action {{ border-color: rgba(96,165,250,.35); background: rgba(30,64,175,.12); }}
    ol {{ color:#dbeafe; line-height:1.75; padding-left:22px; }}
    code {{ background:#111827; border:1px solid #334155; border-radius:6px; padding:2px 6px; }}
    details {{ margin-top:18px; background:rgba(2,6,23,.82); border:1px solid rgba(148,163,184,.17); border-radius:16px; overflow:hidden; }}
    summary {{ cursor:pointer; padding:17px 20px; font-weight:700; color:#cbd5e1; }}
    pre {{ margin:0; padding:20px; overflow:auto; border-top:1px solid rgba(148,163,184,.13); color:#cbd5e1; background:#050812; font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }}
    .footer {{ margin-top:18px; color:#64748b; font-size:13px; text-align:center; }}
    @media (max-width: 760px) {{ .grid {{ grid-template-columns: 1fr; }} .hero {{ padding:24px; }} main {{ padding:28px 14px 48px; }} }}
  </style>
</head>
<body>
<main>
  <section class="hero">
    <div class="badge">⚠ CUDA PREFLIGHT FAILED</div>
    <h1>{html.escape(p["title"])}</h1>
    <p class="lead">{html.escape(p["summary"])}</p>
    <div class="category">Detected area: {html.escape(p["category"])}</div>
    <div class="grid">{card_html}</div>
  </section>

  <section class="section action">
    <h2>Recommended action</h2>
    <p>{html.escape(p["action"])}</p>
    <ol>
      <li>Keep this Pod only if you need the diagnostics; SSH, JupyterLab and FileBrowser remain available.</li>
      <li>For a <code>cuInit()</code> / driver failure, terminate the Pod and deploy another GPU host.</li>
      <li>If the problem repeats, send the Pod ID, GPU UUID, NVIDIA driver version and <code>CUDA_PREFLIGHT.txt</code> to the infrastructure provider.</li>
    </ol>
  </section>

  <section class="section">
    <h2>What this means</h2>
    <p>{html.escape(host_note)}</p>
    <p>The preflight intentionally prevents ComfyUI from starting when CUDA is unhealthy, avoiding later errors that are harder to diagnose.</p>
  </section>

  <details>
    <summary>Advanced diagnostics — /workspace/CUDA_PREFLIGHT.txt</summary>
    <pre>{html.escape(diagnostics)}</pre>
  </details>

  <div class="footer">Inteliweb AI · ComfyUI CUDA preflight protection</div>
</main>
</body>
</html>'''

out = Path("/workspace/cuda-error/index.html")
out.write_text(page, encoding="utf-8")
PY

    echo "Starting CUDA error page on port 8188..."
    nohup "${PYTHON_BIN:-python3.12}" -m http.server 8188 --bind 0.0.0.0 --directory /workspace/cuda-error > /cuda-error-page.log 2>&1 &
}

handle_cuda_preflight() {
    set +e
    cuda_preflight > "$CUDA_PREFLIGHT_LOG" 2>&1
    local status=$?
    set -e

    cat "$CUDA_PREFLIGHT_LOG" || true

    if [ "$status" -ne 0 ]; then
        echo "============================================================"
        echo "  CUDA PREFLIGHT FAILED (code $status)"

        case "$status" in
            41)
                echo "  Stage: NVIDIA driver library"
                echo "  libcuda.so.1 could not be loaded."
                ;;
            42)
                echo "  Stage: CUDA Driver API"
                echo "  cuInit() could not be called successfully."
                ;;
            43)
                echo "  Stage: CUDA driver initialization"
                echo "  cuInit() failed BEFORE PyTorch and ComfyUI were loaded."
                echo "  This strongly points to the host / NVIDIA driver / GPU runtime layer."
                ;;
            44)
                echo "  Stage: PyTorch CUDA initialization"
                echo "  The CUDA Driver API initialized, but PyTorch could not use CUDA."
                ;;
            45)
                echo "  Stage: CUDA runtime / cuBLAS smoke test"
                echo "  PyTorch detected CUDA, but a real GPU operation failed."
                ;;
            *)
                echo "  Stage: unknown CUDA preflight failure"
                ;;
        esac

        echo ""
        echo "  ComfyUI was not started to prevent a misleading downstream crash."
        echo "  Diagnostics: $CUDA_PREFLIGHT_LOG"
        echo "  SSH, JupyterLab and FileBrowser remain available."
        echo ""
        if [ "$status" = "43" ]; then
            echo "  Recommended action: terminate this Pod and deploy another GPU/host."
            echo "  If it repeats, report the Pod ID, GPU UUID and driver version shown above."
        else
            echo "  Recommended action: review the diagnostics above before changing the ComfyUI workflow."
        fi
        echo ""
        echo "  To bypass this protection for debugging only: SKIP_CUDA_PREFLIGHT=1"
        echo "============================================================"

        show_cuda_error_page "$status"
        sleep infinity
    fi
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

configure_torch_cuda_runtime_libs
setup_ssh
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

# Start FileBrowser
echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

# Create default comfyui_args.txt if it doesn't exist
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."

    # Copy baked ComfyUI from image (no git, no network)
    if [ ! -d "$COMFYUI_DIR" ]; then
        cp -r /opt/comfyui-baked "$COMFYUI_DIR"
        echo "ComfyUI copied to workspace"
    fi

    # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        "${PYTHON_BIN:-python3.12}" -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        # Ensure pip is available in the venv (needed for ComfyUI-Manager)
        python -m ensurepip --upgrade || python -m ensurepip

        echo "Base packages (torch, numpy, etc.) available from system site-packages"
        echo "ComfyUI ready — all dependencies pre-installed in image"
    fi
else
    source "$VENV_DIR/bin/activate"
    echo "Using existing ComfyUI installation"
fi

ensure_package_tools || true
patch_manager_pip_timeout
handle_cuda_preflight

# Start ComfyUI — keep container alive if it crashes so SSH/Jupyter remain accessible
cd "$COMFYUI_DIR"
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
python main.py $FIXED_ARGS &
COMFY_PID=$!
trap "kill $COMFY_PID 2>/dev/null" SIGTERM SIGINT
wait $COMFY_PID || true

echo "============================================="
echo "  ComfyUI crashed — check the logs above."
echo "  SSH and JupyterLab are still available."
echo "  To restart after fixing:"
echo "    cd $COMFYUI_DIR && source .venv/bin/activate"
echo "    python main.py $FIXED_ARGS"
echo "============================================="

sleep infinity