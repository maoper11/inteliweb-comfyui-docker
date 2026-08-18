# RunPod Direct TCP Backup for ComfyUI

This image keeps the normal ComfyUI HTTP service on internal port `8188` and adds an independent Direct TCP backup listener on internal port `8189`.

The backup listener forwards byte-for-byte:

```text
0.0.0.0:8189 -> 127.0.0.1:8188
```

This is useful when ComfyUI is healthy locally but RunPod's HTTP proxy has problems loading frontend assets, for example repeated browser errors such as:

```text
ERR_HTTP2_SERVER_REFUSED_STREAM
Failed to fetch dynamically imported module
```

## Recommended RunPod template ports

Configure the template as follows:

```text
Expose HTTP ports:
8188,8080,8888

Expose TCP ports:
22,8189
```

Do not expose `8188` as both HTTP and TCP because RunPod rejects duplicate exposed internal ports.

## Normal access

Use RunPod's normal clickable ComfyUI HTTP service:

```text
https://<POD_ID>-8188.proxy.runpod.net
```

## Backup access

Open the Pod's **Connect** tab and look under **Direct TCP ports**. RunPod will show a mapping similar to:

```text
ComfyUI Backup -> 80.15.7.37:47172 -> :8189
```

Open the public IP and mapped port with plain HTTP:

```text
http://80.15.7.37:47172
```

The external mapped port is assigned by RunPod and will normally be different from `8189`.

## Dynamic access URL

When RunPod provides both `RUNPOD_PUBLIC_IP` and `RUNPOD_TCP_PORT_8189`, the container writes the calculated backup URL to:

```text
/workspace/COMFYUI_DIRECT_TCP_URL.txt
/workspace/COMFYUI_DIRECT_TCP.html
```

It also prints the URL in the container logs.

Example:

```text
ComfyUI Direct TCP backup available
  Internal forward : 0.0.0.0:8189 -> 127.0.0.1:8188
  Direct URL       : http://80.15.7.37:47172
```

## Environment variables

The backup is enabled by default.

Disable it with:

```text
ENABLE_COMFYUI_TCP_BACKUP=0
```

Optional advanced settings:

```text
COMFYUI_TCP_BACKUP_PORT=8189
COMFYUI_TCP_TARGET_PORT=8188
COMFYUI_TCP_TARGET_HOST=127.0.0.1
```

If the backup internal port is changed, the RunPod TCP port configuration must be changed to match it.

## Security note

Direct TCP access bypasses RunPod's HTTPS proxy. The generated ComfyUI backup URL therefore uses plain `http://` and may be displayed by the browser as **Not secure**.

ComfyUI itself does not provide strong authentication by default. Treat the Direct TCP endpoint as an emergency/diagnostic path and do not expose it longer than necessary on untrusted networks.

## Diagnostic interpretation

If all of the following are true:

```text
http://127.0.0.1:8188              works
frontend assets served locally     work
Direct TCP backup                  works
RunPod HTTP proxy                  fails
```

then the problem is outside the ComfyUI application path and is likely related to the external HTTP proxy/load-balancer path rather than ComfyUI itself.
