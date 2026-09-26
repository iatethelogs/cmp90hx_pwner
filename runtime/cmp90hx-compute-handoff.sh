#!/usr/bin/env bash
# Load CMP90HX patched compute driver.
# P2P is deliberately not enabled from boot or from this handoff.
# Run cmp90hxpwner.sh --p2p-enable manually after PCIe Gen2 when P2P is wanted.
set -uo pipefail

KREL="$(uname -r)"
PATCHED_DIR="/usr/lib/modules/${KREL}/updates/cmpunlocker-90hx-stockflow"
PATCHED_SRCV="$(modinfo -F srcversion "${PATCHED_DIR}/nvidia.ko" 2>/dev/null || true)"
UNLOAD=(nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia)

log() { echo "cmp90hx-handoff: $*"; }
loaded_srcv() { cat /sys/module/nvidia/srcversion 2>/dev/null || true; }
gpu_ok() { nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; }

wait_gpu() {
    local i
    for i in $(seq 1 "${1:-30}"); do
        gpu_ok && return 0
        sleep 2
    done
    return 1
}


stop_gpu_users_handoff() {
    systemctl stop nvidia-persistenced ollama llama open-webui librechat comfyui docker containerd 2>/dev/null || true
    pkill -f 'nvidia-smi|llama-server|ollama|comfyui|python.*cuda|python.*torch|python.*nvidia' 2>/dev/null || true
    if ls /dev/nvidia* >/dev/null 2>&1; then
        fuser -k -TERM /dev/nvidia* >/dev/null 2>&1 || true
        sleep 1
        fuser -k -KILL /dev/nvidia* >/dev/null 2>&1 || true
    fi
}

nvidia_loaded() {
    lsmod | awk '{print $1}' | grep -Eq '^nvidia($|_)|^nvidia-vgpu-vfio$|^nvidia_vgpu_vfio$'
}

unload_all() {
    local i loaded

    for i in 1 2 3 4 5; do
        modprobe -r "${UNLOAD[@]}" 2>/dev/null || true
        modprobe -r nvidia-vgpu-vfio nvidia_vgpu_vfio "${UNLOAD[@]}" 2>/dev/null || true
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia_vgpu_vfio nvidia 2>/dev/null || true
        sleep 1

        if ! nvidia_loaded; then
            log "nvidia stack unloaded"
            return 0
        fi

        loaded="$(lsmod | awk '/^nvidia/ {print $1}' | tr '\n' ' ')"
        log "nvidia stack still loaded after pass $i/5: ${loaded:-unknown}"
        stop_gpu_users_handoff
        sleep 2
    done

    log "FATAL: nvidia stack is still loaded"
    lsmod | grep '^nvidia' || true
    return 1
}


find_stock() {
    local p
    for p in "/usr/lib/modules/${KREL}/updates/dkms/nvidia.ko" \
             "/lib/modules/${KREL}/updates/dkms/nvidia.ko"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    p="$(find "/lib/modules/${KREL}" -name nvidia.ko 2>/dev/null | grep -v -- "$PATCHED_DIR" | head -1)"
    [[ -n "$p" ]] && echo "$p"
}

cmp_gpus() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

set_iommu_identity() {
    local dev group type_file before after groups=()
    mapfile -t groups < <(
        for dev in $(cmp_gpus); do
            [[ -e "/sys/bus/pci/devices/$dev/iommu_group" ]] || continue
            basename "$(readlink "/sys/bus/pci/devices/$dev/iommu_group")"
        done | sort -n -u
    )

    if [[ "${#groups[@]}" -eq 0 ]]; then
        log "no CMP90HX IOMMU groups found; skip identity"
        return 0
    fi

    for group in "${groups[@]}"; do
        type_file="/sys/kernel/iommu_groups/${group}/type"
        [[ -e "$type_file" ]] || { log "group $group has no type file"; continue; }
        before="$(cat "$type_file" 2>/dev/null || true)"
        log "IOMMU group $group before=$before"
        if [[ "$before" != "identity" ]]; then
            echo identity > "$type_file" || { log "FATAL: cannot set IOMMU group $group to identity"; return 1; }
        fi
        after="$(cat "$type_file" 2>/dev/null || true)"
        log "IOMMU group $group after=$after"
        [[ "$after" == "identity" ]] || { log "FATAL: IOMMU group $group is not identity"; return 1; }
    done
}

disable_acs_redirects() {
    local dev old new
    command -v lspci >/dev/null 2>&1 || return 0
    command -v setpci >/dev/null 2>&1 || return 0
    for path in /sys/bus/pci/devices/*; do
        dev="$(basename "$path")"
        lspci -vv -s "$dev" 2>/dev/null | grep -q ACSCtl || continue
        old="$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null || true)"
        [[ -z "$old" ]] && continue
        new="$(printf '%04x' $(( 0x$old & ~0x000c )))"
        if [[ "$new" != "$old" ]]; then
            log "$dev ACSCtl old=$old new=$new"
            setpci -s "$dev" ECAP_ACS+0x6.w="$new" 2>/dev/null || true
        fi
    done
}

load_patched_final() {
    modprobe ecc 2>/dev/null || true
    modprobe ecdh_generic 2>/dev/null || true
    log "loading patched module without P2P RegistryDwords"
    modprobe nvidia || return 1
    modprobe nvidia_uvm 2>/dev/null || true
}

[[ -n "$PATCHED_SRCV" ]] || { log "FATAL: patched nvidia.ko missing at $PATCHED_DIR"; exit 1; }

# Fast path: patched module already active with a live GPU.
if [[ "$(loaded_srcv)" == "$PATCHED_SRCV" ]] && gpu_ok; then
    log "patched module already active (srcversion $PATCHED_SRCV)"
    exit 0
fi

log "P2P mode: manual-only; compute handoff loads without P2P RegistryDwords"

STOCK="$(find_stock)"
if [[ -n "$STOCK" ]]; then
    stock_srcv="$(modinfo -F srcversion "$STOCK" 2>/dev/null || true)"
    log "priming GPU with stock module: $STOCK"
    log "stock module srcversion: ${stock_srcv:-missing}"

    if [[ "${CMP90HX_ASSUME_NVIDIA_UNLOADED:-0}" == "1" ]]; then
        if nvidia_loaded; then
            log "caller claimed nvidia is unloaded, but stack is still loaded; unloading now"
            unload_all || { log "FATAL: cannot unload before stock prime"; exit 1; }
        else
            log "skip pre-stock unload; caller already unloaded nvidia stack"
        fi
    else
        unload_all || { log "FATAL: cannot unload before stock prime"; exit 1; }
    fi

    modprobe ecc 2>/dev/null || true
    modprobe ecdh_generic 2>/dev/null || true

    if ! insmod "$STOCK"; then
        rc=$?
        log "FATAL: stock module insmod failed rc=$rc: $STOCK"
        log "recent NVIDIA kernel messages:"
        dmesg 2>/dev/null | grep -Ei 'NVRM|nvidia|Xid|RmInitAdapter|fallen off the bus' | tail -n 40 || true
        exit 1
    fi

    loaded="$(loaded_srcv)"
    log "loaded stock srcversion: ${loaded:-none}"

    if [[ -n "$stock_srcv" && "$loaded" != "$stock_srcv" ]]; then
        log "FATAL: expected stock srcversion '$stock_srcv', but loaded '${loaded:-none}'"
        exit 1
    fi

    if wait_gpu 20; then
        log "stock module brought the GPU up"
    else
        log "FATAL: stock module did not bring the GPU up"
        dmesg 2>/dev/null | grep -Ei 'NVRM|nvidia|Xid|RmInitAdapter|fallen off the bus' | tail -n 40 || true
        exit 1
    fi
else
    log "FATAL: no stock nvidia.ko found; stock prime is required for Gen2/rejoin16"
    exit 1
fi

log "handing over to the patched module"
unload_all || { log "FATAL: cannot unload stock module before patched handoff"; exit 1; }
sleep 2
load_patched_final || { log "FATAL: patched module load failed"; exit 1; }
loaded="$(loaded_srcv)"
if [[ "$loaded" != "$PATCHED_SRCV" ]]; then
    log "FATAL: loaded srcversion '${loaded:-none}' != patched '$PATCHED_SRCV'"
    exit 1
fi
if wait_gpu 30; then
    log "patched module active (srcversion ${loaded:-?})"
    exit 0
fi
log "FATAL: GPU did not come up on the patched module"
exit 1
