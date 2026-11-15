#!/usr/bin/env python3
"""The captain ask register: one durable record for every question, approval, review or merge First Mate puts to
the captain. Bridge (and through it Helm and the companion app) shows exactly these records, so what First Mate says
is waiting on the captain and what the captain's screens show are the same list.

Records live in state/captain-asks.jsonl as append-only events (open / answer / close); the latest event per key wins.

  fm-ask.sh open  <key> --type merge|decide|review|do --q "Question?" [--option "Label|What it does"]...
                  [--recommended N] [--link URL]... [--pr URL] [--task ID] [--order N] [--blocker "text"] [--repo R]
                  Re-opening an existing key updates it (same card).
  fm-ask.sh answer <key> "what the captain said"     the captain answered; the record stays open until you act
  fm-ask.sh close  <key> [--dropped] [--note "text"]  done (acted on, merged, no longer needed) - leaves every screen
  fm-ask.sh list   [--json] [--all]                   open asks (merges first, in order); --all adds answered ones
  fm-ask.sh stale  [--days 5]                         open asks older than N days ("still needed?")
  fm-ask.sh find   <text>                             open asks whose key, question, links or PR contain text

Keys are short, stable and unique per ask: pr-877-renumber, merge-petit-core-2211, decide-2078-name-field.
"""
import argparse, calendar, json, os, sys, time, fcntl

HOME = os.environ.get("FM_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILE = os.path.join(HOME, "state", "captain-asks.jsonl")
TYPES = ("merge", "decide", "review", "do")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load():
    asks = {}
    try:
        with open(FILE, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                k = e.get("key")
                if not k:
                    continue
                if e.get("op") == "open":
                    prev = asks.get(k)
                    rec = {kk: v for kk, v in e.items() if kk not in ("op", "v")}
                    rec["opened"] = prev["opened"] if prev and prev.get("state") != "closed" else e.get("ts")
                    rec["state"] = "open"
                    rec["answer"] = None
                    asks[k] = rec
                elif k in asks and e.get("op") == "answer":
                    asks[k].update(state="answered", answer=e.get("answer"), answered=e.get("ts"))
                elif k in asks and e.get("op") == "close":
                    asks[k].update(state="closed", outcome=e.get("outcome"), closed=e.get("ts"), note=e.get("note"))
    except FileNotFoundError:
        pass
    return asks


def append(event):
    os.makedirs(os.path.dirname(FILE), exist_ok=True)
    event = {"v": 1, "ts": now(), **event}
    with open(FILE, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
    return event


def ordered(asks):
    rank = {"merge": 0, "decide": 1, "review": 2, "do": 3}
    return sorted(asks, key=lambda a: (rank.get(a.get("type"), 9), a.get("order") if a.get("order") is not None else 9999, a.get("opened") or ""))


def show(a):
    bits = [f"[{a.get('type')}] {a['key']}: {a.get('q')}"]
    if a.get("blocker"):
        bits.append(f"   blocker: {a['blocker']}")
    for o in a.get("options") or []:
        bits.append(f"   - {o.get('label')}" + (f" ({o.get('does')})" if o.get("does") else ""))
    for u in ([a.get("pr")] if a.get("pr") else []) + (a.get("links") or []):
        bits.append(f"   {u}")
    if a.get("state") == "answered":
        bits.append(f"   ANSWERED: {a.get('answer')}  -> act on it, then: fm-ask.sh close {a['key']}")
    return "\n".join(bits)


def main():
    p = argparse.ArgumentParser(prog="fm-ask.sh", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("open"); o.add_argument("key")
    o.add_argument("--type", choices=TYPES, required=True); o.add_argument("--q", required=True)
    o.add_argument("--option", action="append", default=[]); o.add_argument("--recommended", type=int)
    o.add_argument("--link", action="append", default=[]); o.add_argument("--pr"); o.add_argument("--task")
    o.add_argument("--order", type=int); o.add_argument("--blocker"); o.add_argument("--repo")
    a = sub.add_parser("answer"); a.add_argument("key"); a.add_argument("answer")
    c = sub.add_parser("close"); c.add_argument("key"); c.add_argument("--dropped", action="store_true"); c.add_argument("--note")
    l = sub.add_parser("list"); l.add_argument("--json", action="store_true"); l.add_argument("--all", action="store_true")
    s = sub.add_parser("stale"); s.add_argument("--days", type=float, default=5)
    f = sub.add_parser("find"); f.add_argument("text")
    args = p.parse_args()
    asks = load()

    if args.cmd == "open":
        key = args.key.strip()
        if not key or len(key) > 80 or any(ch.isspace() for ch in key):
            sys.exit("fm-ask: a key is one short word-like id (no spaces)")
        opts = []
        for raw in args.option[:4]:
            label, _, does = raw.partition("|")
            opts.append({"label": label.strip()[:60], "does": does.strip()[:160]})
        ev = {"op": "open", "key": key, "type": args.type, "q": args.q.strip()[:600], "options": opts,
              "recommended": args.recommended, "links": args.link[:6], "pr": args.pr, "task": args.task,
              "order": args.order, "blocker": args.blocker, "repo": args.repo}
        append({k: v for k, v in ev.items() if v not in (None, [], "")})
        print(f"ask {'updated' if key in asks and asks[key]['state'] != 'closed' else 'opened'}: {key}")
    elif args.cmd == "answer":
        if args.key not in asks or asks[args.key]["state"] == "closed":
            sys.exit(f"fm-ask: no open ask {args.key}")
        append({"op": "answer", "key": args.key, "answer": args.answer.strip()[:1000]})
        print(f"answer recorded: {args.key}")
    elif args.cmd == "close":
        if args.key not in asks or asks[args.key]["state"] == "closed":
            sys.exit(f"fm-ask: no open ask {args.key}")
        append({"op": "close", "key": args.key, "outcome": "dropped" if args.dropped else "done", **({"note": args.note[:300]} if args.note else {})})
        print(f"closed: {args.key}")
    elif args.cmd == "list":
        rows = ordered([x for x in asks.values() if x["state"] == "open" or (args.all and x["state"] == "answered")])
        if args.json:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
        else:
            answered = [x for x in asks.values() if x["state"] == "answered"]
            print(f"{len([x for x in asks.values() if x['state'] == 'open'])} open, {len(answered)} answered and waiting for you to act")
            for x in rows:
                print(show(x))
    elif args.cmd == "stale":
        cut = time.time() - args.days * 86400
        for x in ordered([x for x in asks.values() if x["state"] == "open"]):
            t = calendar.timegm(time.strptime(x.get("opened") or x["ts"], "%Y-%m-%dT%H:%M:%SZ"))
            if t < cut:
                print(show(x))
    elif args.cmd == "find":
        t = args.text.lower()
        for x in asks.values():
            if x["state"] != "closed" and t in json.dumps(x, ensure_ascii=False).lower():
                print(show(x))


if __name__ == "__main__":
    main()
