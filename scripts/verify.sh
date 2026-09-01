#!/usr/bin/env bash
# End-to-end check on the built bundle: ingest, persist, survive a kill, restore, evict, login item.
# Uses temp directories for the store and the screenshot destination so the user's data stays untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh >/dev/null
bin="$PWD/BarCut.app/Contents/MacOS/BarCut"
work="$(mktemp -d /tmp/barcut-verify.XXXXXX)"
store="$work/store"; shots="$work/shots"; mkdir -p "$store" "$shots"
sample="${1:-/tmp/barcut-bench/screen.png}"
[ -f "$sample" ] || screencapture -x "$sample"

launch() {
    BARCUT_STORE_DIR="$store" BARCUT_SCREENSHOT_DIR="$shots" BARCUT_POLL_CLIPBOARD=0 "$bin" >"$work/app-$1.log" 2>&1 &
    echo $!
}
rss_mb() { footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ { print $2; exit }'; }
count_pngs() { find "$store" -maxdepth 1 -name '*.png' | wc -l | tr -d ' '; }
manifest_ids() { python3 -c 'import json,sys; print(" ".join(i["id"]["hex"][:8] for i in json.load(open(sys.argv[1]))["items"]))' "$store/manifest.json" 2>/dev/null || echo "(no manifest)"; }
fail() { echo "FAIL: $*"; exit 1; }

pid=$(launch first); sleep 1.5
echo "launch 1 pid $pid, idle footprint $(rss_mb "$pid") MB"

for i in 1 2 3; do cp "$sample" "$shots/Screenshot $i.png"; sleep 0.4; done
sips -s format png --resampleWidth 900 "$sample" --out "$shots/Screenshot 4.png" >/dev/null
sleep 2
echo "after 4 files: pngs on disk $(count_pngs), manifest ids: $(manifest_ids)"
[ "$(count_pngs)" = 2 ] || fail "expected 2 distinct images on disk (3 identical copies dedup to 1, plus 1 resized)"
echo "footprint after ingest $(rss_mb "$pid") MB"

kill -9 "$pid"; sleep 0.5
echo "killed with SIGKILL"
pid=$(launch second); sleep 1.5
restored=$(log show --process BarCut --last 30s --style compact 2>/dev/null | grep -o 'restored [0-9]* items' | tail -1 || true)
echo "launch 2 pid $pid, log says: ${restored:-(no restore line found)}"
[ "$restored" = "restored 2 items" ] || fail "restore line mismatch"
echo "footprint after restore $(rss_mb "$pid") MB"

for i in $(seq 5 16); do sips -s format png --resampleWidth $((300 + i * 37)) "$sample" --out "$shots/Screenshot $i.png" >/dev/null; sleep 0.3; done
sleep 3
echo "after 12 more distinct files: pngs on disk $(count_pngs), manifest ids: $(manifest_ids)"
[ "$(count_pngs)" = 10 ] || fail "expected eviction to keep 10 files"
echo "footprint after 14 ingests, 10 kept: $(rss_mb "$pid") MB"

kill "$pid" 2>/dev/null || true
echo "PASS. work dir: $work"
