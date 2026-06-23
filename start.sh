#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/filebrowser.db"
ARGS_FILE="/workspace/comfyui_args.txt"
CUDA_PREFLIGHT_LOG="/workspace/CUDA_PREFLIGHT.txt"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

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

# Lightweight CUDA preflight. It is intentionally passive: it does not install packages,
# modify Torch, or change CUDA variables. It only detects broken GPU/driver exposure early.
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
import sys

print("CUDA_VISIBLE_DEVICES:", os.environ.get("CUDA_VISIBLE_DEVICES"))
print("NVIDIA_VISIBLE_DEVICES:", os.environ.get("NVIDIA_VISIBLE_DEVICES"))

try:
    libcuda = ctypes.CDLL("libcuda.so.1")
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED: libcuda.so.1 not available:", repr(e))
    sys.exit(41)

try:
    rc = libcuda.cuInit(0)
    print("cuInit(0):", rc)
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED: cuInit exception:", repr(e))
    sys.exit(42)

if rc != 0:
    print("CUDA_PREFLIGHT_FAILED: CUDA driver initialization failed before PyTorch.")
    print("This usually means the RunPod host/GPU is defective or incorrectly exposed to the container.")
    sys.exit(43)

try:
    import torch
    print("torch:", torch.__version__)
    print("torch.version.cuda:", torch.version.cuda)
    available = torch.cuda.is_available()
    print("torch.cuda.is_available():", available)
    print("torch.cuda.device_count():", torch.cuda.device_count())

    if not available:
        print("CUDA_PREFLIGHT_FAILED: torch.cuda.is_available() returned False.")
        sys.exit(44)

    print("GPU:", torch.cuda.get_device_name(0))
except Exception as e:
    print("CUDA_PREFLIGHT_FAILED: PyTorch CUDA check failed:", repr(e))
    sys.exit(45)

print("CUDA preflight OK.")
PY
}

show_cuda_error_page() {
    mkdir -p /workspace/cuda-error

    cat > /workspace/cuda-error/index.html <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>CUDA / GPU initialization failed</title>
  <style>
    body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 900px; margin: 40px auto; line-height: 1.5; padding: 0 20px; }
    code, pre { background: #f3f3f3; padding: 3px 6px; border-radius: 4px; }
    .box { border: 1px solid #ddd; padding: 22px; border-radius: 12px; }
    h1 { margin-top: 0; }
  </style>
</head>
<body>
  <div class="box">
    <h1>ComfyUI did not start because CUDA failed</h1>
    <p>The container started, but the GPU could not be initialized by CUDA.</p>
    <p>This usually means the RunPod host/GPU is defective or incorrectly exposed to the container.</p>
    <p>Common diagnostics:</p>
    <pre>cuInit(0): 999
torch.cuda.is_available(): False</pre>
    <p>Diagnostics were saved to <code>/workspace/CUDA_PREFLIGHT.txt</code>.</p>
    <p>SSH, JupyterLab, and FileBrowser are still available.</p>
    <p>Recommended action: stop this pod and try another GPU/host.</p>
  </div>
</body>
</html>
HTML

    echo "Starting CUDA error page on port 8188..."
    nohup python3.12 -m http.server 8188 --bind 0.0.0.0 --directory /workspace/cuda-error > /cuda-error-page.log 2>&1 &
}

handle_cuda_preflight() {
    set +e
    cuda_preflight > "$CUDA_PREFLIGHT_LOG" 2>&1
    local status=$?
    set -e

    cat "$CUDA_PREFLIGHT_LOG" || true

    if [ "$status" -ne 0 ]; then
        echo "============================================="
        echo "  CUDA PREFLIGHT FAILED"
        echo "  ComfyUI was not started because CUDA cannot initialize."
        echo ""
        echo "  Common bad result:"
        echo "    cuInit(0): 999"
        echo "    torch.cuda.is_available(): False"
        echo ""
        echo "  This is usually a RunPod host/GPU problem, not a ComfyUI problem."
        echo "  Try another GPU/host."
        echo ""
        echo "  SSH, JupyterLab and FileBrowser remain available."
        echo "  Diagnostics saved to: $CUDA_PREFLIGHT_LOG"
        echo ""
        echo "  To bypass this check: set SKIP_CUDA_PREFLIGHT=1"
        echo "============================================="
        show_cuda_error_page
        sleep infinity
    fi
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

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
        python3.12 -m venv --system-site-packages "$VENV_DIR"
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
