#!/usr/bin/env python3
"""Turn-end check for the captain ask register (bin/fm-ask.py). Runs from the primary session's Stop hook.

It reads First Mate's final message of the turn, picks out what it asks of the captain (the bullets under
"Waiting on you" / "Ready to merge" style headings, and question lines), and checks that each one has an open record in
state/captain-asks.jsonl. Anything unfiled blocks the turn end once, with the list and the command to file it, so the
captain's screens (Bridge, Helm, the companion) never miss an ask that is only in chat. It never blocks twice in a row
(stop_hook_active), never in a crew or scout worktree, and steps aside on any error.
"""
import json, os, re, subprocess, sys

HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEAD = re.compile(r"(waiting on you|waiting for you|needs? (your|the captain)|ready to merge|on your word|your (call|decision|review|approval|word)s?|decisions? (for you|needed|pending)|open (asks|questions))", re.I)
ID = re.compile(r"https?://\S+|#\d{2,6}\b|\b(?:PR|issue|task|pull)\s*#?\d{2,6}\b", re.I)
NUM = re.compile(r"\d{2,6}")
STOP = set("the a an and or to of for in on at is are be it this that with your you from as by now first then which whether".split())


def primary():
    try:
        gd = subprocess.run(["git", "-C", HOME, "rev-parse", "--git-dir", "--git-common-dir"], capture_output=True, text=True, timeout=5).stdout.split()
        return len(gd) == 2 and os.path.realpath(os.path.join(HOME, gd[0])) == os.path.realpath(os.path.join(HOME, gd[1])) and os.path.isdir(os.path.join(HOME, "state"))
    except Exception:
        return False


def final_message(path):
    texts = []
    with open(path, encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    for line in reversed(lines[-400:]):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        m = e.get("message") or {}
        if e.get("type") == "user" and isinstance(m.get("content"), str):
            break  # the captain's prompt: the turn started here
        if e.get("type") == "user" and isinstance(m.get("content"), list) and any(c.get("type") == "text" for c in m["content"] if isinstance(c, dict)):
            break
        if e.get("type") == "assistant":
            parts = [c.get("text", "") for c in m.get("content") or [] if isinstance(c, dict) and c.get("type") == "text"]
            if parts:
                texts.append("\n".join(parts))
                break  # the last text block of the turn is the final message
    return texts[0] if texts else ""


def candidates(msg):
    out, under = [], False
    for raw in msg.splitlines():
        line = raw.strip()
        if not line:
            continue
        bullet = re.match(r"^([-*•]|\d+[.)])\s+(.*)", line)
        if not bullet:
            under = bool(HEAD.search(line)) and len(line) < 120
            if not under and line.endswith("?") and len(line) > 12 and not line.startswith(("`", ">")):
                out.append(line)
            continue
        text = bullet.group(2)
        if under or text.rstrip().endswith("?"):
            out.append(text)
    return out


def content(a):
    vals = [a.get(k) for k in ("key", "q", "pr", "task", "blocker", "hold", "reason")]
    vals += a.get("links") or []
    vals += [v for o in a.get("options") or [] if isinstance(o, dict) for v in (o.get("label"), o.get("does"))]
    return " ".join(str(v) for v in vals if v).lower()


def has(text, token):
    lead = r"(?<!\d)" if token.isdigit() else r"(?<!\w)"
    return re.search(lead + re.escape(token) + r"(?!\w)", text) is not None


def covered(item, asks):
    blob = [content(a) for a in asks]
    ids = [m.group(0).lower().rstrip("`>*]).,;:'\"") for m in ID.finditer(item)]
    if ids:
        for i in ids:
            keys = [i] if i.startswith("http") else NUM.findall(i)
            if any(any(has(b, k) for b in blob) for k in keys):
                return True
        return False
    words = [w for w in re.findall(r"[a-z][a-z0-9.-]{3,}", item.lower()) if w not in STOP]
    if not words:
        return True
    return any(sum(has(b, w) for w in words) >= max(2, len(words) // 2) for b in blob)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if payload.get("stop_hook_active") or not primary():
        return 0
    path = payload.get("transcript_path")
    if not path or not os.path.exists(path):
        return 0
    msg = final_message(path)
    items = candidates(msg)
    if not items:
        return 0
    try:
        out = subprocess.run([sys.executable, os.path.join(HOME, "bin", "fm-ask.py"), "list", "--json", "--all"], capture_output=True, text=True, timeout=10).stdout
        asks = json.loads(out or "[]")
    except Exception:
        return 0
    # Held backlog tasks already reach the captain (Bridge reads them): count them as records too.
    try:
        import base64
        for line in open(os.path.join(HOME, "data", "backlog.md"), encoding="utf-8"):
            if "hold-kind: captain" in line and line.lstrip().startswith("- [ ]"):
                m = re.search(r"\(hold: ([^)]*)\)", line)
                reason = m.group(1).strip() if m else ""
                if reason.startswith("fm-hold-v1:"):
                    reason = base64.b64decode(reason[len("fm-hold-v1:"):]).decode("utf-8", "ignore")
                title = re.sub(r"\s*\((?:[\w-]+:|since )[^)]*\)", "", line.strip()[len("- [ ]"):]).strip()
                asks.append({"hold": title, "reason": reason})
    except Exception:
        pass
    missing = [i for i in items if not covered(i, asks)]
    if not missing:
        return 0
    lines = "\n".join(f"  - {m[:200]}" for m in missing[:20])
    sys.stderr.write(
        "Your reply asks the captain for things that have no record in the captain ask register, so Bridge, Helm and "
        "the companion app will not show them:\n" + lines + "\n"
        "File each one with bin/fm-ask.sh open <key> --type merge|decide|review|do --q \"...\" (add --option, --pr, "
        "--link, --order, --blocker as they apply; see AGENTS.md section 9, Captain ask register), close any that are "
        "settled with bin/fm-ask.sh close <key>, then end the turn again. Do not repeat your reply to the captain.\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
