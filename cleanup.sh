ssh "${TICC_HOST:?Set TICC_HOST (e.g. user@host)}" "sudo pkill -f ticc-logger"
./pmc-port-toggle.sh enable
./gnss-toggle.sh enable

