#!/usr/bin/env bash
# Task 28 (#59) scratch: runs every scenario headless at 60 Hz for one label. Usage: Scratch/run_all.sh <label> [main_accel]
GODOT="${GODOT:-/c/Users/Nikos/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe}"
cd "$(dirname "$0")/.."
label="$1"
shift
mkdir -p "Scratch/out/$label"
for s in turn90 turn180 arrive brake brake_noretro crab10 clear route a2_5 a2_6 queue crossover; do
	"$GODOT" --headless --path . --fixed-fps 60 --script res://Scratch/experiment.gd -- "$s" "$label" "$@" > "Scratch/out/$label/$s.log" 2>&1
	grep -q '^RESULT' "Scratch/out/$label/$s.log" && echo "$label/$s ok" || echo "$label/$s FAILED"
done
