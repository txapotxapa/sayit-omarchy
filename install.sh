#!/usr/bin/env bash
# Install Say It for Omarchy / Linux from this checkout.
#
#   ./install.sh            everything (Omarchy bar player + hotkeys if Omarchy is found)
#   ./install.sh --no-bar   skip the Omarchy bar player
#   ./install.sh --no-keys  skip the Hyprland hotkeys
#
# Re-running is safe: it updates links and files in place and skips anything
# already done. Nothing is installed system-wide and nothing needs sudo.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/sayit
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
VENV=$DATA/venv
MODELS=$DATA/models
BIN=$HOME/.local/bin
MODEL_URL=https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0
MODEL_SHA=7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5
VOICES_SHA=bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d
PLUGIN=sayit.player

bar=1 keys=1
for arg in "$@"; do
  case $arg in
    --no-bar) bar=0 ;;
    --no-keys) keys=0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# ---- prerequisites --------------------------------------------------------
missing=()
command -v uv >/dev/null || missing+=(uv)
command -v wl-paste >/dev/null || missing+=(wl-clipboard)
command -v notify-send >/dev/null || missing+=(libnotify)
[[ $(ldconfig -p 2>/dev/null) == *libportaudio* ]] || missing+=(portaudio)
command -v systemctl >/dev/null || { echo "systemd (user services) is required" >&2; exit 1; }
if ((${#missing[@]})); then
  warn "missing: ${missing[*]}"
  if command -v pacman >/dev/null; then
    warn "install them with: sudo pacman -S --needed ${missing[*]}"
  fi
  exit 1
fi

# ---- Python environment ---------------------------------------------------
# kokoro-onnx does not support Python 3.14 yet, so uv provides a 3.12.
if [[ ! -x $VENV/bin/python ]]; then
  say "creating Python 3.12 environment in $VENV"
  uv venv --quiet --python 3.12 "$VENV"
fi
say "installing kokoro-onnx"
uv pip install --quiet --python "$VENV/bin/python" kokoro-onnx sounddevice soundfile

# ---- model ----------------------------------------------------------------
mkdir -p "$MODELS"
fetch() {  # fetch FILE SHA256
  local file=$1 sum=$2
  if [[ -f $MODELS/$file ]] && echo "$sum  $MODELS/$file" | sha256sum --quiet -c 2>/dev/null; then
    return
  fi
  say "downloading $file"
  curl -fL --progress-bar -o "$MODELS/$file.part" "$MODEL_URL/$file"
  echo "$sum  $MODELS/$file.part" | sha256sum --quiet -c
  mv "$MODELS/$file.part" "$MODELS/$file"
}
fetch kokoro-v1.0.onnx "$MODEL_SHA"
fetch voices-v1.0.bin "$VOICES_SHA"

# ---- CLI + service --------------------------------------------------------
mkdir -p "$BIN" "$CONFIG/systemd/user"
chmod +x "$SRC/sayit" "$SRC/sayitd.py"
ln -sfn "$SRC/sayit" "$BIN/sayit"
sed -e "s|@VENV@|$VENV|g" -e "s|@SRC@|$SRC|g" "$SRC/systemd/sayit.service.in" \
  > "$CONFIG/systemd/user/sayit.service"
systemctl --user daemon-reload
systemctl --user enable --quiet sayit.service
systemctl --user restart sayit.service
say "service running; try: sayit \"Hello from Say It\""
case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not on your PATH" ;; esac

# ---- coding-agent skill ---------------------------------------------------
if [[ -d $HOME/.claude ]]; then
  mkdir -p "$HOME/.claude/skills"
  ln -sfn "$SRC/skill" "$HOME/.claude/skills/sayit"
  say "Claude Code skill linked (say \"use sayit\" to an agent)"
fi

# ---- Omarchy: bar player + hotkeys ----------------------------------------
if command -v omarchy >/dev/null; then
  if ((bar)); then
    mkdir -p "$CONFIG/omarchy/plugins"
    ln -sfn "$SRC/omarchy/$PLUGIN" "$CONFIG/omarchy/plugins/$PLUGIN"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    if grep -q "\"$PLUGIN\"" "$CONFIG/omarchy/shell.json" 2>/dev/null; then
      say "bar player already on the bar"
    elif omarchy bar put "$PLUGIN" --before omarchy.tray >/dev/null 2>&1 \
      || omarchy bar put "$PLUGIN" >/dev/null 2>&1; then
      say "bar player added (click the speech icon in the bar)"
    else
      warn "could not add the bar player; run: omarchy bar put $PLUGIN"
    fi
  fi
  bindings=$CONFIG/hypr/bindings.lua
  if ((keys)) && [[ -f $bindings ]]; then
    if grep -q 'sayit selection' "$bindings"; then
      say "hotkeys already present in $bindings"
    else
      cp "$bindings" "$bindings.bak.$(date +%s)"
      cat "$SRC/hypr/bindings.lua" >> "$bindings"
      hyprctl reload >/dev/null 2>&1 || true
      say "hotkeys added: Ctrl+Alt+S selection, Ctrl+Alt+V clipboard, Ctrl+Alt+P pause, Ctrl+Alt+X stop"
    fi
  fi
else
  say "not on Omarchy: bind 'sayit selection' / 'sayit clipboard' to keys in your compositor"
fi
