#!/usr/bin/env bash
# CMP90HX Pwner lab runner: staged aggressive mask open, then final soft convergence.
# This bypasses the installed cmp90hx-gen2-minimal.sh retry policy and drives
# rejoin16-cycle.sh / maskread.py directly.

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"
HANDOFF="${CMP90_HANDOFF:-$PREFIX/cmp90hx-gen2-handoff.sh}"

MASK_FEAT_ECC=0x00823800
MASK_XVE=0x00088fe8
MAX_WAIT="${CMP90HX_TOTAL_TIMEOUT:-1800}"
SOFT_ROUNDS="${CMP90HX_SOFT_ROUNDS:-8}"

log() { printf '[cmp90hx-staged] %s\n' "$*"; }

need_exec() {
    [[ -x "$1" ]] || { log "missing executable: $1"; exit 10; }
}

find_cmps() {
    for d in /sys/bus/pci/devices/*; do
        [[ -f "$d/vendor" && -f "$d/device" ]] || continue
        [[ "$(cat "$d/vendor")" == "0x10de" && "$(cat "$d/device")" == "0x220d" ]] && basename "$d"
    done | sort
}

upstream_of() {
    basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$1")")"
}

elapsed() {
    echo $(( $(date +%s) - START ))
}

check_timeout() {
    local e
    e="$(elapsed)"
    if (( e >= MAX_WAIT )); then
        log "FAIL: timeout ${e}s/${MAX_WAIT}s"
        exit 1
    fi
}

mask_val() {  # <bdf> <addr> -> value
    python3 "$READER" "$1" "$2" 2>/dev/null | awk '{print $1}'
}

write_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2"
    CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true
}

check_mask_after_write() { # <bdf> <addr> <label>
    local bdf="$1" addr="$2" label="$3" cur

    write_mask "$bdf" "$addr"

    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr $label readback immediate=${cur:-none}"
    [[ "$cur" == "0xffffffff" ]] && { log "$bdf $addr OK at $label immediate"; return 0; }

    sleep 0.25
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr $label readback 250ms=${cur:-none}"
    [[ "$cur" == "0xffffffff" ]] && { log "$bdf $addr OK at $label 250ms"; return 0; }

    sleep 1
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr $label readback 1s=${cur:-none}"
    [[ "$cur" == "0xffffffff" ]] && { log "$bdf $addr OK at $label 1s"; return 0; }

    return 1
}

retrain_gen2() { # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "$bdf retrain target Gen2 via endpoint=$bdf upstream=$up"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
}

speed_pulse() { # <bdf>
    local bdf="$1" up lc nc
    up="$(upstream_of "$bdf")"
    log "$bdf speed-pulse Gen1 -> Gen2 via endpoint=$bdf upstream=$up"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0001 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0001 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 3
}

nvidia_settle() { # <bdf>
    local bdf="$1"
    log "$bdf nvidia-smi settle"
    nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current --format=csv,noheader,nounits >/dev/null 2>&1 || true
    sleep 3
}

handoff_refresh() { # <bdf>
    local bdf="$1"
    log "$bdf handoff refresh"
    bash "$HANDOFF" || true
    sleep 4
}

pci_reset() { # <bdf>
    local bdf="$1" dev="/sys/bus/pci/devices/$1"
    if [[ -w "$dev/reset" ]]; then
        log "$bdf PCI function reset"
        echo 1 > "$dev/reset" 2>/dev/null || true
        sleep 8
    else
        log "$bdf PCI function reset unavailable"
    fi
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
    local cmps cmp up speed width endpoint upstream total=0 okc=0 bad=()
    mapfile -t cmps < <(find_cmps)
    (( ${#cmps[@]} > 0 )) || { log "no CMP 90HX 10de:220d devices found"; return 2; }

    for cmp in "${cmps[@]}"; do
        total=$((total + 1))
        up="$(upstream_of "$cmp")"
        speed="$(cat "/sys/bus/pci/devices/${cmp}/current_link_speed" 2>/dev/null || true)"
        width="$(cat "/sys/bus/pci/devices/${cmp}/current_link_width" 2>/dev/null || true)"
        endpoint="$(lspci -Dvv -s "$cmp" | grep "LnkSta:" | head -1 || true)"
        upstream="$(lspci -Dvv -s "$up" | grep "LnkSta:" | head -1 || true)"
        log "$cmp upstream=$up speed=$speed width=$width"
        log "  endpoint $endpoint"
        log "  upstream $upstream"
        if card_is_gen2 "$cmp"; then
            okc=$((okc + 1))
        else
            bad+=("$cmp")
        fi
    done

    log "GEN2 $okc/$total"
    (( ${#bad[@]} == 0 )) || log "not Gen2 yet: ${bad[*]}"
    [[ "$okc" == "$total" ]]
}

aggressive_open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" cur
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr aggressive start readback=${cur:-none}"
    [[ "$cur" == "0xffffffff" ]] && { log "$bdf $addr already open"; return 0; }

    # Deliberately short escalation ladder. No long 60-try loop here.
    check_timeout
    check_mask_after_write "$bdf" "$addr" "stage1-direct-write" && return 0

    check_timeout
    nvidia_settle "$bdf"
    check_mask_after_write "$bdf" "$addr" "stage2-nvidia-settle" && return 0

    check_timeout
    speed_pulse "$bdf"
    check_mask_after_write "$bdf" "$addr" "stage3-speed-pulse" && return 0

    check_timeout
    handoff_refresh "$bdf"
    sleep 5
    check_mask_after_write "$bdf" "$addr" "stage4-handoff-refresh" && return 0

    check_timeout
    pci_reset "$bdf"
    handoff_refresh "$bdf"
    check_mask_after_write "$bdf" "$addr" "stage5-pci-reset-handoff" && return 0

    check_timeout
    nvidia_settle "$bdf"
    speed_pulse "$bdf"
    check_mask_after_write "$bdf" "$addr" "stage6-settle-speed-pulse" && return 0

    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr FAIL after aggressive stages readback=${cur:-none}"
    return 1
}

soft_open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" cur
    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr soft start readback=${cur:-none}"
    [[ "$cur" == "0xffffffff" ]] && { log "$bdf $addr soft already open"; return 0; }

    check_mask_after_write "$bdf" "$addr" "soft-direct" && return 0
    nvidia_settle "$bdf"
    check_mask_after_write "$bdf" "$addr" "soft-nvidia-settle" && return 0
    speed_pulse "$bdf"
    check_mask_after_write "$bdf" "$addr" "soft-speed-pulse" && return 0

    cur="$(mask_val "$bdf" "$addr")"
    log "$bdf $addr soft FAIL readback=${cur:-none}"
    return 1
}

aggressive_pass_all() {
    local cmps bdf m_feat m_xve
    mapfile -t cmps < <(find_cmps)
    log "=== AGGRESSIVE STAGED PASS: handoff once, then staged escalation per card/mask ==="
    bash "$HANDOFF"
    sleep 3

    for bdf in "${cmps[@]}"; do
        check_timeout
        m_feat="$(mask_val "$bdf" "$MASK_FEAT_ECC")"
        m_xve="$(mask_val "$bdf" "$MASK_XVE")"
        log "$bdf masks before aggressive: feat_ecc=$m_feat xve=$m_xve"

        [[ "$m_feat" == "0xffffffff" ]] || aggressive_open_mask "$bdf" "$MASK_FEAT_ECC" || true
        [[ "$m_xve"  == "0xffffffff" ]] || aggressive_open_mask "$bdf" "$MASK_XVE" || true

        retrain_gen2 "$bdf"
        log "$bdf aggressive link=$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || echo '?')"
    done
}

soft_pass_all() { # <round>
    local round="$1" cmps bdf m_feat m_xve
    mapfile -t cmps < <(find_cmps)
    log "=== FINAL SOFT PASS round $round: no PCI reset, no handoff refresh ==="

    for bdf in "${cmps[@]}"; do
        check_timeout
        m_feat="$(mask_val "$bdf" "$MASK_FEAT_ECC")"
        m_xve="$(mask_val "$bdf" "$MASK_XVE")"
        log "$bdf masks before soft: feat_ecc=$m_feat xve=$m_xve"

        [[ "$m_feat" == "0xffffffff" ]] || soft_open_mask "$bdf" "$MASK_FEAT_ECC" || true
        [[ "$m_xve"  == "0xffffffff" ]] || soft_open_mask "$bdf" "$MASK_XVE" || true

        retrain_gen2 "$bdf"
        log "$bdf soft link=$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || echo '?')"
    done
}

stop_old_temp_units() {
    local u
    log "stopping old temporary cmp90hx test units"
    for u in $(systemctl list-units --all --no-legend \
        'cmp90hx-aggr-soft-*' \
        'cmp90hx-brutal-soft-*' \
        'cmp90hx-hotfix-*' \
        'cmp90hx-final-soft-*' \
        'cmp90hx-final-pass-*' \
        | awk '{print $1}'); do
        log "stop/reset $u"
        systemctl stop "$u" 2>/dev/null || true
        systemctl reset-failed "$u" 2>/dev/null || true
    done
}

need_exec "$CYCLE"
need_exec "$READER"
need_exec "$HANDOFF"

START="$(date +%s)"
log "start; timeout=${MAX_WAIT}s"

stop_old_temp_units || true
verify_links || true

aggressive_pass_all || true
log "=== VERIFY AFTER AGGRESSIVE STAGED PASS ==="
verify_links || true

for round in $(seq 1 "$SOFT_ROUNDS"); do
    check_timeout
    soft_pass_all "$round" || true
    log "=== VERIFY AFTER FINAL SOFT round $round ==="
    if verify_links; then
        log "SUCCESS: GEN2 all/all after staged aggressive + final soft"
        exit 0
    fi
    log "soft round $round incomplete; settle 10s"
    sleep 10
done

log "FAIL: final soft convergence exhausted"
verify_links || true
exit 1
