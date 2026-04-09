#!/usr/bin/env python3
"""Plot TICC holdover experiment results."""
import argparse
import csv
import sys
from datetime import datetime

import matplotlib.pyplot as plt
import matplotlib.dates as mdates


def parse_csv(path):
    timestamps, offsets = [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
            offset_ns = float(row["offset_s"]) * 1e9  # convert to nanoseconds
            timestamps.append(ts)
            offsets.append(offset_ns)
    return timestamps, offsets


def find_holdover_start(status_path):
    """Find the first 'holdover' phase timestamp from a status CSV."""
    try:
        with open(status_path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                if "holdover" in row.get("phase", "").lower():
                    return datetime.fromisoformat(
                        row["timestamp"].replace("Z", "+00:00")
                    )
    except FileNotFoundError:
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description="Plot TICC holdover data")
    parser.add_argument("csv", help="TICC data CSV file")
    parser.add_argument("--status", help="Status CSV file (to mark holdover start)")
    parser.add_argument("--title", default="Holdover Experiment")
    parser.add_argument("-o", "--output", help="Save plot to file (e.g. plot.png)")
    args = parser.parse_args()

    timestamps, offsets = parse_csv(args.csv)
    if not timestamps:
        print("No data found", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(timestamps)} measurements")
    print(f"  Time range: {timestamps[0]} → {timestamps[-1]}")
    print(f"  Offset range: {min(offsets):.1f} ns → {max(offsets):.1f} ns")

    fig, ax = plt.subplots(figsize=(14, 6))
    ax.plot(timestamps, offsets, linewidth=0.5, color="steelblue")
    ax.set_xlabel("Time (UTC)")
    ax.set_ylabel("Offset (ns)")
    ax.set_title(args.title)
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))

    # Mark holdover start
    holdover_ts = None
    if args.status:
        holdover_ts = find_holdover_start(args.status)
    if holdover_ts:
        ax.axvline(holdover_ts, color="red", linestyle="--", linewidth=1, label="Holdover start")
        ax.legend()
        print(f"  Holdover start: {holdover_ts}")

    plt.tight_layout()
    if args.output:
        plt.savefig(args.output, dpi=150)
        print(f"Saved to {args.output}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
