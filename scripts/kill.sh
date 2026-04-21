#!/bin/bash
set -euo pipefail

pkill -f "/VoiceInput.app/Contents/MacOS/VoiceInput" || true
