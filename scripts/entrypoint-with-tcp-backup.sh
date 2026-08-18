#!/bin/bash
set -e

BACKUP_PORT="${COMFYUI_TCP_BACKUP_PORT:-8189}"
TARGET_PORT="${COMFYUI_TCP_TARGET_PORT:-8188}"
BACKUP_ENABLED="${ENABLE_COMFYUI_TCP_BACKUP:-1}"
URL_TXT="/workspace/COMFYUI_DIRECT_TCP_URL.txt"
URL_HTML="/workspace/COMFYUI_DIRECT_TCP.html"

write_access_info() {
    local public_ip="${RUNPOD_PUBLIC_IP:-}"
    local mapped_var="RUNPOD_TCP_PORT_${BACKUP_PORT}"
    local mapped_port="${!mapped_var:-}"

    if [ -n "$public_ip" ] && [ -n "$mapped_port" ]; then
        local url="http://${public_ip}:${mapped_port}"
        printf '%s\n' "$url" > "$URL_TXT"
        cat > "$URL_HTML" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>ComfyUI Direct TCP Backup</title></head>
<body style="font-family:system-ui;background:#0b1020;color:#eef2ff;padding:32px">
<h1>ComfyUI Direct TCP Backup</h1>
<p>If RunPod's normal HTTP proxy has problems, open ComfyUI directly through TCP:</p>
<p><a href="$url" style="color:#93c5fd;font-size:20px">$url</a></p>
<p><strong>Note:</strong> this uses plain HTTP and bypasses RunPod's HTTPS proxy.</p>
</body></html>
EOF
        echo "============================================================"
        echo "ComfyUI Direct TCP backup available"
        echo "  Internal forward : 0.0.0.0:${BACKUP_PORT} -> 127.0.0.1:${TARGET_PORT}"
        echo "  Direct URL       : ${url}"
        echo "  URL file         : ${URL_TXT}"
        echo "============================================================"
    else
        echo "ComfyUI Direct TCP backup forwarder is enabled on internal port ${BACKUP_PORT}."
        echo "RunPod did not expose RUNPOD_PUBLIC_IP / ${mapped_var} yet."
        echo "Configure template TCP ports as: 22,${BACKUP_PORT}"
    fi
}

if [ "$BACKUP_ENABLED" = "1" ]; then
    echo "Starting ComfyUI Direct TCP backup forwarder on port ${BACKUP_PORT}..."
    nohup python3.12 /opt/inteliweb/comfyui-tcp-forward.py > /comfyui-tcp-backup.log 2>&1 &
    write_access_info
else
    echo "ENABLE_COMFYUI_TCP_BACKUP=${BACKUP_ENABLED}; Direct TCP backup disabled."
fi

exec /start.sh
