#!/bin/bash
# SyncE Holdover Experiment — automated runner
#
# Runs two holdover test cases using TICC time interval counter:
#   Case 1: Holdover WITH SyncE (oscillator syntonized to GM)
#   Case 2: Holdover WITHOUT SyncE (oscillator free-running)
#
# Prerequisites:
#   - Patched ptp4l with DISABLE_PORT support deployed
#   - T-GM and T-BC configs applied, both locked (s2)
#   - TICC connected at /dev/ttyACM0, firmware 20251215.1, TI mode
#   - ticc-logger binary installed at ~/ticc-logger on $TICC_HOST
#   - SSH key access to $TICC_HOST
#   - Environment: KUBECONFIG, TICC_HOST (e.g. user@host)
#
# Usage:
#   ./holdover-experiment.sh [OPTIONS]
#
# Options:
#   -b SECONDS    Baseline (locked) duration before holdover (default: 3600)
#   -h SECONDS    Holdover duration (default: 14400 = 4 hours)
#   -c CASE       Run only case 1 or 2 (default: both)
#   -o DIR        Output directory for log files (default: ./results)
#   -s            Skip pre-flight checks
#   -n            Dry run — print what would be done without executing

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to your cluster kubeconfig path}"
export KUBECONFIG

NAMESPACE="openshift-ptp"
PTP_DOMAIN=24
TICC_HOST="${TICC_HOST:?Set TICC_HOST (e.g. user@host)}"
TICC_LOGGER="~/ticc-logger"

# Config files (in ptp-discovery/configs under the ptp repo root)
CONFIG_DIR="$REPO_ROOT/ptp-discovery/configs"
GM_CONFIG="$CONFIG_DIR/t-gm.yaml"
BC_CONFIG="$CONFIG_DIR/t-bc.yaml"
GM_CONFIG_BACKUP="$GM_CONFIG.with-synce"
BC_CONFIG_BACKUP="$BC_CONFIG.with-synce"

# Defaults
BASELINE_SECS=3600
HOLDOVER_SECS=14400
RUN_CASE=""
OUTPUT_DIR="$SCRIPT_DIR/results"
SKIP_PREFLIGHT=false
DRY_RUN=false

# Status CSV path (set per case in run_case)
STATUS_CSV=""

# ─── Argument parsing ────────────────────────────────────────────────────────

while getopts "b:h:c:o:sn" opt; do
    case $opt in
        b) BASELINE_SECS=$OPTARG ;;
        h) HOLDOVER_SECS=$OPTARG ;;
        c) RUN_CASE=$OPTARG ;;
        o) OUTPUT_DIR=$OPTARG ;;
        s) SKIP_PREFLIGHT=true ;;
        n) DRY_RUN=true ;;
        *) echo "Usage: $0 [-b baseline_secs] [-h holdover_secs] [-c 1|2] [-o outdir] [-s] [-n]"; exit 1 ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "=== $(date -u '+%Y-%m-%d %H:%M:%S UTC') | $* ==="; }
die() { echo "FATAL: $*" >&2; exit 1; }

fmt_duration() {
    local secs=$1
    local h=$((secs / 3600))
    local m=$(( (secs % 3600) / 60 ))
    if [ $h -gt 0 ] && [ $m -gt 0 ]; then echo "${h}h${m}m"
    elif [ $h -gt 0 ]; then echo "${h}h"
    else echo "${m}m"
    fi
}

run() {
    if $DRY_RUN; then
        echo "[DRY RUN] $*"
    else
        "$@"
    fi
}

# Find the linuxptp daemon pod
find_pod() {
    oc get pods -n "$NAMESPACE" -l app=linuxptp-daemon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Execute a command inside the daemon pod
pod_exec() {
    oc exec -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container -- "$@"
}

# Find the GM ptp4l socket by looking for the grandmaster profile config
find_gm_socket() {
    local configs
    configs=$(pod_exec ls /var/run/ 2>/dev/null | grep 'ptp4l\..*\.config' || true)
    for cfg in $configs; do
        if pod_exec grep -q 'grandmaster\|t-gm' "/var/run/$cfg" 2>/dev/null; then
            local num
            num=$(echo "$cfg" | sed 's/ptp4l\.\([0-9]*\)\.config/\1/')
            echo "/var/run/ptp4l.${num}.socket"
            return 0
        fi
    done
    die "Could not find GM ptp4l socket. Is the GM profile applied?"
}

# Send pmc command to GM
pmc_cmd() {
    pod_exec pmc -u -b 0 -d "$PTP_DOMAIN" -s "$GM_SOCKET" "$@"
}

# Start ticc-logger on the remote host with a duration.
# The logger stops itself after the specified time.
# Runs fully detached on the remote host via nohup so it survives SSH drops.
ticc_start() {
    local remote_csv="$1"
    local duration_secs="$2"
    log "Starting ticc-logger on $TICC_HOST → $remote_csv (${duration_secs}s)"
    if $DRY_RUN; then
        echo "[DRY RUN] ssh $TICC_HOST sudo nohup $TICC_LOGGER -o $remote_csv -d ${duration_secs}s"
        return
    fi
    ssh "$TICC_HOST" "sudo nohup $TICC_LOGGER -o $remote_csv -d ${duration_secs}s > /tmp/ticc-logger.log 2>&1 &"
    sleep 3
    if ! ssh "$TICC_HOST" "pgrep -f ticc-logger" &>/dev/null; then
        die "ticc-logger failed to start on $TICC_HOST"
    fi
    log "ticc-logger running on $TICC_HOST (detached)"
}

# Wait for ticc-logger to finish (it stops itself after its duration)
ticc_wait() {
    if $DRY_RUN; then return; fi
    log "Waiting for ticc-logger to finish"
    while ssh "$TICC_HOST" "pgrep -f ticc-logger" &>/dev/null; do
        sleep 30
    done
    log "ticc-logger finished"
}

# Copy CSV from remote host to local output dir
ticc_copy() {
    local remote_file="$1"
    local local_file="$2"
    log "Copying $remote_file → $local_file"
    if ! run scp "$TICC_HOST:$remote_file" "$local_file"; then
        log "WARNING: scp failed. Data is still on $TICC_HOST:$remote_file"
        return 0
    fi
    if [ -f "$local_file" ]; then
        local lines
        lines=$(wc -l < "$local_file")
        log "Copied $lines lines"
    fi
}

# Wait with countdown, showing progress every 5 minutes
wait_period() {
    local total=$1
    local label=$2
    local expected_ql="${3:-}"  # optional: expected SyncE QL (e.g. "0x1"), empty to skip
    local interval=120  # progress update every 2 min

    if $DRY_RUN; then
        echo "[DRY RUN] Would wait $total seconds ($label)"
        return
    fi

    log "Waiting $(fmt_duration $total) for $label"
    local elapsed=0
    while [ $elapsed -lt $total ]; do
        local remaining=$((total - elapsed))
        local chunk=$interval
        [ $chunk -gt $remaining ] && chunk=$remaining
        sleep $chunk
        elapsed=$((elapsed + chunk))
        if [ $elapsed -lt $total ]; then
            # Check ticc-logger is still alive (only if it was started)
            if ssh "$TICC_HOST" "test -f /tmp/ticc-logger.log" &>/dev/null && \
               ! ssh "$TICC_HOST" "pgrep -f ticc-logger" &>/dev/null; then
                log "WARNING: ticc-logger died on $TICC_HOST. TICC data collection has stopped."
            fi
            local status_info=""
            local tgm_eec tgm_pps_src tbc_eec tbc_pps tbc_ptp tbc_eec_src tbc_pps_src ql=""
            tgm_eec=$(check_eec_lock_status 0 || true)
            tgm_pps_src=$(check_dpll_source 1 || true)
            tbc_eec=$(check_eec_lock_status 2 || true)
            tbc_pps=$(check_eec_lock_status 3 || true)
            tbc_ptp=$(check_tbc_ptp_state || true)
            tbc_eec_src=$(check_dpll_source 2 || true)
            tbc_pps_src=$(check_dpll_source 3 || true)
            status_info=" | T-GM-EEC=${tgm_eec:-?} T-GM-PPS-SRC=${tgm_pps_src:-none} T-BC-EEC=${tbc_eec:-?}(${tbc_eec_src:-none}) T-BC-PPS=${tbc_pps:-?}(${tbc_pps_src:-none}) T-BC-PTP=${tbc_ptp:-?}"
            if [ "${tbc_eec_src:-}" = "GNSS-1PPS" ] || [ "${tbc_pps_src:-}" = "GNSS-1PPS" ]; then
                status_info="${status_info} WARNING:LOCKED-TO-GNSS"
            fi
            if [ -n "$expected_ql" ]; then
                ql=$(check_tbc_synce_ql || true)
                if [ "$ql" = "$expected_ql" ]; then
                    status_info="${status_info} QL=$ql OK"
                elif [ -z "$ql" ]; then
                    status_info="${status_info} QL=?"
                else
                    status_info="${status_info} QL=$ql UNEXPECTED(expected $expected_ql)"
                fi
            fi
            echo "  ... $(fmt_duration $elapsed) elapsed, $(fmt_duration $((total - elapsed))) remaining ($label)${status_info}"
            # Append to status CSV
            if [ -n "${STATUS_CSV:-}" ] && [ -f "${STATUS_CSV}" ]; then
                echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),${label},${tgm_eec:-},${tgm_pps_src:-},${tbc_eec:-},${tbc_eec_src:-},${tbc_pps:-},${tbc_pps_src:-},${tbc_ptp:-},${ql:-}" >> "$STATUS_CSV"
            fi
        fi
    done
    log "$label complete"
}

# Wait for T-BC DPLLs to reach locked state.
# Checks both the daemon log (T-BC-STATUS s2) and actual DPLL hardware state.
# With GNSS disabled, the daemon may never report s2, so we fall back to DPLL state.
wait_for_lock() {
    local timeout=${1:-600}
    local deadline=$((SECONDS + timeout))

    log "Waiting for T-BC to reach locked state — timeout $(fmt_duration $timeout)"
    if $DRY_RUN; then
        echo "[DRY RUN] Would wait for lock"
        return 0
    fi

    while [ $SECONDS -lt $deadline ]; do
        # Check daemon log first
        local recent
        recent=$(oc logs -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container --tail=50 2>/dev/null || true)
        if grep -q 'T-BC-STATUS s2' <<< "$recent"; then
            log "T-BC is locked (daemon s2)"
            return 0
        fi
        # Fall back to DPLL hardware state
        local eec_state pps_state
        eec_state=$(check_eec_lock_status 2 || true)
        pps_state=$(check_eec_lock_status 3 || true)
        if [[ "${eec_state:-}" == locked* ]] && [[ "${pps_state:-}" == locked* ]]; then
            log "T-BC DPLLs locked (EEC=$eec_state, PPS=$pps_state)"
            return 0
        fi
        sleep 10
    done
    die "T-BC did not reach locked state within $(fmt_duration $timeout)"
}

# Verify holdover detected
verify_holdover() {
    log "Verifying T-BC detected PTP loss"
    if $DRY_RUN; then return 0; fi

    sleep 5
    local found=false
    for i in 1 2 3; do
        local recent
        recent=$(oc logs -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container --tail=30 2>/dev/null || true)
        if grep -q 'Source LOST\|HOLDOVER\|ptpLost.*true\|FREERUN' <<< "$recent"; then
            found=true
            break
        fi
        sleep 5
    done
    if $found; then
        log "T-BC in holdover — confirmed"
    else
        echo "WARNING: Could not confirm holdover state in logs. Proceeding anyway."
    fi
}

# Remove SyncE config from a yaml file (strips synce4lConf and synce4lOpts)
strip_synce() {
    local file="$1"
    python3 -c "
import yaml, sys

with open('$file') as f:
    doc = yaml.safe_load(f)

for profile in doc.get('spec', {}).get('profile', []):
    profile.pop('synce4lConf', None)
    profile.pop('synce4lOpts', None)

with open('$file', 'w') as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False)
"
}

# ─── SyncE status helpers ────────────────────────────────────────────────────

# Check EEC DPLL lock status for a given device id.
# Device IDs: 0=T-GM EEC, 2=T-BC EEC (odd IDs are PPS DPLLs)
check_eec_lock_status() {
    local dev_id="${1:-0}"
    local output
    output=$(pod_exec dpll device show 2>/dev/null || true)
    echo "$output" | awk -v did="$dev_id" '
        $0 ~ "^device id "did":"{found=1}
        found && /lock-status:/{print $2; exit}
    '
}

check_tgm_eec_locked() {
    check_eec_lock_status 0
}

# Check GNSS pin priority on a specific EEC DPLL parent device.
# Usage: check_gnss_prio <dpll_parent_id>
#   dpll_parent_id 0 = T-GM EEC, 2 = T-BC EEC
# Prints the priority value.
check_gnss_prio() {
    local parent_id="${1:-0}"
    local output
    output=$(pod_exec dpll pin show 2>/dev/null || true)
    echo "$output" | awk -v pid="$parent_id" '
        /board-label: GNSS-1PPS/{found=1}
        found && $0 ~ "id "pid" direction"{
            for(i=1;i<=NF;i++) if($i=="prio") print $(i+1)
            found=0
        }
        /^pin/{found=0}
    '
}

# Set GNSS pin priority on one or more DPLL parent devices.
# Usage: set_gnss_prio <priority> <dpll_parent_id> [<dpll_parent_id> ...]
#   T-BC EEC=2, T-BC PPS=3
set_gnss_prio() {
    local prio="$1"; shift
    local output pin_id
    output=$(pod_exec dpll pin show 2>/dev/null || true)
    for parent_id in "$@"; do
        pin_id=$(echo "$output" | awk -v pid="$parent_id" '
            /^pin id [0-9]+:/{gsub(/:/, ""); current_pin=$3}
            /board-label: GNSS-1PPS/{found=1}
            found && $0 ~ "id "pid" direction"{print current_pin; exit}
            /^pin/{found=0}
        ')
        if [ -z "$pin_id" ]; then
            die "Could not find GNSS-1PPS pin for DPLL parent $parent_id"
        fi
        log "Setting GNSS pin $pin_id prio=$prio on DPLL parent $parent_id"
        run pod_exec dpll pin set id "$pin_id" parent-device "$parent_id" prio "$prio"
    done
}

# Check what source a DPLL device is locked to.
# Usage: check_dpll_source <device_id>
# Prints the board-label of the pin in "connected" state, or empty if none.
check_dpll_source() {
    local dev_id="${1:-2}"
    local output
    output=$(pod_exec dpll pin show 2>/dev/null || true)
    echo "$output" | awk -v did="$dev_id" '
        /^pin id [0-9]+:/{current_pin=""}
        /board-label:/{current_pin=$2}
        $0 ~ "id "did" direction input.*state connected"{print current_pin}
    ' | head -1
}

# Check T-BC PTP clock state from daemon logs.
# Prints the most recent state: s0 (freerun), s1 (holdover), s2 (locked).
check_tbc_ptp_state() {
    local recent
    recent=$(oc logs -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container --tail=200 2>/dev/null || true)
    echo "$recent" | grep 'T-BC-STATUS' | tail -1 | sed 's/.*T-BC-STATUS \(s[0-9]\).*/\1/'
}

# Check what QL the T-BC synce4l is receiving on ens2f1.
# Prints the QL hex value (e.g., "0x1" for PRC, "0xf" for DNU).
check_tbc_synce_ql() {
    local recent
    recent=$(oc logs -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container --tail=200 2>/dev/null || true)
    echo "$recent" | grep 'synce4l.*synce4l\.1\.config.*QL=.*received on ens2f1' | tail -1 | sed 's/.*QL=\(0x[0-9a-f]*\).*/\1/'
}

# Cleanup on exit — stop remote ticc-logger on clean exit only
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "Script exited with error ($exit_code). Leaving ticc-logger running on remote host."
        return
    fi
    if ssh "$TICC_HOST" "pgrep -f ticc-logger" &>/dev/null; then
        log "Cleanup: stopping ticc-logger on $TICC_HOST"
        ssh "$TICC_HOST" "sudo pkill -f ticc-logger" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
    log "Running pre-flight checks"

    echo -n "  Kubeconfig... "
    [ -f "$KUBECONFIG" ] || die "Kubeconfig not found: $KUBECONFIG"
    echo "OK ($KUBECONFIG)"

    echo -n "  Cluster access... "
    oc get nodes &>/dev/null || die "Cannot reach cluster"
    echo "OK"

    echo -n "  Daemon pod... "
    POD=$(find_pod)
    [ -n "$POD" ] && echo "OK ($POD)" || die "No linuxptp-daemon pod found"

    echo -n "  GM ptp4l socket... "
    GM_SOCKET=$(find_gm_socket)
    echo "OK ($GM_SOCKET)"

    echo -n "  DISABLE_PORT support... "
    local pmc_out
    pmc_out=$(pmc_cmd "COMMAND ENABLE_PORT" 2>&1 || true)
    if echo "$pmc_out" | grep -q "not supported"; then
        die "ptp4l does not support DISABLE_PORT. Deploy patched build."
    fi
    echo "OK"

    echo -n "  T-GM locked... "
    local logs
    logs=$(oc logs -n "$NAMESPACE" "$POD" -c linuxptp-daemon-container --tail=500 2>/dev/null || true)
    if grep -q 'T-GM-STATUS s2\|LOCKED' <<< "$logs"; then
        echo "OK"
    else
        echo "WARNING: Could not confirm T-GM lock in recent logs"
    fi

    echo -n "  T-BC locked... "
    if grep -q 'T-BC-STATUS s2' <<< "$logs"; then
        echo "OK"
    else
        die "T-BC not locked. Wait for lock before running experiment."
    fi

    echo -n "  TICC host reachable... "
    ssh -o ConnectTimeout=5 "$TICC_HOST" "echo ok" &>/dev/null || die "Cannot SSH to $TICC_HOST"
    echo "OK"

    echo -n "  TICC device... "
    ssh "$TICC_HOST" "sudo test -c /dev/ttyACM0" &>/dev/null || die "TICC device /dev/ttyACM0 not found on $TICC_HOST"
    echo "OK"

    echo -n "  ticc-logger on host... "
    ssh "$TICC_HOST" "test -x $TICC_LOGGER" &>/dev/null || die "ticc-logger not found on $TICC_HOST"
    echo "OK"

    echo -n "  Config files... "
    [ -f "$GM_CONFIG" ] || die "GM config not found: $GM_CONFIG"
    [ -f "$BC_CONFIG" ] || die "BC config not found: $BC_CONFIG"
    echo "OK"

    echo -n "  Config backups... "
    [ -f "$GM_CONFIG_BACKUP" ] || die "GM backup not found: $GM_CONFIG_BACKUP (needed for Case 2 restore)"
    [ -f "$BC_CONFIG_BACKUP" ] || die "BC backup not found: $BC_CONFIG_BACKUP"
    echo "OK"

    echo -n "  T-GM EEC DPLL locked... "
    local tgm_eec
    tgm_eec=$(check_tgm_eec_locked)
    if [[ "$tgm_eec" == locked* ]]; then
        echo "OK ($tgm_eec)"
    else
        die "T-GM EEC DPLL not locked: ${tgm_eec:-unknown}. SyncE will not work."
    fi

    echo -n "  GNSS pin prio on T-GM EEC... "
    local gnss_p
    gnss_p=$(check_gnss_prio 0)
    if [ "$gnss_p" = "0" ]; then
        echo "OK (prio=$gnss_p)"
    else
        die "GNSS pin prio on T-GM EEC is ${gnss_p:-unknown} (expected 0). SyncE/DPLL bug may be active."
    fi

    echo -n "  T-BC EEC source... "
    local tbc_eec_src
    tbc_eec_src=$(check_dpll_source 2)
    if [ -n "$tbc_eec_src" ]; then
        echo "OK ($tbc_eec_src)"
    else
        echo "WARNING: no connected source (EEC may be in holdover/freerun)"
    fi

    echo -n "  T-BC PPS source... "
    local tbc_pps_src
    tbc_pps_src=$(check_dpll_source 3)
    if [ -n "$tbc_pps_src" ]; then
        echo "OK ($tbc_pps_src)"
    else
        echo "WARNING: no connected source"
    fi

    if [ "${tbc_eec_src:-}" = "GNSS-1PPS" ] || [ "${tbc_pps_src:-}" = "GNSS-1PPS" ]; then
        echo "  NOTE: T-BC DPLL locked to local GNSS. Script will disable before experiment."
    fi

    if [ "${RUN_CASE:-both}" != "2" ]; then
        echo -n "  T-BC receiving SyncE QL... "
        local ql=""
        for attempt in 1 2 3 4 5 6; do
            ql=$(check_tbc_synce_ql)
            [ -n "$ql" ] && break
            sleep 5
        done
        if [ "$ql" = "0x1" ]; then
            echo "OK (QL=$ql, PRC)"
        elif [ -z "$ql" ]; then
            echo "WARNING: could not determine QL from logs after 30s"
        else
            die "T-BC SyncE QL is $ql (expected 0x1/PRC). SyncE is not working."
        fi
    else
        echo "  T-BC receiving SyncE QL... SKIPPED (Case 2)"
    fi

    log "All pre-flight checks passed"
}

# ─── Experiment Cases ─────────────────────────────────────────────────────────

run_case() {
    local case_num=$1
    local label=$2
    local csv_name=$3
    local expected_ql="${4:-}"  # expected SyncE QL during this case, empty to skip checks

    local timestamp
    timestamp=$(date -u '+%Y%m%d_%H%M%S')
    local remote_csv="$csv_name"
    local local_csv="$OUTPUT_DIR/${csv_name%.csv}-${timestamp}.csv"

    local total_logging_secs=$((BASELINE_SECS + HOLDOVER_SECS + 30))  # +30s buffer
    local status_csv="$OUTPUT_DIR/${csv_name%.csv}-status-${timestamp}.csv"
    # Export for wait_period to append to
    STATUS_CSV="$status_csv"

    log "Case $case_num: $label"
    echo "  Baseline: $(fmt_duration $BASELINE_SECS)"
    echo "  Holdover: $(fmt_duration $HOLDOVER_SECS)"
    echo "  Output:   $local_csv"
    echo "  Status:   $status_csv"

    # Initialize status CSV
    if ! $DRY_RUN; then
        echo "timestamp,phase,tgm_eec,tgm_pps_src,tbc_eec,tbc_eec_src,tbc_pps,tbc_pps_src,tbc_ptp,synce_ql" > "$status_csv"
    fi

    # Start TICC logging (auto-stops after baseline + holdover + buffer)
    ticc_start "$remote_csv" "$total_logging_secs"

    # Baseline period — SyncE should always be 0x1 during baseline
    wait_period "$BASELINE_SECS" "locked baseline (Case $case_num)" "${expected_ql}"

    # Disable PTP on GM to trigger holdover
    log "Disabling GM ptp4l ports"
    run pmc_cmd "COMMAND DISABLE_PORT"

    # Verify holdover
    verify_holdover

    # Holdover period — check SyncE at every progress tick
    wait_period "$HOLDOVER_SECS" "holdover (Case $case_num)" "${expected_ql}"

    # Re-enable PTP
    log "Re-enabling GM ptp4l ports"
    run pmc_cmd "COMMAND ENABLE_PORT" || log "WARNING: ENABLE_PORT failed. Run manually: pmc -u -b 0 -d $PTP_DOMAIN -s $GM_SOCKET COMMAND ENABLE_PORT"

    # Wait for ticc-logger to finish (should be done or close to it)
    ticc_wait

    # Copy data
    ticc_copy "$remote_csv" "$local_csv"

    STATUS_CSV=""
    log "Case $case_num complete. Data saved to $local_csv"
    echo ""
}

case1_with_synce() {
    # Disable T-BC GNSS so it locks to SyncE/PTP instead
    log "Disabling T-BC GNSS on EEC and PPS DPLLs"
    set_gnss_prio 255 2 3
    wait_for_lock 600
    wait_period 300 "settling after GNSS disable"

    # Verify GNSS is not the source
    local tbc_eec_src tbc_pps_src
    tbc_eec_src=$(check_dpll_source 2 || true)
    tbc_pps_src=$(check_dpll_source 3 || true)
    log "T-BC DPLL sources: EEC-SRC=${tbc_eec_src:-none} PPS-SRC=${tbc_pps_src:-none}"
    if [ "${tbc_eec_src:-}" = "GNSS-1PPS" ] || [ "${tbc_pps_src:-}" = "GNSS-1PPS" ]; then
        die "T-BC DPLL still locked to GNSS after pin disable."
    fi

    run_case 1 "Holdover WITH SyncE" "holdover-with-synce.csv" "0x1"
}

case2_without_synce() {
    # Backup configs and strip SyncE
    log "Case 2 prep: removing SyncE from configs"
    run cp "$GM_CONFIG" "$GM_CONFIG.pre-case2"
    run cp "$BC_CONFIG" "$BC_CONFIG.pre-case2"
    run strip_synce "$GM_CONFIG"
    run strip_synce "$BC_CONFIG"

    # Apply configs without SyncE
    log "Applying configs without SyncE"
    run oc apply -f "$GM_CONFIG" -f "$BC_CONFIG"

    # Wait for re-lock after config change
    wait_for_lock 600

    # Wait for daemon to finish reprocessing configs — SetPinDefaults runs after
    # all processes are up, which can take well over 60s
    log "Waiting 5m for daemon to finish config reprocessing (SetPinDefaults)"
    sleep 300

    # Disable T-BC GNSS (daemon re-enabled it via SetPinDefaults during ptp4l restart)
    set_gnss_prio 255 2 3
    wait_period 300 "settling after SyncE removal"

    # Verify GNSS is not the source
    local tbc_eec_src tbc_pps_src
    tbc_eec_src=$(check_dpll_source 2 || true)
    tbc_pps_src=$(check_dpll_source 3 || true)
    log "T-BC DPLL sources: EEC-SRC=${tbc_eec_src:-none} PPS-SRC=${tbc_pps_src:-none}"
    if [ "${tbc_eec_src:-}" = "GNSS-1PPS" ] || [ "${tbc_pps_src:-}" = "GNSS-1PPS" ]; then
        die "T-BC DPLL still locked to GNSS after disable. Daemon may need longer to settle."
    fi

    # Run the experiment
    run_case 2 "Holdover WITHOUT SyncE" "holdover-without-synce.csv"

    # Restore SyncE configs
    log "Restoring SyncE configs"
    run cp "$GM_CONFIG_BACKUP" "$GM_CONFIG"
    run cp "$BC_CONFIG_BACKUP" "$BC_CONFIG"
    run oc apply -f "$GM_CONFIG" -f "$BC_CONFIG"
    log "SyncE configs restored and applied"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          SyncE Holdover Experiment — Automated Runner       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Baseline:  $(printf '%-47s' "$(fmt_duration $BASELINE_SECS)") ║"
    echo "║  Holdover:  $(printf '%-47s' "$(fmt_duration $HOLDOVER_SECS)") ║"
    echo "║  Cases:     $(printf '%-47s' "${RUN_CASE:-1 and 2}") ║"
    echo "║  Output:    $(printf '%-47s' "$OUTPUT_DIR") ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    mkdir -p "$OUTPUT_DIR"

    # Pre-flight
    if ! $SKIP_PREFLIGHT; then
        preflight
    else
        POD=$(find_pod)
        GM_SOCKET=$(find_gm_socket)
    fi

    local total_secs
    case "${RUN_CASE:-both}" in
        1) total_secs=$((BASELINE_SECS + HOLDOVER_SECS)) ;;
        2) total_secs=$((BASELINE_SECS + HOLDOVER_SECS + 900)) ;;  # +15min for config changes
        *) total_secs=$(( (BASELINE_SECS + HOLDOVER_SECS) * 2 + 900 )) ;;
    esac
    log "Estimated total runtime: $(fmt_duration $total_secs)"
    echo ""

    case "${RUN_CASE:-both}" in
        1)
            case1_with_synce
            ;;
        2)
            case2_without_synce
            ;;
        both|"")
            case1_with_synce

            # Re-lock between cases (GNSS stays disabled)
            log "Re-enabling PTP and waiting for T-BC to re-lock before Case 2"
            wait_for_lock 600

            case2_without_synce
            ;;
        *)
            die "Invalid case: $RUN_CASE (use 1, 2, or omit for both)"
            ;;
    esac

    # Restore T-BC GNSS
    log "Restoring T-BC GNSS on EEC and PPS DPLLs"
    set_gnss_prio 0 2 3

    echo ""
    log "Experiment complete!"
    echo ""
    echo "Results in: $OUTPUT_DIR/"
    ls -lh "$OUTPUT_DIR/"*.csv 2>/dev/null || echo "(no CSV files — dry run?)"
}

main
