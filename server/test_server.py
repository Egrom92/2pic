#!/usr/bin/env python3
"""End-to-end check of twopic_server.py: a real server process, a fake Telegram, real HTTP requests.
Run: python3 server/test_server.py   (standard library only; uses a temporary database)"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "test-key-" + "x" * 30
failures = 0


def check(ok, what):
    global failures
    print(("OK    " if ok else "FAIL  ") + what, flush=True)
    failures += 0 if ok else 1


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class FakeTelegram(BaseHTTPRequestHandler):
    messages, healthy = [], True

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if not FakeTelegram.healthy:
            self.send_response(502); self.end_headers(); return
        FakeTelegram.messages.append(body)
        out = json.dumps({"ok": True}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)


def post(url, payload, token=TOKEN, raw=None):
    data = raw if raw is not None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
    except urllib.error.URLError as e:   # the server may answer 413 and close before the client is done sending
        return (413 if isinstance(e.reason, ConnectionResetError) else 0), {}


def envelope(events, install="install-A"):
    return {"schema": 1, "install": install, "app": {"version": "1.1", "build": "abc1234, built 2026-11-13"},
            "system": {"macos": "Version 26.5.1", "model": "Mac17,2", "locale": "ru-EE"},
            "sent_at": "2026-11-13T00:00:00Z", "events": events}


def ev(i, kind, **kw):
    return dict({"id": f"ev-{i}", "kind": kind, "time": "2026-11-13T00:00:00Z"}, **kw)


def wait_for(cond, seconds=8):
    end = time.time() + seconds
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.2)
    return cond()


def main():
    tg_port, port = free_port(), free_port()
    tg = ThreadingHTTPServer(("127.0.0.1", tg_port), FakeTelegram)
    threading.Thread(target=tg.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="twopic-test-")
    db = os.path.join(tmp, "data", "twopic.db")
    environ = dict(os.environ, TWOPIC_TOKEN=TOKEN, TWOPIC_DB=db, TWOPIC_LISTEN=f"127.0.0.1:{port}",
                   TELEGRAM_BOT_TOKEN="123:fake", TELEGRAM_CHAT_ID="42", TELEGRAM_API=f"http://127.0.0.1:{tg_port}",
                   TWOPIC_NOTIFY_SECONDS="1", TWOPIC_REPEAT_MINUTES="30")
    srv = subprocess.Popen([sys.executable, os.path.join(HERE, "twopic_server.py"), "serve"], env=environ,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    base = f"http://127.0.0.1:{port}"
    try:
        check(wait_for(lambda: _up(base)), "the server starts and answers /v1/health")
        ingest = base + "/v1/ingest"

        code, _ = post(ingest, envelope([ev(0, "test")]), token="wrong")
        check(code == 401, "a wrong key is refused (401)")
        code, _ = post(ingest, None, raw=b"{not json")
        check(code == 400, "a body that isn't JSON is refused (400)")
        code, _ = post(ingest, {"schema": 1, "install": "x", "events": [{"kind": "error"}]})
        check(code == 400, "an event without an id is refused (400)")
        code, _ = post(ingest, None, raw=b"x" * (2 * 1024 * 1024 + 10))
        check(code == 413, "a body over 2 MB is refused (413 / connection closed)")

        context = [f"2026-11-13 00:15:{i:02d}.000 INFO  [scroll] frame {i}: appended" for i in range(30)]
        batch = [
            ev(1, "session", info={"screens": "1800×1169 @2x"}),
            ev(2, "warning", level="WARN", category="telemetry", message="slow"),
            ev(3, "stats", stats={"since": "2026-11-13T00:00:00Z", "counts": {"finish.copy": 5, "mark.arrow": 3}}),
            ev(4, "test", message="ping"),
            ev(5, "error", level="ERROR", category="scroll", message="stopped early, frame 4: score 0.41", context=context),
            ev(6, "error", level="ERROR", category="scroll", message="stopped early, frame 7: score 0.38", context=context),
            ev(7, "error", level="ERROR", category="scroll", message="stopped early, frame 9: score 0.12", context=context),
        ]
        code, r = post(ingest, envelope(batch))
        check(code == 200 and r.get("accepted") == 7, f"a batch is stored (accepted {r.get('accepted')})")
        code, r = post(ingest, envelope(batch))
        check(code == 200 and r.get("duplicates") == 6, f"the same batch again is not stored twice (duplicates {r.get('duplicates')})")

        check(wait_for(lambda: len(FakeTelegram.messages) >= 2), "the bot gets messages")
        texts = [m["text"] for m in FakeTelegram.messages]
        check(sum("✅ 2pic на связи" in t for t in texts) == 1, "the test event is announced once")
        err = [t for t in texts if "Ошибка в 2pic [scroll]" in t]
        check(len(err) == 1 and "×3 подряд" in err[0], "three errors of one kind make one message «×3»")
        check(err and "Mac17,2" in err[0] and "2pic 1.1" in err[0] and "00:15:29 INFO [scroll] frame 29" in err[0],
              "the message says where (Mac, version) and shows the log lines before the error")
        check(not any("slow" in t for t in texts), "warnings are stored but not announced")
        check(all(m["chat_id"] == "42" for m in FakeTelegram.messages), "messages go to the configured chat")

        n = len(FakeTelegram.messages)
        post(ingest, envelope([ev(8, "error", level="ERROR", category="scroll", message="stopped early, frame 2: score 0.3")]))
        time.sleep(2.5)
        check(len(FakeTelegram.messages) == n, "the same error again within 30 min is held back, not repeated")

        code, _ = post(base + "/2pic/v1/ingest", envelope([ev(9, "error", level="ERROR", category="crash",
                       message="2pic-2026-11-13-010203.ips: EXC_CRASH SIGABRT; NSInternalInconsistencyException")]))
        check(code == 200, "the receiver also works under a path prefix (/2pic/v1/ingest)")
        check(wait_for(lambda: any("💥 2pic упал" in m["text"] for m in FakeTelegram.messages)), "a crash is announced as a crash")

        FakeTelegram.healthy = False
        post(ingest, envelope([ev(10, "error", level="ERROR", category="output", message="save failed")]))
        time.sleep(2.5)
        check(not any("save failed" in m["text"] for m in FakeTelegram.messages), "(Telegram down: nothing delivered yet)")
        FakeTelegram.healthy = True
        check(wait_for(lambda: any("save failed" in m["text"] for m in FakeTelegram.messages)),
              "an error that couldn't be delivered is delivered once Telegram is back")

        with urllib.request.urlopen(base + "/v1/health") as r:
            check(json.loads(r.read()).get("pending_alerts") == 0, "nothing is left pending")

        if "--app" in sys.argv:   # the real 2pic (a debug build) sending to this server
            app = sys.argv[sys.argv.index("--app") + 1]
            before = len(FakeTelegram.messages)
            out = subprocess.run([app, "--selftest", "telemetry", base + "/2pic", TOKEN], capture_output=True, text=True,
                                 timeout=120).stderr
            print(out)
            check("ALL TELEMETRY CHECKS OK" in out, "the app's sending checks pass")
            import sqlite3
            con = sqlite3.connect(db)
            kinds = dict(con.execute("SELECT kind, COUNT(*) FROM events WHERE install != 'install-A' GROUP BY kind").fetchall())
            ctx = con.execute("SELECT context FROM events WHERE message LIKE '%(selftest)%' AND kind='error' LIMIT 1").fetchone()
            stats = con.execute("SELECT data FROM stats WHERE install != 'install-A'").fetchone()
            con.close()
            check(kinds.get("session", 0) >= 1 and kinds.get("test", 0) >= 1 and kinds.get("error", 0) >= 2,
                  f"the server stored what the app sent: {kinds}")
            check(ctx is not None and "frame 3: appended" in ctx[0], "an app error arrives with the log lines before it")
            check(stats is not None and json.loads(stats[0])["counts"].get("finish.copy") == 2, "the app's statistics arrive")
            check(wait_for(lambda: any("(selftest)" in m["text"] for m in FakeTelegram.messages[before:])),
                  "the app's error reaches the bot")
        out = subprocess.run([sys.executable, os.path.join(HERE, "twopic_server.py"), "report"], env=environ,
                             capture_output=True, text=True).stdout
        installs = 2 if "--app" in sys.argv else 1
        check(f"Установок: {installs}" in out and "[scroll]" in out and "finish.copy" in out,
              "`report` shows installs, errors and usage")
        print("\n--- report ---\n" + out)
    finally:
        srv.terminate()
        log = srv.communicate(timeout=10)[0]
        tg.shutdown()
    check(TOKEN not in log and "stopped" in log, "the server log never contains the key, and it stops cleanly on SIGTERM")
    print("--- server log ---\n" + log)
    print("ALL SERVER CHECKS OK" if failures == 0 else f"{failures} SERVER CHECK(S) FAILED")
    sys.exit(1 if failures else 0)


def _up(base):
    try:
        with urllib.request.urlopen(base + "/v1/health", timeout=1) as r:
            return r.status == 200
    except OSError:
        return False


if __name__ == "__main__":
    main()
