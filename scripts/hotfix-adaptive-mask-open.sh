#!/usr/bin/env bash
# CMP90HX Pwner hotfix: adaptive retry pattern for 0x823800 / 0x088fe8 mask opening.
# This does not change register addresses or the handoff/minimal order.

set -Eeuo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
PROJECT_DIR="${PROJECT_DIR:-/usr/local/src/cmp90hx-pwner/cmp90hx}"
RUN_AFTER_PATCH="${RUN_AFTER_PATCH:-0}"

write_adaptive_minimal() {
    local p="$1"
    [[ -f "$p" ]] || return 0

    cp -a "$p" "${p}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    cat > "$p" <<'EOF_GEN2_MINIMAL'
#!/usr/bin/env bash
# CMP 90HX PCIe Gen2 unlock - adaptive 2-mask apply.
# Register addresses and call order are intentionally unchanged:
#   0x00823800 FEAT_OVR_ECC_PLM
#   0x00088fe8 XVE privilege mask
set -uo pipefail

PREFIX="${CMP90_PREFIX:-/opt/cmp90hx-gen2}"
CYCLE="${CMP90_CYCLE:-$PREFIX/rejoin16-cycle.sh}"
READER="${CMP90_READER:-$PREFIX/maskread.py}"
MASK_FEAT_ECC=0x00823800
MASK_XVE=0x00088fe8
MASK_OPEN_TRIES="${CMP90HX_MASK_OPEN_TRIES:-45}"

log() { echo "cmp90hx-gen2: $*"; }

mask_val() {  # <bdf> <addr> -> value
    python3 "$READER" "$1" "$2" 2>/dev/null | awk '{print $1}'
}

retrain() {   # <bdf>
    local bdf="$1" up lc nc
    up="$(basename "$(readlink -f "/sys/bus/pci/devices/${bdf}/..")")"
    setpci -s "$bdf" CAP_EXP+2c.w=0x0002 2>/dev/null || true
    setpci -s "$up"  CAP_EXP+2c.w=0x0002 2>/dev/null || true
    lc="$(setpci -s "$up" CAP_EXP+10.w 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
        printf -v nc '0x%x' $(( (16#$lc) | 0x20 ))
        setpci -s "$up" CAP_EXP+10.w="$nc" 2>/dev/null || true
    fi
    sleep 2
}

settle_for_try() { # <try>
    local t="$1"
    case $(( (t - 1) % 8 )) in
        0) printf '0' ;;
        1) printf '0.5' ;;
        2) printf '1' ;;
        3) printf '2' ;;
        4) printf '3' ;;
        5) printf '5' ;;
        6) printf '8' ;;
        *) printf '1' ;;
    esac
}

open_mask() { # <bdf> <addr>
    local bdf="$1" addr="$2" try cur delay

    cur="$(mask_val "$bdf" "$addr")"
    [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr already OK"; return 0; }

    for try in $(seq 1 "$MASK_OPEN_TRIES"); do
        # Vary the conditions slightly instead of hammering one identical timing window.
        # The register address and written value are not changed.
        case $(( try % 6 )) in
            3)
                log "  $bdf open $addr try $try: pre-retrain"
                retrain "$bdf"
                ;;
            0)
                log "  $bdf open $addr try $try: longer settle"
                sleep 4
                ;;
        esac

        CMP90_BDF="$bdf" bash "$CYCLE" "$addr" 0xffffffff >/dev/null 2>&1 || true

        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try immediate)"; return 0; }

        sleep 0.25
        cur="$(mask_val "$bdf" "$addr")"
        [[ "$cur" == "0xffffffff" ]] && { log "  $bdf open $addr OK (try $try delayed)"; return 0; }

        delay="$(settle_for_try "$try")"
        log "  $bdf open $addr try $try readback=${cur:-none}; sleep ${delay}s"
        sleep "$delay"
    done

    cur="$(mask_val "$bdf" "$addr")"
    log "  $bdf open $addr FAIL (readback=${cur:-none})"
    return 1
}

mapfile -t BDFS < <(lspci -Dnn | awk '/10de:220d/ {print $1}')
if [[ "${#BDFS[@]}" -eq 0 ]]; then
    log "no CMP 90HX found; nothing to do"
    exit 0
fi

for bdf in "${BDFS[@]}"; do
    m_feat="$(mask_val "$bdf" "$MASK_FEAT_ECC")"
    m_xve="$(mask_val "$bdf" "$MASK_XVE")"
    log "$bdf masks feat_ecc=$m_feat xve=$m_xve"

    if [[ "$m_feat" == "0xffffffff" && "$m_xve" == "0xffffffff" ]]; then
        log "  masks already open - no reload cycles needed"
    else
        [[ "$m_feat" == "0xffffffff" ]] || open_mask "$bdf" "$MASK_FEAT_ECC" || true
        [[ "$m_xve"  == "0xffffffff" ]] || open_mask "$bdf" "$MASK_XVE"      || true
    fi

    retrain "$bdf"
    spd="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null)"
    gen="$(nvidia-smi --query-gpu=pcie.link.gen.current,pci.bus_id --format=csv,noheader,nounits 2>/dev/null \
           | awk -v b="${bdf#0000:}" '$2 ~ b {print $1; exit}')"
    log "  $bdf link=${spd:-?} gen=${gen:-?}"
done
log "done"
exit 0
EOF_GEN2_MINIMAL

    chmod +x "$p"
    echo "patched: $p"
}

write_adaptive_minimal "$PREFIX/cmp90hx-gen2-minimal.sh"
write_adaptive_minimal "$PROJECT_DIR/scripts/cmp90hx-gen2-minimal.sh"

if [[ "$RUN_AFTER_PATCH" == "1" ]]; then
    CMP90HX_MASK_OPEN_TRIES="${CMP90HX_MASK_OPEN_TRIES:-45}" \
    CMP90HX_APPLY_MAX_WAIT="${CMP90HX_APPLY_MAX_WAIT:-2000}" \
    bash "$PREFIX/rejoin17-apply-all.sh"
fi
