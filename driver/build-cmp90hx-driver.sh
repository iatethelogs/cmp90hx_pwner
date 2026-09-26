#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build and install CMP 90HX patched NVIDIA open kernel modules from vendored patches.
set -Eeuo pipefail

DRIVER_VERSION="${DRIVER_VERSION:-610.43.03}"
EXPECTED_SHA256="${EXPECTED_SHA256:-7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc}"
KREL="${KERNEL_RELEASE:-$(uname -r)}"
JOBS="${JOBS:-$(nproc)}"
PREFIX="${PREFIX:-/opt/cmp90hx-gen2}"
CACHE_DIR="${CMP90HX_CACHE_DIR:-/var/cache/cmp90hx-pwner}"
WORK="${CMP90HX_BUILD_WORK:-/var/tmp/cmp90hx-pwner-build}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="${REPO}/driver/patches/${DRIVER_VERSION}"
UPDATES="/usr/lib/modules/${KREL}/updates/cmpunlocker-90hx-stockflow"
SRC_TARBALL="${CACHE_DIR}/NVIDIA-kernel-module-source-${DRIVER_VERSION}.tar.xz"
NV_SRC_URL="https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-${DRIVER_VERSION}.tar.xz"
NVIDIA_RUN="${CACHE_DIR}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
NVIDIA_RUN_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

log(){ echo "[cmp90hx-build] $*"; }
die(){ echo "[cmp90hx-build][FAIL] $*" >&2; exit 1; }

find_nvcc() {
    if command -v nvcc >/dev/null 2>&1; then
        command -v nvcc
        return 0
    fi
    if [[ -x /usr/local/cuda/bin/nvcc ]]; then
        printf '%s\n' /usr/local/cuda/bin/nvcc
        return 0
    fi
    return 1
}

require_cuda_toolkit() {
    local nvcc_bin
    nvcc_bin="$(find_nvcc || true)"
    if [[ -z "$nvcc_bin" ]]; then
        die "CUDA Toolkit not found: nvcc is missing. Open the main menu and press 'Install CUDA Toolkit', then rerun COMPUTE UNLOCK."
    fi
    log "CUDA Toolkit found: $nvcc_bin"
}

[[ "$(id -u)" == "0" ]] || die "run as root"
[[ -d "/lib/modules/${KREL}/build" ]] || die "kernel headers missing: /lib/modules/${KREL}/build"
for c in awk curl find gcc install make mkdir modinfo patch sha256sum sort strings tar; do
    command -v "$c" >/dev/null 2>&1 || die "required command missing: $c"
done
require_cuda_toolkit

find_stock_nvidia_module() {
    local p ver
    for p in \
        "/usr/lib/modules/${KREL}/updates/dkms/nvidia.ko" \
        "/lib/modules/${KREL}/updates/dkms/nvidia.ko" \
        $(find "/usr/lib/modules/${KREL}" "/lib/modules/${KREL}" -name nvidia.ko 2>/dev/null | grep -v '/cmpunlocker-90hx-stockflow/' | sort -u || true); do
        [[ -n "$p" && -f "$p" ]] || continue
        ver="$(modinfo -F version "$p" 2>/dev/null || true)"
        if [[ "$ver" == "$DRIVER_VERSION" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

install_stock_nvidia_run() {
    local tmp cur

    log "stock NVIDIA module ${DRIVER_VERSION} not found; installing NVIDIA .run"
    mkdir -p "$CACHE_DIR"

    if [[ ! -s "$NVIDIA_RUN" ]]; then
        log "downloading NVIDIA installer: $NVIDIA_RUN_URL"
        tmp="${NVIDIA_RUN}.part"
        rm -f "$tmp"
        curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -o "$tmp" "$NVIDIA_RUN_URL"
        mv -f "$tmp" "$NVIDIA_RUN"
    fi
    chmod +x "$NVIDIA_RUN"

    log "stopping GPU users before stock NVIDIA install"
    systemctl stop nvidia-persistenced ollama open-webui librechat llama-server docker comfyui 2>/dev/null || true
    fuser -k -TERM /dev/nvidia* 2>/dev/null || true
    sleep 2
    fuser -k -KILL /dev/nvidia* 2>/dev/null || true
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true

    if lsmod | grep -q '^nouveau '; then
        die "nouveau is loaded; blacklist nouveau, rebuild initramfs and reboot before installing NVIDIA .run"
    fi

    log "installing stock NVIDIA ${DRIVER_VERSION}"
    bash "$NVIDIA_RUN" --silent --accept-license --no-questions --no-cc-version-check --no-nouveau-check || die "stock NVIDIA .run install failed"

    depmod -a "$KREL" || depmod -a
    cur="$(modinfo -F version nvidia 2>/dev/null || true)"
    [[ "$cur" == "$DRIVER_VERSION" ]] || die "stock NVIDIA module is '${cur:-none}', expected '${DRIVER_VERSION}' after .run install"
}

stock_module="$(find_stock_nvidia_module || true)"
if [[ -z "$stock_module" ]]; then
    install_stock_nvidia_run
    stock_module="$(find_stock_nvidia_module || true)"
fi
[[ -n "$stock_module" ]] || die "stock NVIDIA module ${DRIVER_VERSION} not found after installer"
log "stock NVIDIA module: $stock_module"
log "stock NVIDIA module version: $(modinfo -F version "$stock_module" 2>/dev/null || true)"

for p in \
    "${PATCH_DIR}/0014-6104303-cmp90hx-stockflow-rejoin14-multigpu-state.patch" \
    "${PATCH_DIR}/0015-6104303-cmp90hx-stockflow-rejoin15-serialized-start.patch" \
    "${PATCH_DIR}/0016-6104303-cmp90hx-stockflow-rejoin16-pcie-jtag-plm.patch" \
    "${PATCH_DIR}/0017-cmp90hx-gen2-retrain-retry.patch"; do
    [[ -f "$p" ]] || die "missing patch: $p"
done

mkdir -p "$CACHE_DIR" "$WORK"
if [[ ! -s "$SRC_TARBALL" ]]; then
    log "downloading NVIDIA kernel module source ${DRIVER_VERSION}"
    tmp="${SRC_TARBALL}.part"
    rm -f "$tmp"
    curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -o "$tmp" "$NV_SRC_URL"
    mv -f "$tmp" "$SRC_TARBALL"
fi

echo "${EXPECTED_SHA256}  ${SRC_TARBALL}" | sha256sum -c - >/dev/null

SRC="${WORK}/NVIDIA-kernel-module-source-${DRIVER_VERSION}-${KREL}-cmp90hx"
rm -rf "$SRC" "${WORK}/extract-${DRIVER_VERSION}-${KREL}"
mkdir -p "${WORK}/extract-${DRIVER_VERSION}-${KREL}"
log "extracting source"
tar -xf "$SRC_TARBALL" -C "${WORK}/extract-${DRIVER_VERSION}-${KREL}"
mapfile -t roots < <(find "${WORK}/extract-${DRIVER_VERSION}-${KREL}" -mindepth 1 -maxdepth 1 -type d | sort)
if [[ "${#roots[@]}" -eq 1 ]]; then
    mv "${roots[0]}" "$SRC"
else
    mv "${WORK}/extract-${DRIVER_VERSION}-${KREL}" "$SRC"
fi

log "applying CMP90HX patches 0014+0015+0016+0017"
(
    cd "$SRC"
    patch -p1 -s < "${PATCH_DIR}/0014-6104303-cmp90hx-stockflow-rejoin14-multigpu-state.patch"
    patch -p1 -s < "${PATCH_DIR}/0015-6104303-cmp90hx-stockflow-rejoin15-serialized-start.patch"
    patch -p1 -s < "${PATCH_DIR}/0016-6104303-cmp90hx-stockflow-rejoin16-pcie-jtag-plm.patch"
    patch -p1 -s < "${PATCH_DIR}/0017-cmp90hx-gen2-retrain-retry.patch"

    if ! grep -qF CMP90_LOW_MEM_G_BINDATA src/nvidia/Makefile; then
        printf '\n# CMP90_LOW_MEM_G_BINDATA: compile generated/g_bindata.c at O0 on low-memory rigs.\n' >> src/nvidia/Makefile
        printf '$(call BUILD_OBJECT_LIST,generated/g_bindata.c): CFLAGS := $(filter-out -O2,$(CFLAGS)) -O0\n' >> src/nvidia/Makefile
    fi

    log "building modules with JOBS=${JOBS}"
    make modules -j"$JOBS" KERNEL_UNAME="$KREL"
)

ART="${SRC}/kernel-open"
[[ -f "$ART/nvidia.ko" ]] || die "build did not produce nvidia.ko"
[[ "$(modinfo -F version "$ART/nvidia.ko")" == "$DRIVER_VERSION" ]] || die "built module version mismatch"
[[ "$(modinfo -F vermagic "$ART/nvidia.ko" | awk '{print $1}')" == "$KREL" ]] || die "vermagic mismatch"
strings "$ART/nvidia.ko" > "${WORK}/strings-${KREL}.txt" 2>/dev/null || true
grep -q CMP90_STOCKFLOW_REJOIN16 "${WORK}/strings-${KREL}.txt" || die "rejoin16 marker missing"

log "installing modules to $UPDATES"
if [[ -d "$UPDATES" ]]; then
    mv "$UPDATES" "${UPDATES}.bak.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$UPDATES"
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
    [[ -f "$ART/$m.ko" ]] && install -m0644 "$ART/$m.ko" "$UPDATES/$m.ko"
done

log "installing depmod override"
mkdir -p /etc/depmod.d
cat > /etc/depmod.d/cmp90hx-gen2.conf <<'EOF_DEPMOD'
# Force patched CMP 90HX unlock modules ahead of stock DKMS modules.
override nvidia * updates/cmpunlocker-90hx-stockflow
override nvidia-uvm * updates/cmpunlocker-90hx-stockflow
override nvidia-modeset * updates/cmpunlocker-90hx-stockflow
override nvidia-drm * updates/cmpunlocker-90hx-stockflow
override nvidia-peermem * updates/cmpunlocker-90hx-stockflow
EOF_DEPMOD

depmod -a "$KREL"
if ! modprobe --show-depends nvidia 2>/dev/null | grep -q "$UPDATES"; then
    log "WARNING: modprobe does not resolve nvidia to $UPDATES; inspect /etc/depmod.d/cmp90hx-gen2.conf"
fi

log "installing nvidia no-auto-load blacklist"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/cmp90hx-gen2-noauto.conf <<'EOF_NOAUTO'
# cmp90hx-compute.service loads NVIDIA itself: stock prime first, patched final load second.
blacklist nvidia
blacklist nvidia-uvm
blacklist nvidia-modeset
blacklist nvidia-drm
blacklist nvidia-peermem
EOF_NOAUTO
chmod 0644 /etc/modprobe.d/cmp90hx-gen2-noauto.conf
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k "$KREL" || true

log "installing helper binaries to $PREFIX"
mkdir -p "$PREFIX"
gcc -O2 -Wall -Wextra -o "$PREFIX/bar0poke" "${REPO}/tools/bar0poke.c"

cat > "$PREFIX/BUILD-INFO" <<EOF_INFO
driver_version=${DRIVER_VERSION}
kernel_release=${KREL}
source_tarball=${SRC_TARBALL}
patches=0014,0015,0016,0017
modules=${UPDATES}
built_at=$(date -Is)
EOF_INFO

log "PASS_CMP90HX_PWNER_LOCAL_REJOIN16_BUILD"
