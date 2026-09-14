# Notes for coding agents

Say It for Omarchy: a local text-to-speech daemon, CLI and Omarchy bar player.

## Layout

- `sayitd.py`: the daemon (systemd user service). Model, queue, audio, state file.
  Runs in the uv-managed Python 3.12 venv at `~/.local/share/sayit/venv`.
- `sayit`: the CLI. Standard library only, runs on the system Python, talks to the
  daemon over `$XDG_RUNTIME_DIR/sayit.sock` (one JSON request per connection).
- `omarchy/sayit.player/`: the Quickshell bar widget. It reads
  `$XDG_RUNTIME_DIR/sayit-state.json`, which the daemon rewrites on every change.
- `skill/SKILL.md`: the agent narration skill. `hypr/bindings.lua`: the hotkeys.
- `install.sh` / `uninstall.sh`: idempotent, no sudo; `systemd/sayit.service.in` is templated.

## Checks

    ~/.local/share/sayit/venv/bin/python -m unittest discover -s tests
    python3 -m py_compile sayit sayitd.py
    bash -n install.sh uninstall.sh

After editing the daemon: `sayit service restart`. After editing the widget:
`omarchy restart shell` (a running bar keeps its cached QML otherwise).

## Conventions

- `sayit TEXT` must keep returning immediately; the agent skill relies on it.
- Keep the state file small and rewrite it only on changes; the widget has no polling.
- Never edit files under `/usr/share/omarchy`; user config lives in `~/.config`.
