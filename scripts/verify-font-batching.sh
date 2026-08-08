#!/bin/zsh
# Proves the batched font import produces registry state identical to the 57
# individual `wine reg add` calls (spec §5.3). Boots two throwaway prefixes,
# applies one method to each, and diffs the affected registry subtrees.
#
# Usage: scripts/verify-font-batching.sh [workdir]
# Exit 0 = identical. Exit 1 = differences (do NOT ship).
set -u
REPO="${0:A:h:h}"
ENGINE="$HOME/Library/Application Support/OpenXE/engine/current"
WORK="${1:-$(mktemp -d)}"
REAL_PREFIX="$HOME/Library/Application Support/OpenXE/prefix"
case "$WORK" in "$REAL_PREFIX"*) echo "REFUSING: would touch the real prefix"; exit 1;; esac
[[ -x "$ENGINE/wine/bin/wine" ]] || { echo "no engine installed"; exit 1; }
mkdir -p "$WORK"

# Fixtures come from the app's own FontProvisioning table, never hand-written.
# A failure here is fatal: without them the comparison below would run against
# empty inputs and "pass" by comparing nothing to nothing.
if ! swift run --package-path "$REPO" openxe-dump-fontcmds "$WORK"; then
  echo "FAIL: could not generate fixtures from FontProvisioning"; exit 1
fi
for f in substitutions.txt fonts.reg; do
  [[ -s "$WORK/$f" ]] || { echo "FAIL: $WORK/$f missing or empty"; exit 1; }
done

export PATH="$ENGINE/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_FALLBACK_LIBRARY_PATH="$ENGINE/wine/lib:/usr/lib:/usr/local/lib"
export WINEDEBUG=fixme-all

PA="$WORK/pfx-individual"; PB="$WORK/pfx-batched"
boot() { rm -rf "$1"; mkdir -p "$1"; WINEPREFIX="$1" wine wineboot --init >/dev/null 2>&1; WINEPREFIX="$1" wineserver -w; }
echo "booting two throwaway prefixes..."; boot "$PA" & boot "$PB" & wait

# Method A: per-write. Generated from the same table the app uses.
export WINEPREFIX="$PA"
wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' \
    /v "FontAwesome (TrueType)" /t REG_SZ /d "FontAwesome.ttf" /f >/dev/null 2>&1
while IFS='|' read -r from to; do
  [[ -z "$from" ]] && continue
  wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' \
      /v "$from" /t REG_SZ /d "$to" /f >/dev/null 2>&1
  wine reg add 'HKCU\Software\Wine\Fonts\Replacements' \
      /v "$from" /t REG_SZ /d "$to" /f >/dev/null 2>&1
done < "$WORK/substitutions.txt"
wineserver -w

# Method B: batched import of the file the app generates.
export WINEPREFIX="$PB"
wine regedit "$WORK/fonts.reg" >/dev/null 2>&1
wineserver -w

# Extract + normalise the affected subtrees. NOTE: do not pass registry key
# patterns through `awk -v` — it consumes backslashes and silently matches
# nothing, which looks exactly like a passing diff.
extract() {
  local P="$1" OUT="$2"; : > "$OUT"
  for pair in "user.reg:Wine.*Fonts.*Replacements" \
              "system.reg:Microsoft.*Windows NT.*CurrentVersion.*FontSubstitutes" \
              "system.reg:Microsoft.*Windows NT.*CurrentVersion.*Fonts\]"; do
    local f="${pair%%:*}" pat="${pair##*:}"
    print -r -- "### $pat" >> "$OUT"
    grep -n "^\[.*${pat}" "$P/$f" 2>/dev/null | cut -d: -f1 | while read -r ln; do
      print -r -- "--- key: $(sed -n "${ln}p" "$P/$f" | sed 's/ [0-9]*$//')" >> "$OUT"
      sed -n "$((ln+1)),\$p" "$P/$f" | sed -n '/^\[/q;/^"/p' | LC_ALL=C sort >> "$OUT"
    done
  done
}
extract "$PA" "$WORK/A.txt"; extract "$PB" "$WORK/B.txt"

COUNT_A=$(grep -c '^"' "$WORK/A.txt"); COUNT_B=$(grep -c '^"' "$WORK/B.txt")
echo "value lines: individual=$COUNT_A batched=$COUNT_B"
if [[ "$COUNT_A" -eq 0 || "$COUNT_B" -eq 0 ]]; then
  echo "FAIL: extraction produced nothing — the comparison is meaningless"; RC=1
elif diff -u "$WORK/A.txt" "$WORK/B.txt"; then
  echo "PASS: registry state is identical"; RC=0
else
  echo "FAIL: registry state differs"; RC=1
fi

for P in "$PA" "$PB"; do WINEPREFIX="$P" wineserver -k 2>/dev/null; done
exit $RC
