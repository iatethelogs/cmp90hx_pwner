#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CMP90HX Pwner - split compute / manual Gen2 front-end.
# The current known-good installer implementation lives unchanged in
# lib/rejoin17-core.sh. This file only selects the operation flow.

set -Eeuo pipefail

PROGRAM_NAME="CMP90HX Pwner"
WRAPPER_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
WRAPPER_DIR="$(cd "$(dirname "$WRAPPER_SELF")" && pwd)"
CORE="${CMP90HX_CORE_PATH:-$WRAPPER_DIR/lib/rejoin17-core.sh}"
CORE_TMP=""
LOG_DIR="${LOG_DIR:-/var/log}"
LOG="${LOG:-${LOG_DIR}/cmp90hx-pwner-$(date +%Y%m%d-%H%M%S).log}"
REQUESTED_NO_TUI=0
[[ "${1:-}" == "--no-tui" ]] && REQUESTED_NO_TUI=1
ORIGINAL_NO_TUI="${CMP90HX_NO_TUI-}"
[[ "$REQUESTED_NO_TUI" == "1" ]] && export CMP90HX_NO_TUI=1

cleanup_wrapper() {
    [[ -z "$CORE_TMP" ]] || rm -f "$CORE_TMP" 2>/dev/null || true
}
trap cleanup_wrapper EXIT

if [[ "$(id -u)" != "0" ]]; then
    exec sudo -E bash "$WRAPPER_SELF" "$@"
fi

# Launch the split terminal before sourcing the legacy core. The core redirects
# stdout/stderr to the log at top level, so launching tmux afterwards would make
# stdout cease to be a TTY and the original launch_tui() would correctly refuse
# to start. Parent: left = UI, right = live detailed log. Child: no nested tmux.
wrapper_launch_tui() {
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
        printf 'exec bash %q' "$WRAPPER_SELF"
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
wrapper_launch_tui "$@"

if [[ ! -r "$CORE" ]]; then
    CORE_TMP="${TMPDIR:-/tmp}/cmp90hx-pwner-core-$$.sh"
    CORE_URL="https://raw.githubusercontent.com/iatethelogs/cmp90hx_pwner/main/lib/rejoin17-core.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$CORE_TMP" "$CORE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --waitretry=2 -O "$CORE_TMP" "$CORE_URL"
    else
        printf 'CMP90HX Pwner: missing %s and neither curl nor wget is available\n' "$CORE" >&2
        exit 127
    fi
    CORE="$CORE_TMP"
fi

# Source the reverted, known-good implementation without executing its old main().
# TUI has already been created by the wrapper, so suppress only the core's own
# launch attempt. In the tmux child the core then opens fd 3 on /dev/tty for the
# left UI and redirects stdout/stderr into LOG for the right live log pane.
export CMP90HX_NO_TUI=1
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$CORE")
if [[ "$REQUESTED_NO_TUI" == "1" || "$ORIGINAL_NO_TUI" == "1" ]]; then
    export CMP90HX_NO_TUI=1
else
    unset CMP90HX_NO_TUI
fi

menu() {
    clear_left
    banner 1
    ui '1) COMPUTE UNLOCK\n'
    ui '2) PCIe GEN2\n'
    ui '3) VERIFY\n'
    ui '4) INSTALL CUDA TOOLKIT\n'
    ui '5) INSTALL 4-BEEP AT START\n'
    ui '6) INSTALL FAN/GPU HELPERS\n'
    ui '7) UNINSTALL\n'
    ui '0) EXIT\n\nSelect: '
}

remove_obsolete_boot_hook() {
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f \
        "/etc/systemd/system/$SERVICE_NAME" \
        "/lib/systemd/system/$SERVICE_NAME" \
        "/usr/lib/systemd/system/$SERVICE_NAME" \
        "/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME" \
        "$BOOT_GATE" \
        "$SSH_PROFILE" \
        /etc/profile.d/cmp90hx-pwner-firstboot.sh \
        /etc/update-motd.d/99-cmp90hx-pwner \
        2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

activate_compute_driver() {
    local handoff="$PREFIX/cmp90hx-gen2-handoff.sh"
    [[ -x "$handoff" ]] || { printf 'missing patched-driver handoff helper: %s\n' "$handoff"; return 20; }
    bash "$handoff"
}

# Exact successful wrapper from cmp90hx-debug-bundle-20260916-002951,
# with only the requested retry defaults changed: soft 13, aggressive 13.
write_apply_script() {
    mkdir -p "$PREFIX"
    cat > "$APPLY_SCRIPT" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
PREFIX="/opt/cmp90hx-gen2"
MAX_WAIT="${CMP90HX_APPLY_MAX_WAIT:-3600}"
INTERVAL="${CMP90HX_APPLY_INTERVAL:-30}"
SOFT_MASK_TRIES="${CMP90HX_SOFT_MASK_OPEN_TRIES:-13}"
AGGR_MASK_TRIES="${CMP90HX_AGGR_MASK_OPEN_TRIES:-13}"

log() { printf '[cmp90hx-pwner] %s\n' "$*"; }

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

upstream_of() {
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

card_is_gen2() {
    local cmp="$1" up speed endpoint upstream
    up="$(upstream_of "$cmp")"
    speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
    endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
    upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
    [[ "$speed" == *"5.0 GT/s"* ]] && [[ "$endpoint" == *"Speed 5GT/s"* ]] && [[ "$upstream" == *"Speed 5GT/s"* ]]
}

failed_cards() {
    local cmps cmp out=()
    mapfile -t cmps < <(find_cmps)
    for cmp in "${cmps[@]}"; do
        card_is_gen2 "$cmp" || out+=("$cmp")
    done
    printf '%s\n' "${out[@]}"
}

verify_links() {
    local cmps cmp up speed width endpoint upstream total=0 okc=0 failed=()
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { log "no CMP 90HX 10de:220d devices found"; return 2; }

    for cmp in "${cmps[@]}"; do
        total=$((total+1))
        up="$(upstream_of "$cmp")"
        speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/${cmp}/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
        log "$cmp upstream=$up speed=$speed width=$width"
        log "  endpoint $endpoint"
        log "  upstream $upstream"
        if card_is_gen2 "$cmp"; then
            okc=$((okc+1))
        else
            failed+=("$cmp")
        fi
    done

    log "GEN2 $okc/$total"
    if (( ${#failed[@]} > 0 )); then
        log "not Gen2 yet: ${failed[*]}"
    fi
    [[ "$okc" == "$total" ]]
}

handoff() {
    [[ -x "$PREFIX/cmp90hx-gen2-handoff.sh" ]] || { log "missing handoff script"; exit 11; }
    log "handoff"
    bash "$PREFIX/cmp90hx-gen2-handoff.sh"
}

run_minimal() { # <label> <pci_reset> <tries>
    local label="$1" pci_reset="$2" tries="${3:-$SOFT_MASK_TRIES}"
    [[ -x "$PREFIX/cmp90hx-gen2-minimal.sh" ]] || { log "missing minimal script"; exit 12; }
    log "Gen2 runtime: ${label} pci_reset=${pci_reset} tries=${tries}"
    CMP90HX_PCI_RESET="$pci_reset" \
    CMP90HX_MASK_OPEN_TRIES="$tries" \
    bash "$PREFIX/cmp90hx-gen2-minimal.sh"
    sleep 5
}

soft_pass() { # <label>
    local label="$1"
    log "=== ${label}: handoff -> adaptive minimal -> verify ==="
    handoff
    run_minimal "$label" 0 "$SOFT_MASK_TRIES" || true
    verify_links
}

rescue_pass() {
    log "=== rescue: handoff -> adaptive minimal with targeted PCI reset -> verify ==="
    handoff
    CMP90HX_PCI_RESET=1 CMP90HX_MASK_OPEN_TRIES="$AGGR_MASK_TRIES" bash "$PREFIX/cmp90hx-gen2-minimal.sh" || true
    sleep 5
    verify_links
}

[[ "${1:-}" == "--verify-only" ]] && { verify_links; exit $?; }

if verify_links; then
    log "already Gen2"
    exit 0
fi

start="$(date +%s)"
cycle=1

while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    log "convergence cycle ${cycle}, elapsed ${elapsed}s/${MAX_WAIT}s"

    if soft_pass "adaptive pass ${cycle}"; then
        log "Gen2 verified after adaptive pass ${cycle}"
        exit 0
    fi

    mapfile -t failed < <(failed_cards)
    log "adaptive pass ${cycle} left non-Gen2 cards: ${failed[*]:-none}"

    if rescue_pass; then
        log "rescue pass reached Gen2; running mandatory final soft pass"
    else
        log "rescue pass did not leave all cards Gen2; running mandatory final soft pass anyway"
    fi

    if soft_pass "final soft pass ${cycle}"; then
        log "Gen2 verified after rescue + final soft pass ${cycle}"
        exit 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= MAX_WAIT )); then
        log "FAIL: Gen2 was not verified inside ${MAX_WAIT}s"
        exit 1
    fi

    mapfile -t failed < <(failed_cards)
    log "cycle ${cycle} incomplete; still not Gen2: ${failed[*]:-unknown}; retry in ${INTERVAL}s"
    sleep "$INTERVAL"
    cycle=$((cycle + 1))
done
EOF_APPLY
    chmod +x "$APPLY_SCRIPT"
}

clean_install_unlock() {
    STEP_NO=0
    TOTAL_STEPS=13
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
    run_step 'remove obsolete boot hook' remove_obsolete_boot_hook
    run_step 'activate patched compute driver' activate_compute_driver
    run_step 'preserve compute verifier' preserve_rejoin_verifiers
    run_step 'verify compute driver' verify_compute_unlock
    run_step 'verify compute unlock' verify_rejoin_compute_full
    ok 'COMPUTE UNLOCK COMPLETE'
}

show_apply_gen2() {
    STEP_NO=0
    TOTAL_STEPS=4
    clear_left
    banner
    [[ -x "$PREFIX/cmp90hx-gen2-handoff.sh" ]] || { fail 'COMPUTE UNLOCK must be installed first'; ui '\nPress Enter to return: '; [[ -t 0 ]] && read -r _ || true; return 1; }
    run_step 'disable Gen2 autostart' remove_obsolete_boot_hook
    run_step 'restore proven Gen2 minimal' write_adaptive_gen2_minimal
    run_step 'write proven Gen2 runner' write_apply_script
    run_step 'apply PCIe Gen2 now' apply_now
    ok 'PCIe GEN2 COMPLETE'
    ui '\nGen2 is manual. Run this item again after every reboot.\n'
    ui 'Press Enter to return: '
    [[ -t 0 ]] && read -r _ || true
}

uninstall_split() {
    remove_obsolete_boot_hook || true
    uninstall_all
}

usage() {
    cat <<EOF_USAGE
$PROGRAM_NAME
$REPO_URL

Usage:
  sudo ./rejoin17.sh
  sudo ./rejoin17.sh --compute-unlock
  sudo ./rejoin17.sh --gen2
  sudo ./rejoin17.sh --verify
  sudo ./rejoin17.sh --install-cuda
  sudo ./rejoin17.sh --install-beep
  sudo ./rejoin17.sh --install-helpers
  sudo ./rejoin17.sh --uninstall
  sudo ./rejoin17.sh --no-tui --verify

Gen2 is never enabled at boot by this front-end. Run --gen2 manually after every reboot.

Gen2 retry defaults:
  CMP90HX_SOFT_MASK_OPEN_TRIES=13
  CMP90HX_AGGR_MASK_OPEN_TRIES=13
  CMP90HX_APPLY_MAX_WAIT=3600
  CMP90HX_APPLY_INTERVAL=30
EOF_USAGE
}

main() {
    case "${1:-}" in
        --compute-unlock|--compute) clean_install_unlock ;;
        --gen2|--apply-gen2) show_apply_gen2 ;;
        --verify|--status) show_verify ;;
        --install-cuda|--cuda) show_install_cuda ;;
        --install-beep|--beep) show_install_boot_beep ;;
        --install-helpers|--helpers|--fan-scripts|--gpu-scripts) show_install_helpers ;;
        --uninstall|--rollback|--remove|--cancel) uninstall_split ;;
        --unlock-this-shit|--unlock)
            fail 'combined compute+Gen2 mode was removed; choose COMPUTE UNLOCK or PCIe GEN2'
            exit 2
            ;;
        --help|-h) usage ;;
        '')
            while true; do
                menu
                IFS= read -r choice
                case "$choice" in
                    1) clean_install_unlock ;;
                    2) show_apply_gen2 ;;
                    3) show_verify ;;
                    4) show_install_cuda ;;
                    5) show_install_boot_beep ;;
                    6) show_install_helpers ;;
                    7)
                        ui 'Type UNINSTALL to remove everything: '
                        IFS= read -r confirm
                        [[ "$confirm" == "UNINSTALL" ]] && uninstall_split || warn 'cancelled'
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
