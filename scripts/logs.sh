#!/bin/bash
set -euo pipefail

LOG_FILE="$HOME/Library/Logs/DoubaoMurmur/voiceinput.log"

if [[ "${1:-}" == "--open" ]]; then
  open "$HOME/Library/Logs/DoubaoMurmur"
  exit 0
fi

tail -n 200 -f "$LOG_FILE"
