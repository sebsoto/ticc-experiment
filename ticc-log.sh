#!/bin/bash
# Log TICC Time Interval measurements to a file
# Must be run as root (sudo ./ticc-log.sh ...)
#
# Usage:
#   sudo ./ticc-log.sh <output_file>        Run in foreground (Ctrl+C to stop)
#   sudo ./ticc-log.sh -d <output_file>     Run detached (survives SSH disconnect)
#   sudo ./ticc-log.sh -s                   Show status of detached logging
#   sudo ./ticc-log.sh -k                   Stop detached logging
#
# Detached mode writes to the output file and a .pid file for cleanup.
# Safe to disconnect SSH after starting — logging continues on the host.

DEVICE="/dev/ttyACM0"
BAUD=115200
PIDFILE="/tmp/ticc-log.pid"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root: sudo $0 $*"
    exit 1
fi

do_log() {
    local outfile="$1"
    stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb raw -echo
    cat "$DEVICE" | while IFS= read -r line; do
        if [[ "$line" != \#* && -n "$line" ]]; then
            echo "$line" >> "$outfile"
        fi
    done
}

case "${1:-}" in
    -d)
        OUTFILE="$(pwd)/${2:-ticc_$(date +%Y%m%d_%H%M%S).log}"
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "Already logging (PID $(cat "$PIDFILE")). Stop first with: $0 -k"
            exit 1
        fi
        echo "Starting detached TICC logging to: $OUTFILE"
        stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb raw -echo
        nohup bash -c "cat '$DEVICE' | while IFS= read -r line; do
            if [[ \"\$line\" != \\#* && -n \"\$line\" ]]; then
                echo \"\$line\" >> '$OUTFILE'
            fi
        done" > /dev/null 2>&1 &
        echo $! > "$PIDFILE"
        echo "PID: $(cat "$PIDFILE")"
        echo "Disconnect SSH safely. Check status: sudo $0 -s  Stop: sudo $0 -k"
        sleep 2
        if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "Logging started successfully."
        else
            echo "ERROR: Logging process died. Check $DEVICE."
            rm -f "$PIDFILE"
            exit 1
        fi
        ;;
    -s)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "TICC logging is running (PID $(cat "$PIDFILE"))"
            # Find the output file
            logfiles=$(ls -t ticc_*.log *-synce.log *-5min.log 2>/dev/null | head -1)
            if [ -n "$logfiles" ]; then
                lines=$(wc -l < "$logfiles")
                echo "Log file: $logfiles ($lines measurements)"
                echo "Last 3 readings:"
                tail -3 "$logfiles"
            fi
        else
            echo "No TICC logging running."
            rm -f "$PIDFILE"
        fi
        ;;
    -k)
        if [ -f "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE")
            if kill -0 "$pid" 2>/dev/null; then
                kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
                echo "Stopped TICC logging (PID $pid)"
            else
                echo "Process $pid not running."
            fi
            rm -f "$PIDFILE"
        else
            echo "No PID file found."
        fi
        ;;
    *)
        OUTFILE="${1:-ticc_$(date +%Y%m%d_%H%M%S).log}"
        stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb raw -echo
        echo "Logging TICC output to: $OUTFILE"
        echo "Waiting for 1PPS pulses on chA and chB..."
        echo "Press Ctrl+C to stop."
        cat "$DEVICE" | while IFS= read -r line; do
            if [[ "$line" != \#* && -n "$line" ]]; then
                echo "$line" | tee -a "$OUTFILE"
            else
                echo "$line"
            fi
        done
        ;;
esac
