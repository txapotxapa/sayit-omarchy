
-- ---------------------------------------------------------------------------
-- Say It: local text-to-speech (https://github.com/txapotxapa/sayit-omarchy).
-- Same default shortcuts as the macOS app. Selection = highlighted text
-- (Wayland primary selection), so no copy is needed.
o.bind("CTRL + ALT + S", "Read selection aloud", "sayit selection")
o.bind("CTRL + ALT + V", "Read clipboard aloud", "sayit clipboard")
o.bind("CTRL + ALT + P", "Pause or resume speech", "sayit toggle")
o.bind("CTRL + ALT + X", "Stop speech", "sayit stop")
