"""Merge downloaded usage/<uid>/<ms>.json session files into one CSV and print per-variant averages.

    python tools/usage_to_csv.py path/to/usage [out.csv]
"""
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

METRICS = ["duration_s", "detent_ticks", "scrub_ticks", "scrub_marks", "button_presses",
           "spins", "bumps", "mean_tick_rate", "peak_tick_rate"]


def load(root: Path) -> list[dict]:
    rows = []
    for path in sorted(root.glob("*/*.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        tuning = record.pop("tuning", {})
        row = {"user": path.parent.name, "file": path.name, **record}
        row.update({f"tuning.{k}": v for k, v in sorted(tuning.items())})
        rows.append(row)
    return rows


def main() -> None:
    root = Path(sys.argv[1])
    out = Path(sys.argv[2] if len(sys.argv) > 2 else "usage.csv")
    rows = load(root)
    if not rows:
        sys.exit(f"No session files under {root}/<user>/*.json")

    columns = list(dict.fromkeys(key for row in rows for key in row))
    with out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} sessions to {out}\n")

    by_variant = defaultdict(list)
    for row in rows:
        by_variant[row.get("variant", "?")].append(row)
    print("variant".ljust(14) + "users  sessions  " + "  ".join(m.rjust(14) for m in METRICS))
    for variant, group in sorted(by_variant.items()):
        users = len({r["user"] for r in group})
        means = [sum(r.get(m, 0) for r in group) / len(group) for m in METRICS]
        print(variant.ljust(14) + f"{users:5}  {len(group):8}  " + "  ".join(f"{v:14.1f}" for v in means))
    excluded = sum(1 for r in rows if r.get("tuning_customized") or r.get("config_source") != "remote")
    if excluded:
        print(f"\nNote: {excluded} session(s) had Haptics Lab edits or no remote config; filter them in the CSV.")


if __name__ == "__main__":
    main()
