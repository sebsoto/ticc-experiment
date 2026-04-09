#!/bin/bash
# Toggle T-GM ptp4l ports via pmc DISABLE_PORT / ENABLE_PORT.
# Usage:
#   ./pmc-port-toggle.sh disable   # disable GM ports (triggers T-BC holdover)
#   ./pmc-port-toggle.sh enable    # re-enable GM ports
#   ./pmc-port-toggle.sh status    # show current port states
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to your cluster kubeconfig path}"
export KUBECONFIG

NAMESPACE="openshift-ptp"
PTP_DOMAIN=24

find_pod() {
    oc get pods -n "$NAMESPACE" -l app=linuxptp-daemon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

pod_exec() {
    oc exec -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container -- "$@"
}

find_gm_socket() {
    local configs
    configs=$(pod_exec ls /var/run/ 2>/dev/null | grep 'ptp4l\..*\.config' || true)
    for cfg in $configs; do
        if pod_exec grep -q 'grandmaster\|t-gm' "/var/run/$cfg" 2>/dev/null; then
            local num
            num=$(echo "$cfg" | sed 's/ptp4l\.\([0-9]*\)\.config/\1/')
            echo "/var/run/ptp4l.${num}.socket"
            return
        fi
    done
    echo ""
}

pmc_cmd() {
    pod_exec pmc -u -b 0 -d "$PTP_DOMAIN" -s "$GM_SOCKET" "$@"
}

ACTION="${1:-status}"
POD=$(find_pod)
[ -n "$POD" ] || { echo "ERROR: no linuxptp-daemon pod found"; exit 1; }

GM_SOCKET=$(find_gm_socket)
[ -n "$GM_SOCKET" ] || { echo "ERROR: could not find T-GM ptp4l socket"; exit 1; }
echo "Pod: $POD"
echo "GM socket: $GM_SOCKET"

case "$ACTION" in
    disable)
        echo "Disabling T-GM ptp4l ports..."
        pmc_cmd "COMMAND DISABLE_PORT"
        echo "Done. T-BC should enter holdover after announce receipt timeout (~24s)."
        ;;
    enable)
        echo "Enabling T-GM ptp4l ports..."
        pmc_cmd "COMMAND ENABLE_PORT"
        echo "Done. T-BC should re-lock."
        ;;
    status)
        echo "T-GM port state:"
        pmc_cmd "GET PORT_DATA_SET"
        ;;
    *)
        echo "Usage: $0 {disable|enable|status}"
        exit 1
        ;;
esac
