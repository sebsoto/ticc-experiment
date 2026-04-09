#!/bin/bash
# Toggle T-BC GNSS pin priority on EEC and PPS DPLLs.
# Usage:
#   ./gnss-toggle.sh disable   # set GNSS prio=255 (T-BC uses SyncE/PTP instead)
#   ./gnss-toggle.sh enable    # set GNSS prio=0 (T-BC can lock to local GNSS)
#   ./gnss-toggle.sh status    # show current GNSS pin priority and DPLL sources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to your cluster kubeconfig path}"
export KUBECONFIG

NAMESPACE="openshift-ptp"
# T-BC DPLL device IDs: EEC=2, PPS=3
TBC_EEC_ID=2
TBC_PPS_ID=3

find_pod() {
    oc get pods -n "$NAMESPACE" -l app=linuxptp-daemon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

pod_exec() {
    oc exec -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container -- "$@"
}

get_dpll_pin_show() {
    pod_exec dpll pin show 2>/dev/null || true
}

# Find GNSS-1PPS pin ID for a given DPLL parent device
find_gnss_pin_id() {
    local parent_id="$1"
    echo "$PIN_SHOW" | awk -v pid="$parent_id" '
        /^pin id [0-9]+:/{gsub(/:/, ""); current_pin=$3}
        /board-label: GNSS-1PPS/{found=1}
        found && $0 ~ "id "pid" direction"{print current_pin; exit}
        /^pin/{found=0}
    '
}

# Set GNSS pin priority on a DPLL parent
set_gnss_prio() {
    local prio="$1"
    local parent_id="$2"
    local pin_id
    pin_id=$(find_gnss_pin_id "$parent_id")
    if [ -z "$pin_id" ]; then
        echo "ERROR: could not find GNSS-1PPS pin for DPLL parent $parent_id"
        return 1
    fi
    echo "  Setting GNSS pin $pin_id prio=$prio on DPLL parent $parent_id"
    pod_exec dpll pin set id "$pin_id" parent-device "$parent_id" prio "$prio"
}

# Check what source a DPLL device is locked to
check_dpll_source() {
    local dev_id="$1"
    echo "$PIN_SHOW" | awk -v did="$dev_id" '
        /^pin id [0-9]+:/{current_pin=""}
        /board-label:/{current_pin=$2}
        $0 ~ "id "did" direction input.*state connected"{print current_pin}
    ' | head -1
}

# Check GNSS pin priority for a given DPLL parent
check_gnss_prio() {
    local parent_id="$1"
    echo "$PIN_SHOW" | awk -v pid="$parent_id" '
        /board-label: GNSS-1PPS/{found=1}
        found && $0 ~ "id "pid" direction"{
            for(i=1;i<=NF;i++) if($i=="prio") print $(i+1)
            found=0
        }
        /^pin/{found=0}
    '
}

# Check EEC DPLL lock status
check_eec_lock_status() {
    local dev_id="$1"
    pod_exec dpll device show 2>/dev/null | awk -v did="$dev_id" '
        $0 ~ "^device id "did":"{found=1}
        found && /lock-status:/{print $2; exit}
    '
}

ACTION="${1:-status}"
POD=$(find_pod)
[ -n "$POD" ] || { echo "ERROR: no linuxptp-daemon pod found"; exit 1; }
echo "Pod: $POD"

PIN_SHOW=$(get_dpll_pin_show)

echo "# C827_0-RCLKA — locked via SyncE recovered clock (traces to T-GM)"
echo "# CVL-SDP22 — locked via PTP-derived PPS (traces to T-GM through ts2phc)"
echo "# GNSS-1PPS — locked to local GNSS"


case "$ACTION" in
    disable)
        echo "Disabling T-BC GNSS (prio=255 on EEC and PPS DPLLs)..."
        set_gnss_prio 255 "$TBC_EEC_ID"
        set_gnss_prio 255 "$TBC_PPS_ID"
        echo "Done. T-BC will lock to SyncE/PTP instead of local GNSS."
        ;;
    enable)
        echo "Enabling T-BC GNSS (prio=0 on EEC and PPS DPLLs)..."
        set_gnss_prio 0 "$TBC_EEC_ID"
        set_gnss_prio 0 "$TBC_PPS_ID"
        echo "Done. T-BC can lock to local GNSS."
        ;;
    status)
        echo "T-BC DPLL status:"
        echo "  EEC (dev $TBC_EEC_ID): lock=$(check_eec_lock_status $TBC_EEC_ID) source=$(check_dpll_source $TBC_EEC_ID)"
        echo "  PPS (dev $TBC_PPS_ID): lock=$(check_eec_lock_status $TBC_PPS_ID) source=$(check_dpll_source $TBC_PPS_ID)"
        echo "  GNSS prio on EEC: $(check_gnss_prio $TBC_EEC_ID)"
        echo "  GNSS prio on PPS: $(check_gnss_prio $TBC_PPS_ID)"
        ;;
    *)
        echo "Usage: $0 {disable|enable|status}"
        exit 1
        ;;
esac
