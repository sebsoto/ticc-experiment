# TICC SyncE Holdover Experiment

Measures SyncE's effect on holdover accuracy in a T-GM → T-BC topology using a
TAPR TICC time interval counter.

## Topology

```
GNSS antenna
    |
NIC1 (ens1f0) -- T-GM (GNSS-locked, SyncE leader)
    | ens1f1 ------- PTP + SyncE ------+--- SMA1 1PPS out --> TICC chA
    v                                   |
NIC2 (ens2f1) -- T-BC (PTP follower)---+
    | ens2f0 ------- SMA1 1PPS out --> TICC chB
```

The TICC measures the 1PPS phase difference between GM and BC each second.

## Test cases

**Case 1 — Holdover with SyncE**: GM ptp4l ports are disabled via
`pmc COMMAND DISABLE_PORT`. The physical link stays up, so SyncE continues
providing frequency to the T-BC EEC DPLL. 

**Case 2 — Holdover without SyncE**: Same as Case 1, but `synce4lConf` /
`synce4lOpts` are stripped from the PtpConfig CRs first. The T-BC EEC DPLL
has no frequency reference and free-runs on its internal oscillator.

## Experiment procedure

1. Disable T-BC local GNSS pins (prio=255) so DPLL locks to SyncE/PTP, not GNSS
2. Start `ticc-logger` on `$TICC_HOST` (records 1PPS offset each second)
3. Wait for baseline period (system locked, TICC recording)
4. Disable T-GM ptp4l ports: `pmc COMMAND DISABLE_PORT` on the GM socket
5. T-BC ptp4l hits `ANNOUNCE_RECEIPT_TIMEOUT_EXPIRES`, transitions SLAVE → MASTER
6. Daemon fires `EnterHoldoverTBC()` (disables SDP22 PPS input, enables SDP23 output)
7. BC FSM transitions LOCKED → HOLDOVER (s1)
8. Wait for holdover period (TICC still recording drift)
9. Re-enable T-GM ptp4l ports: `pmc COMMAND ENABLE_PORT`
10. Collect TICC data from `$TICC_HOST`

For Case 2, the script also strips SyncE config before step 1 and restores it
after step 10.

## Prerequisites

- Patched ptp4l with `DISABLE_PORT` support (upstream `ddeec0f`, cherry-picked onto v4.4)
- T-GM and T-BC PtpConfig CRs applied, both locked (`s2`)
- TICC in Time Interval mode (A4) with 10 MHz EXT_REF
- `ticc-logger` binary on `$TICC_HOST` with SSH key access

## Environment variables

```bash
export KUBECONFIG=/path/to/kubeconfig.yaml
export TICC_HOST=user@ticc-host
```

## Usage

```bash
# Case 1 (with SyncE): 20 min baseline, 1 hour holdover
./holdover-experiment.sh -c 1 -b 1200 -h 3600

# Case 2 (without SyncE): 20 min baseline, 1 hour holdover
./holdover-experiment.sh -c 2 -b 1200 -h 3600

# Both cases sequentially
./holdover-experiment.sh -b 1800 -h 43200

# Dry run
./holdover-experiment.sh -c 1 -b 300 -h 900 -n
```

| Flag | Default | Description |
|------|---------|-------------|
| `-b` | 3600 | Baseline (locked) duration in seconds |
| `-h` | 14400 | Holdover duration in seconds |
| `-c` | both | Run only case `1` or `2` |
| `-o` | `./results` | Output directory |
| `-s` | off | Skip pre-flight checks |
| `-n` | off | Dry run |

## Helper scripts

- `pmc-port-toggle.sh {disable|enable|status}` — toggle T-GM ptp4l ports
- `gnss-toggle.sh {disable|enable|status}` — toggle T-BC GNSS DPLL pin priority

## Building ticc-logger

```bash
GOOS=linux GOARCH=amd64 go build -o ticc-logger .
scp ticc-logger $TICC_HOST:~/ticc-logger
```

## Output

Each run produces two CSVs in `results/`:

- `holdover-{with,without}-synce-TIMESTAMP.csv` — TICC measurements (`timestamp,offset_s`, one row/sec)
- `holdover-{with,without}-synce-status-TIMESTAMP.csv` — periodic DPLL/PTP state checks

## Files

| File | Description |
|------|-------------|
| `holdover-experiment.sh` | Automated experiment runner |
| `main.go` | ticc-logger: reads TICC serial, writes CSV |
| `plot-holdover.py` | Plot TICC results |
| `pmc-port-toggle.sh` | Toggle GM ptp4l ports |
| `gnss-toggle.sh` | Toggle T-BC GNSS DPLL pins |
