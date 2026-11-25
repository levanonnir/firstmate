#!/usr/bin/env bash
# Captain ask register: see bin/fm-ask.py (fm-ask.sh --help).
exec python3 "$(cd "$(dirname "$0")" && pwd)/fm-ask.py" "$@"
