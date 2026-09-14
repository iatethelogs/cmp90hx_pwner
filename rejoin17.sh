#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CMP90HX Pwner
# Repository: https://github.com/iatethelogs/cmp90hx_pwner
# Copyright (c) iatethelogs
# Credits:
#   pearlfortune/cmpunlocker  - compute unlock, rejoin15, V67 FEAT/PLM 0x823800/0x823804
#   jdowning100/cmpunlocker   - rejoin16 Gen2 path, XVE/LTSSM 0x088fe8
#   Wh1stle05/cmp90hx         - NVIDIA 610.43.03 Linux installer and patch packaging

set -Eeuo pipefail

PROGRAM_NAME="CMP90HX Pwner"
REPO_URL="https://github.com/iatethelogs/cmp90hx_pwner"
DRIVER_VERSION="${DRIVER_VERSION:-610.43.03}"
PROJECT_REPO="${PROJECT_REPO:-https://github.com/Wh1stle05/cmp90hx.git}"
PROJECT_DIR="${PROJECT_DIR:-/usr/local/src/cmp90hx-pwner/cmp90hx}"
PREFIX="${PREFIX:-/opt/cmp90hx-gen2}"
STATE_DIR="${STATE_DIR:-/var/lib/cmp90hx-pwner}"
RUNTIME_STATE_DIR="${RUNTIME_STATE_DIR:-/var/lib/cmpunlocker-rs}"
LOG_DIR="${LOG_DIR:-/var/log}"
LOG="${LOG:-${LOG_DIR}/cmp90hx-pwner-$(date +%Y%m%d-%H%M%S).log}"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
AUTO_REBOOT_IF_NOUVEAU="${AUTO_REBOOT_IF_NOUVEAU:-0}"
PURGE_NVIDIA_PACKAGES="${PURGE_NVIDIA_PACKAGES:-1}"
KILL_GPU_PROCS="${KILL_GPU_PROCS:-1}"
SERVICE_NAME="cmp90hx-gen2.service"
BOOT_GATE="${PREFIX}/rejoin17-boot-gate.sh"
APPLY_SCRIPT="${PREFIX}/rejoin17-apply-all.sh"
SSH_PROFILE="/etc/profile.d/cmp90hx-pwner-login.sh"
NVIDIA_RUN_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
NVIDIA_RUN="/var/tmp/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

export LC_ALL=C

if [[ "${1:-}" == "--no-tui" ]]; then
    export CMP90HX_NO_TUI=1
    shift
fi

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$SELF_PATH" "$@"
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 0777 "$STATE_DIR" 2>/dev/null || true

launch_tui() {
    [[ "${CMP90HX_TUI_CHILD:-0}" == "1" ]] && return 0
    [[ "${CMP90HX_NO_TUI:-0}" == "1" || "${NO_TUI:-0}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]] || return 0
    [[ -n "${TMUX:-}" ]] && return 0

    if ! command -v tmux >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y tmux >/dev/null 2>&1 || true
        fi
    fi
    command -v tmux >/dev/null 2>&1 || return 0

    local session runner tailer a
    session="cmp90hx-pwner-$$"
    runner="/tmp/cmp90hx-pwner-runner-$$.sh"
    tailer="/tmp/cmp90hx-pwner-tailer-$$.sh"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'export CMP90HX_TUI_CHILD=1\n'
        printf 'export FORCE_COLOR=1\n'
        printf 'export LOG=%q\n' "$LOG"
        printf 'exec bash %q' "$SELF_PATH"
        for a in "$@"; do printf ' %q' "$a"; done
        printf '\n'
    } > "$runner"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'touch %q\n' "$LOG"
        printf 'printf "DETAILED COMMAND LOG: %s\\n\\n" %q\n' "$LOG" "$LOG"
        printf 'tail -n +1 -F %q\n' "$LOG"
    } > "$tailer"

    chmod +x "$runner" "$tailer"
    tmux new-session -d -s "$session" -n "$PROGRAM_NAME" "bash '$runner'; rc=\$?; sleep 1; exit \"\$rc\""
    tmux split-window -h -l 55% -t "$session:0" "bash '$tailer'"
    tmux select-pane -t "$session:0.0"
    tmux select-layout -t "$session:0" even-horizontal >/dev/null 2>&1 || true
    tmux attach -t "$session"
    local rc=$?
    rm -f "$runner" "$tailer" 2>/dev/null || true
    exit "$rc"
}
launch_tui "$@"

STATUS_FD=1
if [[ "${CMP90HX_TUI_CHILD:-0}" == "1" && -w /dev/tty ]]; then
    exec 3>/dev/tty
    STATUS_FD=3
    exec >>"$LOG" 2>&1
else
    exec > >(tee -a "$LOG") 2>&1
fi

if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    RST=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; ORANGE=''; CYAN=''
else
    RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; ORANGE=$'\033[38;5;208m'; CYAN=$'\033[36m'
fi

ui() { printf "$@" >&"$STATUS_FD"; }
cmdlog() { printf '\n[%s] %s\n' "$(date -Is)" "$*"; }
ok() { ui '%b[ OK ]%b %s\n' "${GREEN}${BOLD}" "$RST" "$*"; }
warn() { ui '%b[WARN]%b %s\n' "${YELLOW}${BOLD}" "$RST" "$*"; }
fail() { ui '%b[FAIL]%b %s\n' "${RED}${BOLD}" "$RST" "$*"; }
die() { fail "$*"; ui 'LOG: %s\n' "$LOG"; exit 1; }
clear_left() { [[ -t "$STATUS_FD" ]] && ui '\033[H\033[2J' || true; }

draw_banner() {
    ui '%b' "$ORANGE$BOLD"
    cat >&"$STATUS_FD" <<'EOF_BANNER'

      ____   ___   ______ ______   ______ __  __ ______   __    ____  __________   __ __ __
     /  _/  /   | /_  __// ____/  /_  __// / / // ____/  / /   / __ \/ ____/ ___/  / // // /
     / /   / /| |  / /  / __/      / /  / /_/ // __/    / /   / / / / / __ \__ \  / // // /
   _/ /   / ___ | / /  / /___     / /  / __  // /___   / /___/ /_/ / /_/ /___/ / /_//_//_/
  /___/  /_/  |_|/_/  /_____/    /_/  /_/ /_//_____/  /_____/\____/\____//____/ (_)(_) (_)

EOF_BANNER
    ui '%b' "$RST"
    ui '%b%s%b\n' "$CYAN$BOLD" "$PROGRAM_NAME" "$RST"
    ui '%b%s%b\n' "$DIM" "$REPO_URL" "$RST"
    ui '%bCopyright (c) iatethelogs%b\n\n' "$DIM" "$RST"
    ui '%bUsed work:%b\n' "$BOLD" "$RST"
    ui '  pearlfortune/cmpunlocker  compute unlock, rejoin15, V67 FEAT/PLM 0x823800/0x823804\n'
    ui '  jdowning100/cmpunlocker   rejoin16 Gen2 path, XVE/LTSSM 0x088fe8\n'
    ui '  Wh1stle05/cmp90hx         NVIDIA %s Linux installer and patch packaging\n\n' "$DRIVER_VERSION"
}
banner() {
    draw_banner
}

menu() {
    clear_left
    banner 1
    ui '1) UNLOCK THIS SHIT\n'
    ui '2) VERIFY\n'
    ui '3) INSTALL CUDA TOOLKIT\n'
    ui '4) UNINSTALL\n'
    ui '0) EXIT\n\nSelect: '
}

STEP_NO=0
TOTAL_STEPS=1
spinner_chars=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

shorten() {
    local text="$1" max="${2:-34}"
    if (( ${#text} > max )); then printf '%s…' "${text:0:$((max-1))}"; else printf '%s' "$text"; fi
}

run_step() {
    local label="$1" clean shown i pid rc elapsed spin
    shift
    STEP_NO=$((STEP_NO + 1))
    clean="$(shorten "$label" 34)"
    shown=$(printf '%02d/%02d  %-34s' "$STEP_NO" "$TOTAL_STEPS" "$clean")
    ui '\n%s ' "$shown"
    cmdlog "START: $label"
    ( "$@" ) >>"$LOG" 2>&1 &
    pid=$!
    i=0
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        spin="${spinner_chars[$((i % ${#spinner_chars[@]}))]}"
        ui '\r\033[K%s %b%s%b %3ss' "$shown" "$ORANGE" "$spin" "$RST" "$elapsed"
        sleep 0.25
        i=$((i + 1))
        (( i % 4 == 0 )) && elapsed=$((elapsed + 1))
    done
    set +e
    wait "$pid"
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
        ui '\r\033[K%s %b[ OK ]%b\n' "$shown" "${GREEN}${BOLD}" "$RST"
        cmdlog "OK: $label"
    else
        ui '\r\033[K%s %b[ FAIL ]%b\n' "$shown" "${RED}${BOLD}" "$RST"
        cmdlog "FAIL: $label rc=$rc"
        return "$rc"
    fi
}

apt_install_base() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl wget git tmux pciutils kmod build-essential dkms linux-headers-"$(uname -r)" python3 python3-minimal initramfs-tools gzip tar make gcc g++
}

install_cuda_toolkit() {
    export DEBIAN_FRONTEND=noninteractive

    local os_id os_ver distro arch keyring_deb keyring_url
    os_id=""
    os_ver=""
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        os_id="${ID:-}"
        os_ver="${VERSION_ID:-}"
    fi

    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ "$arch" == "amd64" ]] || { printf 'unsupported architecture for NVIDIA CUDA repo: %s\n' "$arch"; return 2; }

    case "${os_id}:${os_ver}" in
        ubuntu:20.04) distro="ubuntu2004" ;;
        ubuntu:22.04) distro="ubuntu2204" ;;
        ubuntu:24.04) distro="ubuntu2404" ;;
        debian:11) distro="debian11" ;;
        debian:12) distro="debian12" ;;
        *)
            printf 'unsupported distro for automatic NVIDIA CUDA repo: ID=%s VERSION_ID=%s\n' "$os_id" "$os_ver"
            printf 'supported here: Ubuntu 20.04/22.04/24.04, Debian 11/12\n'
            return 2
            ;;
    esac

    apt-get update
    apt-get install -y ca-certificates curl wget gnupg lsb-release

    keyring_deb="/var/tmp/cuda-keyring_1.1-1_${distro}_all.deb"
    keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb"

    download_with_retry "$keyring_url" "$keyring_deb"
    dpkg -i "$keyring_deb"

    apt-get update

    # Toolkit only. Do not install the CUDA driver meta-package here.
    apt-get install -y cuda-toolkit

    command -v nvcc >/dev/null 2>&1 && nvcc --version || true
}

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        if [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]]; then
            basename "$d"
        fi
    done | sort
}

upstream_of() {
    local bdf="$1"
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$bdf")")"
}

card_is_gen2() {
    local cmp="$1" up speed endpoint upstream
    up="$(upstream_of "$cmp")"
    speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

verify_links() {
    command -v lspci >/dev/null 2>&1 || { printf 'lspci missing\n'; return 1; }
    local cmps cmp up speed width endpoint upstream total=0 okc=0
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 2; }
    for cmp in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$cmp")"
        speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/${cmp}/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
        printf '%s upstream=%s speed=%s width=%s\n' "$cmp" "$up" "$speed" "$width"
        printf '  endpoint %s\n' "$endpoint"
        printf '  upstream %s\n' "$upstream"
        card_is_gen2 "$cmp" && okc=$((okc + 1))
    done
    printf 'GEN2 %s/%s\n' "$okc" "$total"
    [[ "$okc" == "$total" ]]
}

backup_state() {
    local bdir="/root/cmp90hx-pwner-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir"
    {
        date -Is
        uname -a
        lspci -Dnn | grep -Ei '10de|nvidia' || true
        modinfo -F version nvidia 2>/dev/null || true
        modinfo -F srcversion nvidia 2>/dev/null || true
        lsmod | grep -E '^nvidia|^nouveau|^ecc' || true
    } > "$bdir/system.txt"
    cp -a "$PREFIX" "$bdir/opt-cmp90hx-gen2" 2>/dev/null || true
    cp -a /etc/systemd/system/cmp90hx*.service "$bdir/" 2>/dev/null || true
    cp -a /etc/modprobe.d "$bdir/modprobe.d" 2>/dev/null || true
    cp -a /etc/depmod.d "$bdir/depmod.d" 2>/dev/null || true
    printf '%s\n' "$bdir" > "$STATE_DIR/last-backup"
    printf 'backup: %s\n' "$bdir"
}

stop_gpu_users() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop nvidia-persistenced ollama llama open-webui librechat comfyui 2>/dev/null || true
    if [[ "$KILL_GPU_PROCS" == "1" ]]; then
        pkill -f 'llama-server' 2>/dev/null || true
        pkill -f '/opt/llama.cpp' 2>/dev/null || true
        ls /dev/nvidia* >/dev/null 2>&1 && fuser -k /dev/nvidia* 2>/dev/null || true
    fi
    sleep 1
}

unload_nvidia_modules() {
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia 2>/dev/null || true
    sleep 1
}

sanitize_depmod() {
    find /etc/depmod.d -type f \( -name '*cmp90hx*' -o -name '*rejoin*' -o -name '*pwner*' \) -print -delete 2>/dev/null || true
}

blacklist_nouveau() {
    mkdir -p /etc/modprobe.d /etc/default/grub.d "$STATE_DIR"
    cat > /etc/modprobe.d/blacklist-nouveau-cmp90hx.conf <<'EOF_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
alias nouveau off
install nouveau /bin/false
EOF_NOUVEAU
    cat > /etc/modprobe.d/nvidia-installer-disable-nouveau.conf <<'EOF_NVIDIA_NOUVEAU'
blacklist nouveau
options nouveau modeset=0
EOF_NVIDIA_NOUVEAU
    cat > /etc/default/grub.d/99-cmp90hx-pwner-nouveau.cfg <<'EOF_GRUB_NOUVEAU'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT modprobe.blacklist=nouveau nouveau.modeset=0 rd.driver.blacklist=nouveau"
EOF_GRUB_NOUVEAU
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]] && grub-mkconfig -o /boot/grub/grub.cfg || true
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true

    if lsmod | grep -q '^nouveau'; then
        systemctl stop display-manager 2>/dev/null || true
        for dev in /sys/bus/pci/drivers/nouveau/0000:*; do
            [[ -e "$dev" ]] && printf '%s' "${dev##*/}" > /sys/bus/pci/drivers/nouveau/unbind 2>/dev/null || true
        done
        modprobe -r nouveau 2>/dev/null || true
    fi

    if lsmod | grep -q '^nouveau'; then
        local count_file count
        count_file="$STATE_DIR/nouveau-reboot-count"
        count="$(cat "$count_file" 2>/dev/null || echo 0)"
        if [[ "$AUTO_REBOOT_IF_NOUVEAU" == "1" && "$count" == "0" ]]; then
            echo 1 > "$count_file"
            sync
            systemctl reboot
            sleep 60
        fi
        printf 'nouveau is still loaded. Reboot once, then run installer again.\n'
        printf 'cmdline: %s\n' "$(cat /proc/cmdline 2>/dev/null || true)"
        return 50
    fi
    rm -f "$STATE_DIR/nouveau-reboot-count" 2>/dev/null || true
}

remove_bootloader_nouveau_blacklist() {
    rm -f /etc/default/grub.d/99-cmp90hx-pwner-nouveau.cfg /etc/modprobe.d/blacklist-nouveau-cmp90hx.conf /etc/modprobe.d/nvidia-installer-disable-nouveau.conf 2>/dev/null || true
    python3 - <<'PY_REMOVE_GRUB' || true
from pathlib import Path
p = Path('/etc/default/grub')
if p.exists():
    remove = {'modprobe.blacklist=nouveau', 'nouveau.modeset=0', 'rd.driver.blacklist=nouveau'}
    out = []
    for line in p.read_text(errors='replace').splitlines():
        if line.startswith('GRUB_CMDLINE_LINUX_DEFAULT='):
            prefix, value = line.split('=', 1)
            tokens = [t for t in value.strip().strip('"').split() if t not in remove]
            line = prefix + '="' + ' '.join(tokens) + '"'
        out.append(line)
    p.write_text('\n'.join(out) + '\n')
PY_REMOVE_GRUB
    command -v update-grub >/dev/null 2>&1 && update-grub || true
    command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]] && grub-mkconfig -o /boot/grub/grub.cfg || true
}

purge_old_pwner() {
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable --now cmp90hx-pwner-firstboot-ui.service cmp90hx-pwner-ssh-gate.service 2>/dev/null || true
    systemctl unmask ssh.service sshd.service 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME" \
          /etc/systemd/system/cmp90hx-pwner-firstboot-ui.service \
          /etc/systemd/system/cmp90hx-pwner-ssh-gate.service 2>/dev/null || true
    rm -f "$SSH_PROFILE" \
          /etc/profile.d/cmp90hx-pwner-firstboot.sh \
          /etc/profile.d/cmp90hx-pwner-login.sh 2>/dev/null || true
    rm -f /etc/update-motd.d/99-cmp90hx-pwner 2>/dev/null || true
    rm -rf "$PREFIX" "$RUNTIME_STATE_DIR" "$STATE_DIR" "$PROJECT_DIR" /usr/local/src/cmp90hx-rejoin17 2>/dev/null || true
    rm -f /etc/depmod.d/cmp90hx-gen2.conf /etc/depmod.d/*cmp90hx* /etc/depmod.d/*rejoin* /etc/depmod.d/*pwner* 2>/dev/null || true
    rm -f /etc/modprobe.d/cmp90hx-gen2-noauto.conf /etc/modprobe.d/*cmp90hx* /etc/modprobe.d/*rejoin* /etc/modprobe.d/*pwner* 2>/dev/null || true
    sanitize_depmod
    systemctl daemon-reload || true
    mkdir -p "$STATE_DIR"
    chmod 0777 "$STATE_DIR" 2>/dev/null || true
}

nvidia_uninstall_best_effort() {
    stop_gpu_users || true
    unload_nvidia_modules || true

    if command -v nvidia-uninstall >/dev/null 2>&1; then
        nvidia-uninstall --silent --no-runlevel-check 2>/dev/null || true
    fi

    if command -v dkms >/dev/null 2>&1; then
        dkms status 2>/dev/null | awk -F, '/nvidia|cmp|rejoin/ {print $1","$2}' | while IFS=, read -r name ver; do
            name="${name// /}"
            ver="${ver// /}"
            [[ -n "$name" && -n "$ver" ]] && dkms remove -m "$name" -v "$ver" --all 2>/dev/null || true
        done
    fi

    if [[ "$PURGE_NVIDIA_PACKAGES" == "1" && -x /usr/bin/apt-get ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y 'nvidia-*' 'libnvidia-*' 'cuda-drivers*' 'cuda-toolkit-*' 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    find /lib/modules /usr/lib/modules -type d \( -name 'cmpunlocker*' -o -name '*cmp90hx*' -o -name '*rejoin*' -o -name '*pwner*' \) -prune -exec rm -rf {} + 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/updates/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/extra/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true
    find /lib/modules /usr/lib/modules -path '*/weak-updates/*' \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' \) -delete 2>/dev/null || true

    rm -rf /usr/local/src/cmp90hx-pwner /usr/local/src/cmp90hx-rejoin17 /usr/src/nvidia-* /var/lib/dkms/nvidia 2>/dev/null || true
    rm -f /etc/ld.so.conf.d/nvidia*.conf /etc/OpenCL/vendors/nvidia.icd 2>/dev/null || true
    rm -f /usr/bin/nvidia-smi /usr/bin/nvidia-debugdump /usr/bin/nvidia-persistenced /usr/bin/nvidia-settings /usr/bin/nvidia-uninstall /usr/bin/nvidia-modprobe 2>/dev/null || true
    rm -f /var/tmp/NVIDIA-Linux-x86_64-*.run 2>/dev/null || true

    ldconfig 2>/dev/null || true
    depmod -a || true
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true
}


download_with_retry() {
    local url="$1" out="$2" tmp attempts delay
    attempts="${DOWNLOAD_ATTEMPTS:-10}"
    delay="${DOWNLOAD_RETRY_DELAY:-8}"
    tmp="${out}.part"
    mkdir -p "$(dirname "$out")"

    for ((i=1; i<=attempts; i++)); do
        printf 'download attempt %s/%s: %s\n' "$i" "$attempts" "$url"
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            if curl -fL --connect-timeout 30 --retry 2 --retry-delay 5 --retry-all-errors -o "$tmp" "$url"; then
                mv -f "$tmp" "$out"
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget --tries=3 --waitretry=5 --timeout=30 --read-timeout=60 -O "$tmp" "$url"; then
                mv -f "$tmp" "$out"
                return 0
            fi
        else
            printf 'curl/wget missing\n'
            return 127
        fi
        printf 'download failed, retry in %ss\n' "$delay"
        sleep "$delay"
    done
    rm -f "$tmp"
    return 1
}

git_clone_retry() {
    local repo="$1" dst="$2" attempts delay
    attempts="${GIT_ATTEMPTS:-6}"
    delay="${GIT_RETRY_DELAY:-8}"
    rm -rf "$dst"
    for ((i=1; i<=attempts; i++)); do
        printf 'git clone attempt %s/%s: %s\n' "$i" "$attempts" "$repo"
        if git clone --depth 1 "$repo" "$dst"; then
            return 0
        fi
        rm -rf "$dst"
        printf 'git clone failed, retry in %ss\n' "$delay"
        sleep "$delay"
    done
    return 1
}

install_stock_driver() {
    mkdir -p "$(dirname "$NVIDIA_RUN")"

    if [[ ! -s "$NVIDIA_RUN" ]]; then
        download_with_retry "$NVIDIA_RUN_URL" "$NVIDIA_RUN"
    fi

    chmod +x "$NVIDIA_RUN"
    bash "$NVIDIA_RUN" \
        --silent \
        --accept-license \
        --no-questions \
        --no-cc-version-check \
        --no-nouveau-check

    depmod -a
}

install_patched_driver() {
    mkdir -p "$(dirname "$PROJECT_DIR")"
    git_clone_retry "$PROJECT_REPO" "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    bash scripts/install.sh
    depmod -a
}

preserve_rejoin_verifiers() {
    mkdir -p "$PREFIX"
    local bin check copied=0

    bin="$(find_rejoin_verifier_bin || true)"
    if [[ -n "$bin" && -x "$bin" ]]; then
        install -m 0755 "$bin" "$PREFIX/cmpunlocker-rs"
        printf 'saved built-in verifier: %s -> %s\n' "$bin" "$PREFIX/cmpunlocker-rs"
        copied=1
    fi

    check="$(find_rejoin_check_sh || true)"
    if [[ -n "$check" && -f "$check" ]]; then
        install -m 0755 "$check" "$PREFIX/check.sh"
        printf 'saved check.sh: %s -> %s\n' "$check" "$PREFIX/check.sh"
        copied=1
    fi

    if [[ "$copied" != "1" ]]; then
        printf 'warning: no built-in rejoin verifier found during install\n'
        printf 'verify will fail until cmpunlocker-rs or check.sh is available\n'
    fi
}

write_apply_script() {
    mkdir -p "$PREFIX"
    cat > "$APPLY_SCRIPT" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
PREFIX="/opt/cmp90hx-gen2"
log() { printf '[cmp90hx-pwner] %s\n' "$*"; }
find_cmps() { for d in /sys/bus/pci/devices/*; do [[ -f "$d/vendor" && -f "$d/device" ]] || continue; [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"; done | sort; }
upstream_of() { basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"; }
card_is_gen2() { local cmp="$1" up speed endpoint upstream; up="$(upstream_of "$cmp")"; speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"; endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"; upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"; [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]; }
verify_links() { local cmps cmp up speed width endpoint upstream total=0 okc=0; mapfile -t cmps < <(find_cmps); (( ${#cmps[@]} > 0 )) || { log "no CMP 90HX 10de:220d devices found"; return 2; }; for cmp in "${cmps[@]}"; do total=$((total+1)); up="$(upstream_of "$cmp")"; speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"; width="$(cat "/sys/bus/pci/devices/${cmp}/current_link_width" 2>/dev/null || true)"; endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"; upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"; log "$cmp upstream=$up speed=$speed width=$width"; log "  endpoint $endpoint"; log "  upstream $upstream"; card_is_gen2 "$cmp" && okc=$((okc+1)); done; log "GEN2 $okc/$total"; [[ "$okc" == "$total" ]]; }
[[ "${1:-}" == "--verify-only" ]] && { verify_links; exit $?; }
verify_links && { log "already Gen2"; exit 0; }
[[ -x "$PREFIX/cmp90hx-gen2-handoff.sh" ]] || { log "missing handoff script"; exit 11; }
[[ -x "$PREFIX/cmp90hx-gen2-minimal.sh" ]] || { log "missing minimal script"; exit 12; }
log "handoff"
bash "$PREFIX/cmp90hx-gen2-handoff.sh"
log "Gen2 runtime"
bash "$PREFIX/cmp90hx-gen2-minimal.sh"
sleep 3
verify_links
EOF_APPLY
    chmod +x "$APPLY_SCRIPT"
}

write_boot_gate() {
    mkdir -p "$PREFIX" "$STATE_DIR"
    cat > "$BOOT_GATE" <<'EOF_BOOT_GATE'
#!/usr/bin/env bash
set -Eeuo pipefail
PREFIX="/opt/cmp90hx-gen2"
STATE_DIR="/var/lib/cmp90hx-pwner"
APPLY_SCRIPT="$PREFIX/rejoin17-apply-all.sh"
LOG="/var/log/cmp90hx-pwner-boot.log"
MAX_WAIT="${CMP90HX_BOOT_MAX_WAIT:-420}"
INTERVAL="${CMP90HX_BOOT_INTERVAL:-20}"
mkdir -p "$STATE_DIR"
chmod 0777 "$STATE_DIR" 2>/dev/null || true
exec >>"$LOG" 2>&1
log(){ printf '[%s] %s\n' "$(date -Is)" "$*"; }
boot_id(){ cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown; }
write_status(){
    local status="$1" elapsed="$2"
    {
        printf 'boot_id=%s\n' "$(boot_id)"
        printf 'status=%s\n' "$status"
        printf 'elapsed=%s\n' "$elapsed"
        printf 'time=%s\n' "$(date -Is)"
        printf 'log=%s\n' "$LOG"
    } > "$STATE_DIR/boot-status"
    chmod 0666 "$STATE_DIR/boot-status" 2>/dev/null || true
}
verify_gen2(){ bash "$APPLY_SCRIPT" --verify-only; }
verify_compute(){
    if [[ -x "$PREFIX/cmpunlocker-rs" ]]; then
        "$PREFIX/cmpunlocker-rs" compute90hx-v67 verify --all-cmp90hx --expect full
        return $?
    fi
    if [[ -x "$PREFIX/check.sh" ]]; then
        ( cd "$PREFIX" && bash ./check.sh )
        return $?
    fi
    log "no rejoin compute verifier found"
    return 20
}
verify_all(){
    verify_compute && verify_gen2
}
apply(){ bash "$APPLY_SCRIPT"; }
start=$(date +%s)
attempt=1
log "boot gate start boot_id=$(boot_id) max_wait=${MAX_WAIT}s interval=${INTERVAL}s"
while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if verify_all; then
        log "compute + Gen2 verified after ${elapsed}s"
        write_status OK "$elapsed"
        exit 0
    fi
    log "apply attempt ${attempt}, elapsed ${elapsed}s"
    apply || true
    sleep 5
    now=$(date +%s)
    elapsed=$((now - start))
    if verify_all; then
        log "compute + Gen2 verified after apply, elapsed ${elapsed}s"
        write_status OK "$elapsed"
        exit 0
    fi
    if (( elapsed >= MAX_WAIT )); then
        log "FAIL: compute + Gen2 were not verified inside ${MAX_WAIT}s"
        write_status FAIL "$elapsed"
        exit 1
    fi
    sleep "$INTERVAL"
    attempt=$((attempt + 1))
done
EOF_BOOT_GATE
    chmod +x "$BOOT_GATE"
}

write_systemd_service() {
    cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF_SERVICE
[Unit]
Description=CMP90HX Pwner Gen2 boot apply
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service local-fs.target systemd-modules-load.service
Before=nvidia-persistenced.service ollama.service llama.service open-webui.service librechat.service comfyui.service

[Service]
Type=oneshot
ExecStart=$BOOT_GATE
RemainAfterExit=yes
TimeoutStartSec=900
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

write_ssh_login_gate() {
    mkdir -p "$STATE_DIR"
    chmod 0777 "$STATE_DIR" 2>/dev/null || true
    cat > "$SSH_PROFILE" <<'EOF_PROFILE'
# CMP90HX Pwner first SSH login notice. Generated by rejoin17.sh.
# This hook never blocks sshd and never closes the user session.
case "$-" in *i*) ;; *) return 0 2>/dev/null || true ;; esac
[ -t 0 ] && [ -t 1 ] || return 0 2>/dev/null || true
[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 0 2>/dev/null || true

STATE_DIR="/var/lib/cmp90hx-pwner"
SERVICE_NAME="cmp90hx-gen2.service"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
SHOWN="/tmp/cmp90hx-pwner-ssh-shown-${USER:-user}-${BOOT_ID}"
LOCK="/tmp/cmp90hx-pwner-ssh-lock-${BOOT_ID}"
STATUS="$STATE_DIR/boot-status"

[ -f "$SHOWN" ] && return 0 2>/dev/null || true
mkdir "$LOCK" 2>/dev/null || return 0 2>/dev/null || true
cleanup_lock(){ rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup_lock EXIT

read_status_field(){ awk -F= -v k="$1" '$1==k {print $2}' "$STATUS" 2>/dev/null | tail -1; }

wait_boot_gate(){
    local max=480 elapsed=0 status_boot status svc
    printf '\n\033[36;1mCMP90HX Pwner\033[0m\n'
    while (( elapsed <= max )); do
        status_boot=""
        status=""
        if [ -r "$STATUS" ]; then
            status_boot="$(read_status_field boot_id)"
            status="$(read_status_field status)"
            if [ "$status_boot" = "$BOOT_ID" ]; then
                if [ "$status" = "OK" ]; then
                    printf '\r\033[K\033[32;1m[ OK ]\033[0m boot verify passed after %ss\n' "$elapsed"
                    return 0
                fi
                if [ "$status" = "FAIL" ]; then
                    printf '\r\033[K\033[31;1m[ FAIL ]\033[0m boot verify failed\n'
                    return 1
                fi
            fi
        fi

        svc="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
        if [ "$svc" = "failed" ]; then
            printf '\r\033[K\033[31;1m[ FAIL ]\033[0m %s failed\n' "$SERVICE_NAME"
            return 1
        fi

        printf '\r\033[K\033[33;1m[ WAIT ]\033[0m applying compute unlock + Gen2: %03ds / %03ds' "$elapsed" "$max"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    printf '\n\033[31;1m[ FAIL ]\033[0m timeout while waiting for boot verify\n'
    return 1
}

show_ok(){
    printf '\n\033[38;5;208m        /\_/\\\n'
    printf '       ( o.o )\n'
    printf '        > ^ <\033[0m\n\n'
    printf '\033[32;1mCMP90HX PWNED\033[0m  '
    printf '\033[36;1mENJOY!\033[0m  '
    printf '\033[38;5;208m\033[1mHA HA FULL SPEED\033[0m\n\n'
}

show_fail(){
    printf '\n\033[31;1mCMP90HX FAIL\033[0m\n'
    printf 'SSH is not blocked. Shell is available for repair.\n'
    printf 'Diagnostics:\n'
    printf '  systemctl status %s --no-pager\n' "$SERVICE_NAME"
    printf '  journalctl -b -u %s --no-pager\n\n' "$SERVICE_NAME"
}

if wait_boot_gate; then
    show_ok
else
    show_fail
fi

date -Is > "$SHOWN" 2>/dev/null || true
return 0 2>/dev/null || true
EOF_PROFILE
    chmod 0644 "$SSH_PROFILE"
}

write_runtime_all() {
    write_apply_script
    write_boot_gate
    write_systemd_service
    write_ssh_login_gate
}

apply_now() {
    [[ -x "$APPLY_SCRIPT" ]] || return 10
    bash "$APPLY_SCRIPT"
}

bind_cmps_to_nvidia() {
    local cmps cmp dev drv ok=0 total=0
    command -v modprobe >/dev/null 2>&1 || { printf 'modprobe missing\n'; return 30; }
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    sleep 1

    [[ -d /sys/bus/pci/drivers/nvidia ]] || { printf 'nvidia PCI driver is not registered\n'; return 31; }

    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 32; }

    for cmp in "${cmps[@]}"; do
        total=$((total + 1))
        dev="/sys/bus/pci/devices/$cmp"
        drv=""
        if [[ -L "$dev/driver" ]]; then
            drv="$(basename "$(readlink -f "$dev/driver")")"
        fi

        if [[ "$drv" != "nvidia" ]]; then
            printf '%s: binding to nvidia driver\n' "$cmp"
            if [[ -n "$drv" && -e "$dev/driver/unbind" ]]; then
                printf '%s' "$cmp" > "$dev/driver/unbind" 2>/dev/null || true
                sleep 1
            fi
            printf 'nvidia' > "$dev/driver_override" 2>/dev/null || true
            printf '%s' "$cmp" > /sys/bus/pci/drivers_probe 2>/dev/null || true
            if [[ ! -L "$dev/driver" ]]; then
                printf '%s' "$cmp" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
            fi
            sleep 1
        fi

        drv=""
        if [[ -L "$dev/driver" ]]; then
            drv="$(basename "$(readlink -f "$dev/driver")")"
        fi
        printf '%s driver=%s\n' "$cmp" "${drv:-none}"
        [[ "$drv" == "nvidia" ]] && ok=$((ok + 1))
    done

    printf 'nvidia-bound CMP cards: %s/%s\n' "$ok" "$total"
    [[ "$ok" == "$total" ]]
}

verify_compute_unlock() {
    local ver src cmps cmp drv failed=0
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { printf 'no CMP 90HX 10de:220d devices found\n'; return 10; }

    ver="$(modinfo -F version nvidia 2>/dev/null || true)"
    src="$(modinfo -F srcversion nvidia 2>/dev/null || true)"
    printf 'nvidia module version: %s\n' "${ver:-missing}"
    printf 'nvidia module srcversion: %s\n' "${src:-missing}"

    [[ "$ver" == "$DRIVER_VERSION" ]] || return 11
    [[ -n "$src" ]] || return 12

    bind_cmps_to_nvidia || return 13

    for cmp in "${cmps[@]}"; do
        drv="none"
        [[ -L "/sys/bus/pci/devices/$cmp/driver" ]] && drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$cmp/driver")")"
        if [[ "$drv" != "nvidia" ]]; then
            printf '%s not bound to nvidia driver\n' "$cmp"
            failed=1
        fi
    done
    [[ "$failed" == "0" ]] || return 14

    if [[ -r /proc/driver/nvidia/version ]]; then
        cat /proc/driver/nvidia/version
    fi
    printf 'compute driver layer present\n'
}

find_rejoin_verifier_bin() {
    local p
    for p in \
        "$PREFIX/cmpunlocker-rs" \
        "$PREFIX/bin/cmpunlocker-rs" \
        "$PROJECT_DIR/cmpunlocker-rs" \
        "/usr/local/bin/cmpunlocker-rs" \
        "/usr/bin/cmpunlocker-rs"; do
        [[ -x "$p" ]] && { printf '%s
' "$p"; return 0; }
    done

    find \
        "$PREFIX" \
        "$PROJECT_DIR" \
        /usr/local/src/cmp90hx-pwner \
        /var/tmp \
        /tmp \
        -maxdepth 8 -type f -name cmpunlocker-rs -perm -111 2>/dev/null | head -1
}

find_rejoin_check_sh() {
    local p
    for p in \
        "$PREFIX/check.sh" \
        "$PROJECT_DIR/check.sh" \
        "/usr/local/src/cmp90hx-pwner/cmp90hx/check.sh"; do
        [[ -f "$p" ]] && { printf '%s
' "$p"; return 0; }
    done

    find \
        "$PREFIX" \
        "$PROJECT_DIR" \
        /usr/local/src/cmp90hx-pwner \
        /var/tmp \
        /tmp \
        -maxdepth 8 -type f -name check.sh -path '*cmp*' 2>/dev/null | head -1
}

verify_rejoin_compute_full() {
    local bin check rc

    bind_cmps_to_nvidia || return 21

    bin="$(find_rejoin_verifier_bin || true)"
    if [[ -n "$bin" && -x "$bin" ]]; then
        printf 'rejoin verifier: %s
' "$bin"
        "$bin" compute90hx-v67 verify --all-cmp90hx --expect full
        return $?
    fi

    check="$(find_rejoin_check_sh || true)"
    if [[ -n "$check" && -f "$check" ]]; then
        printf 'rejoin check.sh: %s
' "$check"
        chmod +x "$check" 2>/dev/null || true
        ( cd "$(dirname "$check")" && bash "./$(basename "$check")" )
        rc=$?
        return "$rc"
    fi

    printf 'no rejoin built-in verifier found
'
    printf 'expected one of:
'
    printf '  cmpunlocker-rs compute90hx-v67 verify --all-cmp90hx --expect full
'
    printf '  check.sh from cmp90hx/cmpunlocker tree
'
    return 20
}

verify_full() {
    verify_compute_unlock
    verify_rejoin_compute_full
    verify_links
}

prompt_reboot_now() {
    ui '\n%s\n' 'Install finished. Reboot is required to test boot gate.'
    ui '%b[ OK ]%b Reboot now? [y/N]: ' "$GREEN$BOLD" "$RST"
    local answer=''
    if [[ -t 0 ]]; then read -r answer; fi
    case "$answer" in
        y|Y|yes|YES) sync; systemctl reboot; sleep 60 ;;
        *) warn 'reboot skipped; run sudo reboot manually before production validation' ;;
    esac
}

clean_install_unlock() {
    STEP_NO=0
    TOTAL_STEPS=12
    clear_left
    banner
    run_step 'backup' backup_state
    run_step 'stop GPU users' stop_gpu_users
    run_step 'remove previous pwner install' purge_old_pwner
    run_step 'remove previous NVIDIA driver' nvidia_uninstall_best_effort
    run_step 'install dependencies' apt_install_base
    run_step 'block nouveau' blacklist_nouveau
    run_step 'install stock NVIDIA driver' install_stock_driver
    run_step 'install patched driver' install_patched_driver
    run_step 'preserve rejoin verifier' preserve_rejoin_verifiers
    run_step 'write boot service and login notice' write_runtime_all
    run_step 'apply Gen2 now' apply_now
    run_step 'verify compute and Gen2' verify_full
    ok 'UNLOCK COMPLETE'
    prompt_reboot_now
}

uninstall_all() {
    STEP_NO=0
    TOTAL_STEPS=8
    clear_left
    banner
    warn 'UNINSTALL removes runtime, boot hook, login notice, patched driver and NVIDIA driver files.'
    warn 'A reboot is required; current PCIe link can remain Gen2 until the next boot.'
    run_step 'stop services' stop_gpu_users || true
    run_step 'remove pwner runtime' purge_old_pwner || true
    run_step 'remove NVIDIA driver' nvidia_uninstall_best_effort || true
    run_step 'remove nouveau blacklist' remove_bootloader_nouveau_blacklist || true
    run_step 'sanitize depmod' sanitize_depmod || true
    run_step 'restore initramfs' bash -c 'depmod -a; command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true' || true
    run_step 'reload systemd' systemctl daemon-reload || true
    run_step 'sync' sync || true
    ok 'UNINSTALL COMPLETE'
    ui '\nAfter reboot the volatile Gen2 state should be gone.\n'
    ui '%b[ OK ]%b Reboot now? [y/N]: ' "$GREEN$BOLD" "$RST"
    local answer=''
    if [[ -t 0 ]]; then read -r answer; fi
    case "$answer" in
        y|Y|yes|YES) sync; systemctl reboot; sleep 60 ;;
        *) warn 'reboot skipped; card can stay Gen2 until reboot' ;;
    esac
}

show_verify() {
    STEP_NO=0
    TOTAL_STEPS=3
    local failed=0
    clear_left
    banner
    if run_step 'compute unlock' verify_compute_unlock; then :; else failed=1; fi
    if run_step 'rejoin compute full' verify_rejoin_compute_full; then :; else failed=1; fi
    if run_step 'Gen2 link' verify_links; then :; else failed=1; fi
    if [[ "$failed" == "0" ]]; then
        ok 'VERIFY COMPLETE'
    else
        warn 'VERIFY FAILED; details are in the right log pane. Program is still alive.'
    fi
    ui '\nPress Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}

show_install_cuda() {
    STEP_NO=0
    TOTAL_STEPS=1
    clear_left
    banner
    run_step 'install CUDA toolkit' install_cuda_toolkit
    ok 'CUDA TOOLKIT INSTALLED'
    ui '\nPress Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}

usage() {
    cat <<EOF_USAGE
$PROGRAM_NAME
$REPO_URL

Usage:
  sudo ./rejoin17.sh
  sudo ./rejoin17.sh --unlock-this-shit
  sudo ./rejoin17.sh --verify
  sudo ./rejoin17.sh --install-cuda
  sudo ./rejoin17.sh --uninstall
  sudo ./rejoin17.sh --no-tui --verify

Environment:
  AUTO_REBOOT_IF_NOUVEAU=1
  CMP90HX_NO_TUI=1
  CMP90HX_BOOT_MAX_WAIT=420
  CMP90HX_BOOT_INTERVAL=20
EOF_USAGE
}

main() {
    case "${1:-}" in
        --unlock-this-shit|--unlock) clean_install_unlock ;;
        --verify|--status) show_verify ;;
        --install-cuda|--cuda) show_install_cuda ;;
        --uninstall|--rollback|--remove|--cancel) uninstall_all ;;
        --help|-h) usage ;;
        '')
            while true; do
                menu
                IFS= read -r choice
                case "$choice" in
                    1) clean_install_unlock ;;
                    2) show_verify ;;
                    3) show_install_cuda ;;
                    4)
                        ui 'Type UNINSTALL to remove everything: '
                        IFS= read -r confirm
                        [[ "$confirm" == "UNINSTALL" ]] && uninstall_all || warn 'cancelled'
                        ;;
                    0) exit 0 ;;
                    *) warn 'unknown option'; sleep 1 ;;
                esac
            done
            ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
