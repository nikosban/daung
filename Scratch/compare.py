"""Task 28 (#59) scratch: compares labels' summaries and draws trail SVGs. Usage: python Scratch/compare.py main c1 c2 ..."""
import csv
import json
import sys
from pathlib import Path

OUT = Path(__file__).parent / "out"
labels = sys.argv[1:]

ROWS = [
    ("turn90", ["speed_at_activation", "turn_radius", "turn_min_speed", "speed_lost", "drift_past_destination_line",
                "arrival_time", "turn_exit_time", "max_bow_to_travel", "bow_to_travel_last_over_5deg",
                "bow_to_path_last_over_5deg", "final_miss", "turn_sign_flips_last_10s"]),
    ("turn180", ["speed_at_activation", "turn_radius", "speed_lost", "forward_overshoot_past_order_point", "arrival_time",
                 "turn_exit_time", "max_bow_to_travel", "bow_to_travel_last_over_5deg", "bow_to_path_last_over_5deg",
                 "final_miss", "turn_sign_flips_last_10s"]),
    ("arrive", ["speed_at_activation", "arrival_time", "final_miss"]),
    ("brake", ["speed_at_activation", "stopping_distance", "stopping_time", "peak_sternward_thrust",
               "max_speed_drop_per_tick", "speed_monotonic"]),
    ("brake_noretro", ["speed_at_activation", "stopping_distance", "stopping_time", "peak_sternward_thrust",
                       "speed_monotonic"]),
    ("crab10", ["arrival_time", "displacement", "final_miss", "peak_speed", "max_line_deviation", "yaw_change"]),
    ("clear", ["arrival_time", "final_miss", "max_off_mesh", "bow_to_path_last_over_5deg", "turn_sign_flips_last_10s"]),
    ("route", ["arrival_time", "final_miss", "min_hull_gap", "max_off_mesh", "max_bow_to_path",
               "bow_to_path_last_over_5deg", "turn_sign_flips_last_10s"]),
    ("a2_5", ["arrived", "arrival_time", "min_hull_gap", "max_off_mesh", "contact"]),
    ("a2_6", ["arrived", "arrival_time", "min_hull_gap", "max_off_mesh", "contact"]),
    ("queue", ["activations", "arrival_time", "final_miss"]),
    ("crossover", ["crossover_speed"]),
]


def load(label, scenario):
    path = OUT / label / f"{scenario}.json"
    return json.loads(path.read_text()) if path.exists() else None


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        if v == -1.0:
            return "n/a"
        return f"{v:.2f}"
    if isinstance(v, list):
        return " / ".join(fmt(x) for x in v)
    return str(v) if v != "" else "none"


def table():
    lines = []
    for scenario, keys in ROWS:
        lines.append(f"\n**{scenario}**\n")
        lines.append("| metric | " + " | ".join(labels) + " |")
        lines.append("|---|" + "---|" * len(labels))
        data = [load(l, scenario) for l in labels]
        for key in keys + ["max_thrust_fraction", "profile_unchanged"]:
            if all(d is None or key not in d for d in data):
                continue
            lines.append(f"| {key} | " + " | ".join(fmt(d.get(key) if d else None) for d in data) + " |")
        if scenario in ("a2_5", "a2_6"):
            for l, d in zip(labels, data):
                if d:
                    lines.append(f"\n{l}: " + "; ".join(d.get("status", [])[-2:]))
    return "\n".join(lines)


COLORS = {"main": "#888888", "c1": "#d9534f", "c2": "#f0ad4e", "c3": "#2a9d8f", "c3_15": "#6f42c1", "c2_15": "#6f42c1"}


def svg(scenario):
    traces = {}
    for l in labels:
        path = OUT / l / f"{scenario}.csv"
        if not path.exists():
            continue
        with path.open() as f:
            rows = list(csv.DictReader(f))
        traces[l] = rows
    if not traces:
        return
    xs = [float(r["x"]) for rows in traces.values() for r in rows]
    zs = [float(r["z"]) for rows in traces.values() for r in rows]
    pad = 15
    x0, x1, z0, z1 = min(xs) - pad, max(xs) + pad, min(zs) - pad, max(zs) + pad
    w = 900
    scale = w / max(x1 - x0, 1)
    h = max(200, (z1 - z0) * scale)
    if h > 900:
        scale = 900 / (z1 - z0)
        h = 900
        w = (x1 - x0) * scale
    def p(x, z):
        return (x - x0) * scale, (z - z0) * scale
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h + 30:.0f}" viewBox="0 0 {w:.0f} {h + 30:.0f}">',
           f'<rect width="100%" height="100%" fill="#ffffff"/>']
    # Asteroid no-go zones (19.75 m) and bodies (7.5 m) in view.
    for ax, az in ASTEROIDS:
        if x0 - 20 < ax < x1 + 20 and z0 - 20 < az < z1 + 20:
            cx, cz = p(ax, az)
            out.append(f'<circle cx="{cx:.1f}" cy="{cz:.1f}" r="{19.75 * scale:.1f}" fill="#f6e3e3" stroke="#e0b0b0"/>')
            out.append(f'<circle cx="{cx:.1f}" cy="{cz:.1f}" r="{7.5 * scale:.1f}" fill="#999"/>')
    for i, (l, rows) in enumerate(traces.items()):
        color = COLORS.get(l, "#333")
        pts = " ".join("%.1f,%.1f" % p(float(r["x"]), float(r["z"])) for r in rows)
        out.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2"/>')
        # Bow ticks every 2 s.
        last = -9.0
        for r in rows:
            t = float(r["t"])
            if t - last >= 2.0:
                last = t
                import math
                yaw = math.radians(float(r["yaw"]))
                bx, bz = -math.sin(yaw), -math.cos(yaw)
                x, z = float(r["x"]), float(r["z"])
                a = p(x - bx * 5, z - bz * 5)
                b = p(x + bx * 5, z + bz * 5)
                out.append(f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke="{color}" stroke-width="3" opacity="0.6"/>')
        d = load(l, scenario)
        if d and "destination" in d:
            cx, cz = p(*d["destination"])
            out.append(f'<circle cx="{cx:.1f}" cy="{cz:.1f}" r="4" fill="none" stroke="{color}" stroke-width="2"/>')
        out.append(f'<text x="{10 + i * 110}" y="{h + 20:.0f}" fill="{color}" font-family="sans-serif" font-size="14">■ {l}</text>')
    out.append(f'<text x="{w - 10:.0f}" y="{h + 20:.0f}" text-anchor="end" fill="#555" font-family="sans-serif" font-size="12">{scenario}: X right, Z down; bow ticks every 2 s; 10 m = {10 * scale:.0f} px</text>')
    out.append("</svg>")
    report = OUT.parent / "report"
    report.mkdir(exist_ok=True)
    (report / f"{scenario}.svg").write_text("\n".join(out), encoding="utf-8")


def asteroid_positions():
    data = load("main", "a2_5")
    return []


ASTEROIDS = [(83, 0)] + [(215 + x, -170 + z) for x, z in [(-34, -22), (25, -31), (-26, 32), (34, 24)]] \
    + [(-155 + x, -165 + z) for x, z in [(-58, -42), (-5, -63), (52, -43), (-63, 15), (15, 4), (67, 20), (-36, 65), (42, 62)]] \
    + [(50 + x, 205 + z) for x, z in [(-82, -66), (-26, -84), (38, -84), (91, -63), (-95, 0), (-37, -15), (30, -20), (92, 2), (-80, 72), (-17, 82), (47, 80), (92, 69)]]

if __name__ == "__main__":
    print(table())
    for s in ["turn90", "turn180", "crab10", "route", "clear", "a2_5", "a2_6", "brake", "arrive"]:
        svg(s)
