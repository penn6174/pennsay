#!/bin/bash
set -euo pipefail

osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "PennSay"
    tell menu "PennSay" of menu bar item 1 of menu bar 2
      get name of every menu item
    end tell
  end tell
end tell
APPLESCRIPT
