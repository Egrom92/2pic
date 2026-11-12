#!/usr/bin/env python3
"""2pic server: receives errors and usage statistics from the 2pic app, keeps them in SQLite and sends
new errors to a Telegram bot. Python 3.9+, standard library only.

Commands:
  python3 twopic_server.py serve                 run the receiver and the notifier (systemd runs this)
  python3 twopic_server.py report [--days 7]     errors and usage in the terminal
  python3 twopic_server.py selfcheck             database writable? Telegram reachable? (sends a test message)

Settings come from the environment (systemd: EnvironmentFile):
  TWOPIC_TOKEN            required. The key the app sends: "Authorization: Bearer <key>"
  TWOPIC_DB               SQLite file                         (default /var/lib/twopic/twopic.db)
  TWOPIC_LISTEN           where to listen, host:port          (default 127.0.0.1:8787; HTTPS proxy in front)
  TELEGRAM_BOT_TOKEN      bot token from @BotFather           (without it errors are stored but not announced)
  TELEGRAM_CHAT_ID        chat to notify
  TELEGRAM_API            Bot API base                        (default https://api.telegram.org)
  TWOPIC_REPEAT_MINUTES   the same error is announced again at most this often (default 30)
  TWOPIC_RETENTION_DAYS   events and statistics older than this are deleted (default 180)

HTTP:
  POST …/v1/ingest   body: {"schema":1,"install":"…","app":{…},"system":{…},"sent_at":"…","events":[…]}
                     event: {"id","kind": session|error|warning|stats|test, "time", "level"?, "category"?,
                             "message"?, "context"?: [lines], "info"?: {…}, "stats"?: {…}}
                     200 {"ok":true,"accepted":N,"duplicates":M} · 400 bad body · 401 bad key · 413 too big · 429 slow down
  GET  …/v1/health   200 {"ok":true,"pending_alerts":N}
Paths are matched by their ending, so the app may be served under a prefix (https://host/2pic/v1/ingest).
"""
import argparse
import collections
import hmac
import json
import os
import re
import signal
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 2 * 1024 * 1024
MAX_EVENTS = 500
KINDS = {"session", "error", "warning", "stats", "test"}
RATE_REQUESTS, RATE_WINDOW = 120, 600          # per client (install or IP) per 10 minutes
NOTIFY_EVERY = int(os.environ.get("TWOPIC_NOTIFY_SECONDS", "15"))   # seconds between notifier passes
MESSAGES_PER_PASS = 10

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS installs (
  install TEXT PRIMARY KEY, first_seen TEXT, last_seen TEXT,
  version TEXT, build TEXT, macos TEXT, model TEXT, locale TEXT);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY, install TEXT, kind TEXT, time TEXT, received TEXT,
  level TEXT, category TEXT, message TEXT, context TEXT, info TEXT,
  version TEXT, build TEXT, notified INTEGER NOT NULL DEFAULT 1);
CREATE INDEX IF NOT EXISTS events_pending ON events(notified, received);
CREATE INDEX IF NOT EXISTS events_received ON events(received);
CREATE TABLE IF NOT EXISTS stats (
  install TEXT, day TEXT, time TEXT, data TEXT, PRIMARY KEY (install, day));
CREATE TABLE IF NOT EXISTS alerts (
  signature TEXT PRIMARY KEY, last_sent REAL, suppressed INTEGER NOT NULL DEFAULT 0);
"""


def env(name, default=None):
    v = os.environ.get(name, "").strip()
    return v if v else default


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"{now_iso()} {msg}", flush=True)


def connect(path):
    db = sqlite3.connect(path, timeout=15)
    db.row_factory = sqlite3.Row
    return db


def init_db(path):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    with connect(path) as db:
        db.executescript(SCHEMA)


def clip(v, n):
    if v is None:
        return None
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return s[:n]


# ---------------------------------------------------------------- receiving

class Limiter:
    """At most RATE_REQUESTS per RATE_WINDOW seconds per key."""

    def __init__(self):
        self.hits = collections.defaultdict(collections.deque)
        self.lock = threading.Lock()

    def allow(self, key):
        t = time.time()
        with self.lock:
            q = self.hits[key]
            while q and q[0] < t - RATE_WINDOW:
                q.popleft()
            if len(q) >= RATE_REQUESTS:
                return False
            q.append(t)
            return True


def store(db_path, payload):
    """Validates and stores one envelope. Returns (accepted, duplicates) or raises ValueError."""
    if not isinstance(payload, dict) or payload.get("schema") != 1:
        raise ValueError("schema must be 1")
    install = payload.get("install")
    events = payload.get("events")
    if not isinstance(install, str) or not (0 < len(install) <= 64):
        raise ValueError("install must be a short string")
    if not isinstance(events, list) or len(events) > MAX_EVENTS:
        raise ValueError(f"events must be a list of at most {MAX_EVENTS}")
    app = payload.get("app") if isinstance(payload.get("app"), dict) else {}
    system = payload.get("system") if isinstance(payload.get("system"), dict) else {}
    version, build = clip(app.get("version"), 40), clip(app.get("build"), 120)
    received = now_iso()
    accepted = duplicates = 0
    with connect(db_path) as db:
        db.execute(
            """INSERT INTO installs (install, first_seen, last_seen, version, build, macos, model, locale)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(install) DO UPDATE SET last_seen=excluded.last_seen, version=excluded.version,
                 build=excluded.build, macos=excluded.macos, model=excluded.model, locale=excluded.locale""",
            (install, received, received, version, build, clip(system.get("macos"), 120),
             clip(system.get("model"), 60), clip(system.get("locale"), 30)))
        for e in events:
            if not isinstance(e, dict) or not isinstance(e.get("id"), str) or e.get("kind") not in KINDS:
                raise ValueError("each event needs an id and a known kind")
            kind = e["kind"]
            t = clip(e.get("time"), 40) or received
            if kind == "stats":
                if not isinstance(e.get("stats"), dict):
                    raise ValueError("stats event without stats")
                db.execute("INSERT OR REPLACE INTO stats (install, day, time, data) VALUES (?,?,?,?)",
                           (install, t[:10], t, clip(e["stats"], 500_000)))
                accepted += 1
                continue
            context = e.get("context") if isinstance(e.get("context"), list) else None
            if context is not None:
                context = [str(x)[:1000] for x in context[-60:]]
            cur = db.execute(
                """INSERT OR IGNORE INTO events (id, install, kind, time, received, level, category, message,
                     context, info, version, build, notified) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (e["id"][:64], install, kind, t, received, clip(e.get("level"), 10), clip(e.get("category"), 40),
                 clip(e.get("message"), 8000), json.dumps(context, ensure_ascii=False) if context else None,
                 clip(e.get("info"), 4000), version, build,
                 0 if kind in ("error", "test") else 1))   # only errors and tests are announced
            if cur.rowcount:
                accepted += 1
            else:
                duplicates += 1
    return accepted, duplicates


class Handler(BaseHTTPRequestHandler):
    server_version = "twopic/1"
    db_path = token = None
    limiter = Limiter()

    def log_message(self, fmt, *args):   # bodies and keys never reach the log
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def client(self):
        return (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()

    def do_GET(self):
        if self.path.split("?")[0].rstrip("/").endswith("/v1/health"):
            with connect(self.db_path) as db:
                n = db.execute("SELECT COUNT(*) FROM events WHERE notified=0").fetchone()[0]
            return self.reply(200, {"ok": True, "pending_alerts": n})
        self.reply(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if not path.endswith("/v1/ingest"):
            return self.reply(404, {"ok": False, "error": "not found"})
        auth = self.headers.get("Authorization", "")
        given = auth[7:] if auth.startswith("Bearer ") else ""
        if not hmac.compare_digest(given.encode(), self.token.encode()):
            log(f"ingest from {self.client()}: bad key")
            return self.reply(401, {"ok": False, "error": "bad key"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            # Read (and drop) a moderately oversized body first, so the client gets a clean 413 instead of a reset.
            left = length if 0 < length <= 4 * MAX_BODY else 0
            while left > 0:
                chunk = self.rfile.read(min(65536, left))
                if not chunk:
                    break
                left -= len(chunk)
            self.close_connection = True
            return self.reply(413, {"ok": False, "error": f"body must be at most {MAX_BODY} bytes"})
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except ValueError:
            return self.reply(400, {"ok": False, "error": "not JSON"})
        key = payload.get("install") if isinstance(payload, dict) and isinstance(payload.get("install"), str) else self.client()
        if not self.limiter.allow(key):
            return self.reply(429, {"ok": False, "error": "too many requests"})
        try:
            accepted, duplicates = store(self.db_path, payload)
        except ValueError as e:
            log(f"ingest from {self.client()}: rejected ({e})")
            return self.reply(400, {"ok": False, "error": str(e)})
        kinds = collections.Counter(e.get("kind") for e in payload["events"])
        log(f"ingest {payload['install'][:8]}: {dict(kinds)} accepted {accepted}, duplicates {duplicates}")
        self.reply(200, {"ok": True, "accepted": accepted, "duplicates": duplicates})


# ---------------------------------------------------------------- notifying

def telegram(text):
    """Sends a message; True on success. Plain text, no markup: nothing in an error can break it."""
    tok, chat = env("TELEGRAM_BOT_TOKEN"), env("TELEGRAM_CHAT_ID")
    if not tok or not chat:
        return False
    url = f"{env('TELEGRAM_API', 'https://api.telegram.org').rstrip('/')}/bot{tok}/sendMessage"
    data = json.dumps({"chat_id": chat, "text": text[:3900], "disable_web_page_preview": True}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read()).get("ok", False)
    except (urllib.error.URLError, ValueError, OSError) as e:
        log(f"telegram: {getattr(e, 'code', '')} {e}")
        return False


def signature(category, message):
    """Same kind of error, whatever the numbers in it."""
    m = re.sub(r"0x[0-9a-fA-F]+|\d+", "#", message or "")
    return f"{category}|{m[:200]}"


def where(row):
    return f"{row['model'] or '?'} · 2pic {row['version'] or '?'} ({row['build'] or '?'}) · macOS {row['macos'] or '?'} · установка {row['install'][:8]}"


def context_tail(row, n=8):
    try:
        lines = json.loads(row["context"] or "[]")
    except ValueError:
        return ""
    # "2026-11-13 00:15:30.463 INFO  [scroll] text" → "00:15:30 INFO [scroll] text"
    out = []
    for line in lines[-n:]:
        m = re.match(r"\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d)\.\d+ (\w+)\s+(.*)", line)
        out.append(f"{m.group(1)} {m.group(2)} {m.group(3)}" if m else line)
    return "\n".join(x[:300] for x in out)


def notify_pass(db_path, repeat_minutes):
    """One pass: announce pending tests and errors, grouping repeats. Returns the number of messages sent."""
    if not env("TELEGRAM_BOT_TOKEN") or not env("TELEGRAM_CHAT_ID"):
        return 0
    sent = 0
    with connect(db_path) as db:
        rows = db.execute(
            """SELECT e.*, i.macos, i.model FROM events e LEFT JOIN installs i ON i.install = e.install
               WHERE e.notified = 0 ORDER BY e.received LIMIT 1000""").fetchall()
        groups = collections.OrderedDict()
        for r in rows:
            key = ("test", r["id"]) if r["kind"] == "test" else ("error", signature(r["category"], r["message"]))
            groups.setdefault(key, []).append(r)
        for (kind, sig), items in groups.items():
            if sent >= MESSAGES_PER_PASS:
                break
            first = items[0]
            ids = [r["id"] for r in items]
            if kind == "test":
                text = f"✅ 2pic на связи: тестовое событие получено\n{where(first)}"
            else:
                a = db.execute("SELECT last_sent, suppressed FROM alerts WHERE signature=?", (sig,)).fetchone()
                if a and time.time() - a["last_sent"] < repeat_minutes * 60:
                    # Announced recently: count it, say it with the next announcement.
                    db.execute("UPDATE alerts SET suppressed = suppressed + ? WHERE signature=?", (len(items), sig))
                    db.executemany("UPDATE events SET notified=1 WHERE id=?", [(i,) for i in ids])
                    continue
                crash = (first["category"] or "") == "crash" or "ended without quitting normally" in (first["message"] or "")
                head = "💥 2pic упал" if crash else f"🔴 Ошибка в 2pic [{first['category'] or '?'}]"
                text = f"{head}\n{(first['message'] or '')[:1500]}"
                extra = []
                if len(items) > 1:
                    extra.append(f"×{len(items)} подряд")
                if a and a["suppressed"]:
                    extra.append(f"ещё {a['suppressed']} повторов с прошлого уведомления")
                if extra:
                    text += "\n" + " · ".join(extra)
                text += f"\n{where(first)}"
                tail = context_tail(first)
                if tail:
                    text += f"\n\nПеред этим в журнале:\n{tail}"
            if not telegram(text):
                break   # Telegram is down or misconfigured: keep them pending, try next pass
            sent += 1
            db.executemany("UPDATE events SET notified=1 WHERE id=?", [(i,) for i in ids])
            if kind == "error":
                db.execute("""INSERT INTO alerts (signature, last_sent, suppressed) VALUES (?,?,0)
                              ON CONFLICT(signature) DO UPDATE SET last_sent=excluded.last_sent, suppressed=0""",
                           (sig, time.time()))
            db.commit()
            time.sleep(1.1)   # Telegram allows about one message a second per chat
    return sent


def cleanup(db_path, days):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect(db_path) as db:
        n = db.execute("DELETE FROM events WHERE received < ?", (cutoff,)).rowcount
        m = db.execute("DELETE FROM stats WHERE day < ?", (cutoff[:10],)).rowcount
    if n or m:
        log(f"cleanup: removed {n} events and {m} statistics snapshots older than {days} days")


def notifier_loop(db_path, stop):
    repeat = int(env("TWOPIC_REPEAT_MINUTES", "30"))
    days = int(env("TWOPIC_RETENTION_DAYS", "180"))
    last_cleanup = 0.0
    if not env("TELEGRAM_BOT_TOKEN") or not env("TELEGRAM_CHAT_ID"):
        log("notifier: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — errors are stored, not announced")
    while not stop.is_set():
        try:
            n = notify_pass(db_path, repeat)
            if n:
                log(f"notifier: sent {n} message(s)")
            if time.time() - last_cleanup > 3600:
                cleanup(db_path, days)
                last_cleanup = time.time()
        except Exception as e:   # the notifier must outlive any single bad pass
            log(f"notifier: {type(e).__name__}: {e}")
        stop.wait(NOTIFY_EVERY)


# ---------------------------------------------------------------- commands

def serve():
    token = env("TWOPIC_TOKEN")
    if not token or len(token) < 24:
        sys.exit("TWOPIC_TOKEN is missing or shorter than 24 characters")
    db_path = env("TWOPIC_DB", "/var/lib/twopic/twopic.db")
    init_db(db_path)
    host, _, port = env("TWOPIC_LISTEN", "127.0.0.1:8787").rpartition(":")
    Handler.db_path, Handler.token = db_path, token
    httpd = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    stop = threading.Event()
    threading.Thread(target=notifier_loop, args=(db_path, stop), daemon=True).start()

    def quit_(*_):
        stop.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, quit_)
    signal.signal(signal.SIGINT, quit_)
    log(f"listening on {host or '127.0.0.1'}:{port}, database {db_path}")
    httpd.serve_forever()
    log("stopped")


def report(days):
    db_path = env("TWOPIC_DB", "/var/lib/twopic/twopic.db")
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with connect(db_path) as db:
        installs = db.execute("SELECT * FROM installs ORDER BY last_seen DESC").fetchall()
        active = [i for i in installs if (i["last_seen"] or "") >= since]
        print(f"Установок: {len(installs)}, на связи за {days} дн.: {len(active)}")
        for i in active[:10]:
            print(f"  {i['install'][:8]}  {i['model'] or '?'}  2pic {i['version'] or '?'} ({i['build'] or '?'})  "
                  f"macOS {i['macos'] or '?'}  последний раз {i['last_seen']}")
        groups = {}
        for r in db.execute("SELECT category, message, received FROM events WHERE kind='error' AND received >= ? "
                            "ORDER BY received", (since,)):
            g = groups.setdefault(signature(r["category"], r["message"]), {"n": 0, "cat": r["category"]})
            g["n"] += 1
            g["last"], g["msg"] = r["received"], r["message"] or ""   # the latest example of this kind
        print(f"\nОшибки за {days} дн.: {sum(g['n'] for g in groups.values())} (одинаковые, кроме чисел, вместе)")
        for g in sorted(groups.values(), key=lambda g: -g["n"])[:20]:
            print(f"  {g['n']:4} × [{g['cat']}] {g['msg'][:110]}   (последняя {g['last']})")
        w = db.execute("SELECT COUNT(*) FROM events WHERE kind='warning' AND received >= ?", (since,)).fetchone()[0]
        print(f"Предупреждений за {days} дн.: {w}")
        total = collections.Counter()
        for r in db.execute("""SELECT s.data FROM stats s JOIN (SELECT install, MAX(day) d FROM stats GROUP BY install) l
                               ON l.install = s.install AND l.d = s.day"""):
            try:
                total.update(json.loads(r["data"]).get("counts", {}))
            except ValueError:
                pass
        if total:
            print("\nИспользование (последний снимок каждой установки, сумма):")
            for k, v in sorted(total.items(), key=lambda kv: (-kv[1], kv[0]))[:40]:
                print(f"  {v:6}  {k}")


def selfcheck():
    db_path = env("TWOPIC_DB", "/var/lib/twopic/twopic.db")
    init_db(db_path)
    with connect(db_path) as db:
        db.execute("SELECT 1").fetchone()
    print(f"database OK: {db_path}")
    if not env("TWOPIC_TOKEN"):
        print("TWOPIC_TOKEN is NOT set")
    if not env("TELEGRAM_BOT_TOKEN") or not env("TELEGRAM_CHAT_ID"):
        sys.exit("TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set: notifications are off")
    ok = telegram("✅ Сервер 2pic: уведомления работают")
    print("telegram OK: test message sent" if ok else "telegram FAILED: check the bot token and chat id")
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    r = sub.add_parser("report")
    r.add_argument("--days", type=int, default=7)
    sub.add_parser("selfcheck")
    a = p.parse_args()
    if a.cmd == "serve":
        serve()
    elif a.cmd == "report":
        report(a.days)
    else:
        selfcheck()


if __name__ == "__main__":
    main()
