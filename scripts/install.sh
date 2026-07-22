#!/bin/sh
# Seahelm installer — downloads the latest (or given) release and installs
# Seahelm.app into /Applications (or ~/Applications without write access).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BetaYao/seahelm/main/scripts/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- v2.0.11      # pin a version
#   SEAHELM_INSTALL_DIR=~/Applications sh install.sh  # custom destination
#
# The sea/helm intro animation and progress bars are cosmetic: they render only
# on an interactive terminal and fall back to plain text otherwise (piped output,
# TERM=dumb, or NO_COLOR set). None of it touches the install path.
set -eu

REPO="BetaYao/seahelm"
VERSION="${1:-}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || err "seahelm is macOS-only"

case "$(uname -m)" in
  arm64)  ARCH="arm64" ;;
  x86_64) ARCH="x86_64" ;;
  *) err "unsupported architecture: $(uname -m)" ;;
esac

ESC=$(printf '\033')
E="${ESC}["
R="${E}0m"

# True when it's safe to draw color/animation (interactive tty, capable term).
anim_ok() { [ -t 1 ] && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR:-}" ]; }

# ============================================================================
# Intro animation: a solid gold ship's wheel turning above the SEAHELM wordmark
# and the sea. Grid of 2-wide cells; distance/angle bands; integer math only.
# ============================================================================
CX=8; CY=8; GW=17; GH=17
RIM_LO=32; RIM_HI=44; HUB_HI=5; SPOKE_HI=33; HND_LO=50; HND_HI=72
WMARGIN='               '
C_HUB=51; C_RIM=178; C_SPOKE=136; C_HND=214; C_LIT=231; C_LIT2=228

on_spoke() { [ "$1" -eq 0 ] && return 0; [ "$2" -eq 0 ] && return 0
  [ "$1" -eq "$2" ] && return 0; [ "$1" -eq "$((-$2))" ] && return 0; return 1; }

octant() { # dx dy -> OCT 0..7 clockwise from top
  dx=$1; dy=$2; adx=$dx; [ "$adx" -lt 0 ] && adx=$((-adx)); ady=$dy; [ "$ady" -lt 0 ] && ady=$((-ady))
  if [ "$dy" -lt 0 ]; then
    if [ "$adx" -le 2 ]; then OCT=0
    elif [ "$dx" -gt 0 ]; then { [ "$adx" -gt "$ady" ] && OCT=2 || OCT=1; }
    else { [ "$adx" -gt "$ady" ] && OCT=6 || OCT=7; }; fi
  elif [ "$dy" -gt 0 ]; then
    if [ "$adx" -le 2 ]; then OCT=4
    elif [ "$dx" -gt 0 ]; then { [ "$adx" -gt "$ady" ] && OCT=2 || OCT=3; }
    else { [ "$adx" -gt "$ady" ] && OCT=6 || OCT=5; }; fi
  else [ "$dx" -ge 0 ] && OCT=2 || OCT=6; fi
}

wheel_cell() { # row col lit -> GL
  dx=$(( $2 - CX )); dy=$(( $1 - CY )); d2=$(( dx*dx + dy*dy )); lit=$3
  if [ "$d2" -le "$HUB_HI" ]; then GL="${E}1m${E}38;5;${C_HUB}m██"; return; fi
  if [ "$d2" -ge "$RIM_LO" ] && [ "$d2" -le "$RIM_HI" ]; then
    octant "$dx" "$dy"
    if [ "$OCT" -eq "$lit" ]; then GL="${E}1m${E}38;5;${C_LIT}m██"; else GL="${E}38;5;${C_RIM}m██"; fi; return; fi
  if [ "$d2" -ge "$HND_LO" ] && [ "$d2" -le "$HND_HI" ] && on_spoke "$dx" "$dy"; then
    octant "$dx" "$dy"
    if [ "$OCT" -eq "$lit" ]; then GL="${E}1m${E}38;5;${C_LIT2}m██"; else GL="${E}38;5;${C_HND}m██"; fi; return; fi
  if [ "$d2" -lt "$SPOKE_HI" ] && on_spoke "$dx" "$dy"; then
    octant "$dx" "$dy"
    if [ "$OCT" -eq "$lit" ]; then GL="${E}38;5;${C_LIT2}m██"; else GL="${E}38;5;${C_SPOKE}m██"; fi; return; fi
  GL='  '
}

draw_wheel() { # lit octant (8 = none lit)
  lit=$1; row=0
  while [ "$row" -lt "$GH" ]; do
    line=""; col=0
    while [ "$col" -lt "$GW" ]; do wheel_cell "$row" "$col" "$lit"; line="${line}${GL}"; col=$((col+1)); done
    printf '%s%s%s\n' "$WMARGIN" "$line" "$R"
    row=$((row+1))
  done
}

# SEAHELM wordmark (1=block) with a gold sheen crest at column `h`.
WM0="11111 11111 01110 10001 11111 10000 10001"
WM1="10000 10000 10001 10001 10000 10000 11011"
WM2="11111 11110 11111 11111 11110 10000 10101"
WM3="00001 10000 10001 10001 10000 10000 10001"
WM4="11111 11111 10001 10001 11111 11111 10001"
sheen() { case "$1" in 0)CLR=231;;1)CLR=230;;2)CLR=229;;3)CLR=223;;4)CLR=222;;5)CLR=214;;6)CLR=208;;7)CLR=172;;*)CLR=25;; esac; }
wm_row() { s=$1; h=$2; out=""; c=0
  while [ -n "$s" ]; do ch=${s%"${s#?}"}; s=${s#?}
    if [ "$ch" = 1 ]; then d=$((c-h)); [ "$d" -lt 0 ] && d=$((-d)); sheen "$d"; out="${out}${E}38;5;${CLR}m█"; else out="${out} "; fi
    c=$((c+1)); done
  printf '            %s%s\n' "$out" "$R"; }
draw_wordmark() { wm_row "$WM0" "$1"; wm_row "$WM1" "$1"; wm_row "$WM2" "$1"; wm_row "$WM3" "$1"; wm_row "$WM4" "$1"; }

WVA='∼≈∼  ≈∼≈  ∼≈∼  ≈∼≈  ∼≈∼  ≈∼≈  ∼'
WVB='≈∼≈  ∼≈∼  ≈∼≈  ∼≈∼  ≈∼≈  ∼≈∼  ≈'
draw_waves() { if [ "${1:-0}" -eq 0 ]; then a=$WVA; b=$WVB; else a=$WVB; b=$WVA; fi
  printf '            %s%s%s\n' "${E}38;5;51m" "$a" "$R"
  printf '            %s%s%s\n' "${E}38;5;38m" "$b" "$R"
  printf '            %s%s%s\n' "${E}38;5;24m" "$a" "$R"; }

seahelm_animation() {
  if ! anim_ok; then
    printf '\n     ,--.\n    ( () )   Seahelm\n     `--'\''\n\n'
    return
  fi
  printf '%s%s' "${E}?25l" "${E}2J${E}H"
  trap 'printf "%s%s\n" "$R" "${E}?25h"; exit 130' INT TERM
  n=0
  while [ "$n" -lt 32 ]; do
    printf '%s' "${E}H"; printf '\n'
    draw_wheel "$((n % 8))"; printf '\n'
    draw_wordmark "$(( n*2 - 8 ))"; printf '\n'
    draw_waves "$((n % 2))"
    n=$((n+1)); sleep 0.05
  done
  printf '%s' "${E}H"; printf '\n'
  draw_wheel 8; printf '\n'; draw_wordmark 99; printf '\n'; draw_waves 0
  printf '\n           %s%sSEAHELM%s   %s— at the helm of your fleet%s\n\n' "${E}1m" "${E}38;5;45m" "$R" "${E}2m" "$R"
  printf '%s' "${E}?25h"
  trap - INT TERM
}

# ============================================================================
# Themed progress bar: a foam wake fills as the download lands (◆ = the ship's
# prow, · = deep water); a small turning helm spins at the left. pct<0 = an
# indeterminate "sailing" bar for steps with no byte count.
# ============================================================================
BAR_W=30
SPIN='◐◓◑◒'
spin_char() { i=$(( $1 % 4 )); m=0; s=$SPIN
  while [ "$m" -lt "$i" ]; do s=${s#?}; m=$((m+1)); done; printf '%s' "${s%"${s#?}"}"; }

draw_bar() { # pct spinstep label
  pct=$1; sp=$2; label=$3; bar=""; i=0
  if [ "$pct" -lt 0 ]; then
    head=$(( sp % BAR_W ))
    while [ "$i" -lt "$BAR_W" ]; do
      if   [ "$i" -eq "$head" ]; then bar="${bar}${E}1m${E}38;5;228m◆"
      elif [ "$i" -lt "$head" ]; then bar="${bar}${E}38;5;38m≈"
      else bar="${bar}${E}38;5;24m·"; fi
      i=$((i+1)); done
  else
    fill=$(( pct * BAR_W / 100 )); [ "$fill" -gt "$BAR_W" ] && fill=$BAR_W
    while [ "$i" -lt "$BAR_W" ]; do
      if   [ "$i" -eq "$fill" ] && [ "$pct" -lt 100 ]; then bar="${bar}${E}1m${E}38;5;228m◆"
      elif [ "$i" -lt "$fill" ]; then
        d=$(( fill - i ))
        if [ "$d" -le 3 ]; then bar="${bar}${E}38;5;51m≈"; else bar="${bar}${E}38;5;38m≈"; fi
      else bar="${bar}${E}38;5;24m·"; fi
      i=$((i+1)); done
  fi
  if [ "$pct" -ge 100 ]; then
    printf '\r%s  %s⚓%s %s%s  %s✓%s  %s' "${E}K" "${E}38;5;45m" "$R" "$bar" "$R" "${E}1m${E}38;5;45m" "$R" "$label"
  else
    p=""; [ "$pct" -ge 0 ] && p="$pct%"
    printf '\r%s  %s%s%s %s%s  %s%4s%s  %s' "${E}K" "${E}38;5;214m" "$(spin_char "$sp")" "$R" "$bar" "$R" "${E}2m" "$p" "$R" "$label"
  fi
}

# Run `cmd…` in the background; animate `label` until it exits; return its status.
# `total` (bytes) + `watch` (growing file) drive a real percent when given.
run_with_bar() { # label total watch -- cmd...
  label=$1; total=$2; watch=$3; shift 3; [ "$1" = -- ] && shift
  "$@" & bgpid=$!
  if anim_ok; then
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    sp=0
    while kill -0 "$bgpid" 2>/dev/null; do
      if [ "$total" -gt 0 ] && [ -n "$watch" ]; then
        cur=$(wc -c < "$watch" 2>/dev/null || echo 0); cur=$(printf '%s' "$cur" | tr -d ' '); : "${cur:=0}"
        case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
        pct=$(( cur * 100 / total )); [ "$pct" -gt 99 ] && pct=99
        draw_bar "$pct" "$sp" "$label"
      else
        draw_bar -1 "$sp" "$label"
      fi
      sp=$((sp+1)); sleep 0.1
    done
  fi
  if wait "$bgpid"; then st=0; else st=$?; fi
  if anim_ok && [ "$st" -eq 0 ]; then draw_bar 100 0 "$label"; printf '\n'; fi
  return "$st"
}

# HEAD the (redirecting) URL and read the final Content-Length, or empty.
content_length() {
  curl -fsSLI "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1)=="content-length:"{v=$2} END{print v}'
}

TMP=$(mktemp -d /tmp/seahelm-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Resolve the latest tag in the background while the animation plays (GitHub
# redirects releases/latest to the tagged URL; read the tag from it).
if [ -z "$VERSION" ]; then
  ( curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||' >"$TMP/version" ) &
  vpid=$!
  seahelm_animation
  wait "$vpid" 2>/dev/null || true
  VERSION=$(cat "$TMP/version" 2>/dev/null || true)
  [ -n "$VERSION" ] || err "could not determine latest release"
else
  seahelm_animation
fi

ASSET="seahelm-macos-${ARCH}.zip"
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"

if [ -n "${SEAHELM_INSTALL_DIR:-}" ]; then
  DEST="$SEAHELM_INSTALL_DIR"
elif [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

# --- Download (real byte-count progress) ---
if anim_ok; then
  TOTAL=$(content_length "$URL")
  run_with_bar "Hauling in Seahelm $VERSION ($ARCH)" "$TOTAL" "$TMP/$ASSET" -- \
    curl -fsSL -o "$TMP/$ASSET" "$URL" || err "download failed: $URL"
else
  printf '==> Downloading Seahelm %s (%s)\n' "$VERSION" "$ARCH"
  curl -fSL --progress-bar -o "$TMP/$ASSET" "$URL" || err "download failed: $URL"
fi

# --- Unpack (indeterminate sailing bar) ---
if anim_ok; then
  run_with_bar "Unpacking" "" "" -- ditto -x -k "$TMP/$ASSET" "$TMP/unpacked" \
    || err "unpack failed"
else
  printf '==> Unpacking\n'
  ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
fi
# The bundle is capitalised (PRODUCT_NAME in project.yml), so match that exactly:
# on a case-sensitive volume a lowercase path fails to find it and the error above
# reads as a corrupt download.
[ -d "$TMP/unpacked/Seahelm.app" ] || err "archive did not contain Seahelm.app"

APP="$DEST/Seahelm.app"
# Installs before 2.0.16 landed as lowercase seahelm.app. A case-insensitive volume
# (the macOS default) resolves both to the same directory, but a case-sensitive one
# would keep the old bundle alongside the new one, so remove it by name too.
for OLD in "$APP" "$DEST/seahelm.app"; do
  [ -d "$OLD" ] || continue
  if pgrep -xq Seahelm 2>/dev/null; then
    printf '==> Note: Seahelm is running; the new version takes effect on next launch\n'
  fi
  rm -rf "$OLD"
done
mv "$TMP/unpacked/Seahelm.app" "$APP"

printf '  %s⚓%s  Moored %s%s%s in %s\n' "${E}38;5;45m" "$R" "${E}1m" "$VERSION" "$R" "$APP"
printf '     Launch with: open "%s"\n' "$APP"
