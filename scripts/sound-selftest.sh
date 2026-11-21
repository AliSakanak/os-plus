#!/bin/zsh
# End-to-end check of per-app volume, run as the installed OS+.app (so macOS applies
# the app's own audio permission, not the terminal's).
#   scripts/sound-selftest.sh            full test: quiet 440 Hz tone via afplay for ~2 s, turned to 50% by a real tap
#   scripts/sound-selftest.sh list       just list the apps using audio (changes nothing)
#   scripts/sound-selftest.sh output-test   inaudible (−100 dBFS) test of the output half; no permission needed
set -euo pipefail
MODE="${1:-selftest}"
OUT=$(mktemp -t workbench-sound)
trap 'rm -f "$OUT"' EXIT
# (`open -W` can't always wait on an app that exits this fast; its complaint about that is harmless.)
open -n -W --stdout "$OUT" --stderr "$OUT" /Applications/OS+.app --args --sound-cli "$MODE" 2>/dev/null || true
sleep 0.2
for _ in {1..80}; do   # the full self-test takes ~3 s; wait for its verdict
    grep -qE "^(PASS|FAIL)|^Permission is|^usage" "$OUT" && break
    [[ "$MODE" == "list" ]] && break
    sleep 0.1
done
cat "$OUT"
[[ "$MODE" == "list" ]] && exit 0
grep -q "^PASS" "$OUT"
