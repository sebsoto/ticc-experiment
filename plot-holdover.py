#!/usr/bin/env python3
"""Plot TICC holdover experiment results."""
import argparse
import csv
import sys
from datetime import datetime, timedelta

import numpy as np
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


def compute_stats(timestamps, offsets, holdover_ts, threshold_ns=1000):
    """Compute holdover statistics. Returns a dict of stats."""
    stats = {}

    pre_cutoff = holdover_ts - timedelta(minutes=30)
    pre = [(t, o) for t, o in zip(timestamps, offsets)
           if pre_cutoff <= t < holdover_ts]
    post = [(t, o) for t, o in zip(timestamps, offsets) if t >= holdover_ts]

    # Pre-holdover standard deviation (IQR-filtered to remove outliers)
    if pre:
        pre_offsets = np.array([o for _, o in pre])
        q1, q3 = np.percentile(pre_offsets, [25, 75])
        iqr = q3 - q1
        mask = (pre_offsets >= q1 - 1.5 * iqr) & (pre_offsets <= q3 + 1.5 * iqr)
        filtered = pre_offsets[mask]
        n_removed = len(pre_offsets) - len(filtered)
        if n_removed:
            stats["pre_holdover_outliers"] = n_removed
        stats["pre_holdover_std_ns"] = float(np.std(filtered)) if len(filtered) else None
    else:
        stats["pre_holdover_std_ns"] = None

    if not post:
        return stats

    post_times = [(t - holdover_ts).total_seconds() for t, _ in post]
    post_offsets = [o for _, o in post]

    # Drift rate via linear fit (ns/s)
    if len(post) >= 2:
        coeffs = np.polyfit(post_times, post_offsets, 1)
        stats["drift_rate_ns_per_s"] = coeffs[0]
    else:
        stats["drift_rate_ns_per_s"] = None

    # Max absolute offset during holdover
    stats["max_abs_offset_ns"] = max(abs(o) for o in post_offsets)

    # Time to exceed threshold
    stats["threshold_ns"] = threshold_ns
    stats["time_to_threshold_s"] = None
    for t_s, o in zip(post_times, post_offsets):
        if abs(o) > threshold_ns:
            stats["time_to_threshold_s"] = t_s
            break

    # Offset at fixed intervals
    intervals = [60, 300, 600]
    stats["offset_at"] = {}
    for target in intervals:
        closest = None
        best_diff = float("inf")
        for t_s, o in zip(post_times, post_offsets):
            diff = abs(t_s - target)
            if diff < best_diff:
                best_diff = diff
                closest = (t_s, o)
        if closest and best_diff < 5:  # within 5s tolerance
            stats["offset_at"][target] = closest[1]

    return stats


def format_stats(stats):
    """Format stats dict into lines for display."""
    lines = []

    pre_std = stats.get("pre_holdover_std_ns")
    if pre_std is not None:
        outliers = stats.get("pre_holdover_outliers", 0)
        suffix = f" ({outliers} outliers removed)" if outliers else ""
        lines.append(f"Pre-holdover σ: {pre_std:.1f} ns{suffix}")

    drift = stats.get("drift_rate_ns_per_s")
    if drift is not None:
        lines.append(f"Drift rate: {drift:.2f} ns/s")

    max_off = stats.get("max_abs_offset_ns")
    if max_off is not None:
        lines.append(f"Max |offset|: {max_off:.1f} ns")

    threshold = stats.get("threshold_ns", 1000)
    t2t = stats.get("time_to_threshold_s")
    if t2t is not None:
        lines.append(f"Time to ±{threshold} ns: {t2t:.0f} s")
    elif max_off is not None:
        lines.append(f"Time to ±{threshold} ns: not reached")

    for interval, val in sorted(stats.get("offset_at", {}).items()):
        label = f"{interval // 60}min" if interval >= 60 else f"{interval}s"
        lines.append(f"Offset @ {label}: {val:.1f} ns")

    return lines


def main():
    parser = argparse.ArgumentParser(description="Plot TICC holdover data")
    parser.add_argument("csv", help="TICC data CSV file")
    parser.add_argument("--status", help="Status CSV file (to mark holdover start)")
    parser.add_argument("--title", default="Holdover Experiment")
    parser.add_argument("-o", "--output", help="Save plot to file (e.g. plot.png)")
    parser.add_argument(
        "--actual-time",
        action="store_true",
        help="Show actual UTC time on x-axis instead of elapsed time",
    )
    args = parser.parse_args()

    timestamps, offsets = parse_csv(args.csv)
    if not timestamps:
        print("No data found", file=sys.stderr)
        sys.exit(1)

    # Find holdover start
    holdover_ts = None
    if args.status:
        holdover_ts = find_holdover_start(args.status)
    if holdover_ts:
        print(f"  Holdover start: {holdover_ts}")
    else:
        print("Warning: no holdover start found, plotting all data", file=sys.stderr)

    # Trim to 10 minutes before holdover
    if holdover_ts:
        cutoff = holdover_ts - timedelta(minutes=30)
        paired = [(t, o) for t, o in zip(timestamps, offsets) if t >= cutoff]
        if not paired:
            print("No data in the 30 min before holdover window", file=sys.stderr)
            sys.exit(1)
        timestamps, offsets = zip(*paired)
        timestamps, offsets = list(timestamps), list(offsets)

    print(f"Plotting {len(timestamps)} measurements")
    print(f"  Time range: {timestamps[0]} → {timestamps[-1]}")
    print(f"  Offset range: {min(offsets):.1f} ns → {max(offsets):.1f} ns")

    fig, ax = plt.subplots(figsize=(14, 6))

    if args.actual_time:
        ax.plot(timestamps, offsets, linewidth=0.5, color="steelblue")
        ax.set_xlabel("Time (UTC)")
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
        if holdover_ts:
            ax.axvline(holdover_ts, color="red", linestyle="--", linewidth=1, label="Holdover start")
    else:
        ref = holdover_ts if holdover_ts else timestamps[0]
        elapsed = [(t - ref).total_seconds() / 3600 for t in timestamps]
        ax.plot(elapsed, offsets, linewidth=0.5, color="steelblue")
        ax.set_xlabel("Time since holdover (hours)")
        if holdover_ts:
            ax.axvline(0, color="red", linestyle="--", linewidth=1, label="Holdover start")

    ax.set_ylabel("Offset (ns)")
    ax.set_title(args.title)
    ax.grid(True, alpha=0.3)

    # Compute and display stats
    if holdover_ts:
        stats = compute_stats(timestamps, offsets, holdover_ts)
        stat_lines = format_stats(stats)

        print("\n  --- Statistics ---")
        for line in stat_lines:
            print(f"  {line}")

        stat_text = "    ".join(stat_lines)
        fig.text(
            0.5, -0.02, stat_text,
            ha="center", va="top", fontsize=7, fontfamily="monospace",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="wheat", alpha=0.8),
        )
        ax.legend()

    plt.tight_layout()
    fig.subplots_adjust(bottom=0.15)
    if args.output:
        plt.savefig(args.output, dpi=150, bbox_inches="tight")
        print(f"Saved to {args.output}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
