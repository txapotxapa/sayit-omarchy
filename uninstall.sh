#!/usr/bin/env bash
# Remove Say It for Omarchy / Linux. Keeps the downloaded model unless --purge is given.
set -uo pipefail

DATA=${XDG_DATA_HOME:-$HOME/.local/share}/sayit
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
PLUGIN=sayit.player

systemctl --user disable --now sayit.service 2>/dev/null
rm -f "$CONFIG/systemd/user/sayit.service"
systemctl --user daemon-reload
rm -f "$HOME/.local/bin/sayit"
[[ -L $HOME/.claude/skills/sayit ]] && rm -f "$HOME/.claude/skills/sayit"
if [[ -L $CONFIG/omarchy/plugins/$PLUGIN ]]; then
  rm -f "$CONFIG/omarchy/plugins/$PLUGIN"
  echo "remove \"$PLUGIN\" from the bar layout in $CONFIG/omarchy/shell.json if it is still listed"
fi
if grep -q 'sayit selection' "$CONFIG/hypr/bindings.lua" 2>/dev/null; then
  echo "the Say It hotkeys are still in $CONFIG/hypr/bindings.lua; delete that block by hand"
fi
if [[ ${1:-} == --purge ]]; then
  rm -rf "$DATA" "$CONFIG/sayit" "${XDG_STATE_HOME:-$HOME/.local/state}/sayit"
  echo "removed model, settings and history"
fi
echo "Say It removed"
