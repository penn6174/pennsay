#!/bin/bash
set -euo pipefail

osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "VoiceInput"
    tell menu "VoiceInput" of menu bar item 1 of menu bar 2
      get name of every menu item
    end tell
  end tell
end tell
APPLESCRIPT
