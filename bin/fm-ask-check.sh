#!/usr/bin/env bash
# Stop hook: every captain ask in the final message has a register record (bin/fm-ask-check.py).
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
exec python3 "$(cd "$(dirname "$0")" && pwd)/fm-ask-check.py"
