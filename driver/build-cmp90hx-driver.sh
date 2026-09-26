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

log(){ echo "[cmp90hx-build] $*"; }
die(){ echo "[cmp90hx-build][FAIL] $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "run as root"
[[ -d "/lib/modules/${KREL}/build" ]] || die "kernel headers missing: /lib/modules/${KREL}/build"
for c in awk curl find gcc install make mkdir modinfo patch sha256sum sort strings tar; do
    command -v "$c" >/dev/null 2>&1 || die "required command missing: $c"
done

cur="$(modinfo -F version nvidia 2>/dev/null || true)"
if [[ "$cur" != "$DRIVER_VERSION" ]]; then
    cat >&2 <<EOF
[cmp90hx-build][FAIL] stock NVIDIA module is '$cur', expected '$DRIVER_VERSION'.
This installer no longer downloads the full NVIDIA .run package.
Install matching NVIDIA ${DRIVER_VERSION} userland/stock module first, then rerun COMPUTE UNLOCK.
EOF
    exit 20
fi

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
