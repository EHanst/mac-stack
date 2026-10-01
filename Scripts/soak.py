#!/usr/bin/env python3
"""Soak test: three clients hammer a running Kororo while RSS and open files are sampled.

  python3 scripts/soak.py --minutes 5            # short run
  python3 scripts/soak.py --hours 24 --out ~/soak # the release run

Everything is isolated: a throwaway home directory, a local stub standing in for the cloud model,
a throwaway API token. Nothing touches your real settings, tokens or providers.

Clients (all continuous, ~1 request per second each):
  chat    MCP `chat` tool over the Unix socket (what an editor plugin does)
  stream  POST /v1/chat/completions with stream=true and a bearer token (what an OpenAI SDK does)
  mcp     MCP tools/list + list_models over a second socket connection (what an agent host does)

Pass = no client error rate above 1 %, app still alive, and RSS growth between the first and last
quarter of the run (after a warm-up) at most 5 %; file descriptors must not climb either.
Exit code 0 pass, 1 fail. Writes soak.csv (samples) and soak.json (summary) into --out.
"""
import argparse, datetime, hashlib, http.client, json, os, plistlib, secrets, shutil, signal
import statistics, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "/tmp/kororo-build/Build/Products/Debug/Kororo.app/Contents/MacOS/Kororo"
KORORO_MCP = os.path.join(ROOT, ".build/debug/kororo-mcp")
STUB_PORT, API_PORT = 18779, 18081


# ---- stub cloud model -------------------------------------------------------------------------
class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self): self._json({"data": [{"id": "stub-model"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if body.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            for t in ["Soak ", "test ", "reply."]:
                self.wfile.write(("data: " + json.dumps({"choices": [{"delta": {"content": t}}]}) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}}) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self._json({"choices": [{"message": {"content": "Soak test reply."}}],
                        "usage": {"prompt_tokens": 10, "completion_tokens": 3}})


# ---- clients ----------------------------------------------------------------------------------
class Counter:
    def __init__(self): self.ok = 0; self.err = 0; self.last_error = ""; self.lock = threading.Lock()
    def good(self):
        with self.lock: self.ok += 1
    def bad(self, e):
        with self.lock: self.err += 1; self.last_error = str(e)[:200]


class MCPSocket:
    def __init__(self, sock, name):
        self.p = subprocess.Popen([KORORO_MCP, "--socket", sock], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.n = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": name, "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def call(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line: raise RuntimeError("socket closed")
        r = json.loads(line)
        if "error" in r: raise RuntimeError(r["error"])
        return r["result"]

    def close(self): self.p.terminate()


def run_chat(sock, stop, c):
    m = MCPSocket(sock, "soak-chat")
    while not stop.is_set():
        try:
            r = m.call("tools/call", {"name": "chat", "arguments": {"prompt": "say hi", "maxTokens": 20}})
            if r.get("isError"): raise RuntimeError(r)
            c.good()
        except Exception as e:
            c.bad(e)
            if "closed" in str(e): break
        stop.wait(1)
    m.close()


def run_mcp(sock, stop, c):
    m = MCPSocket(sock, "soak-mcp")
    while not stop.is_set():
        try:
            m.call("tools/list", {})
            r = m.call("tools/call", {"name": "list_models", "arguments": {}})
            if r.get("isError"): raise RuntimeError(r)
            c.good()
        except Exception as e:
            c.bad(e)
            if "closed" in str(e): break
        stop.wait(1)
    m.close()


def api_model(token):
    h = http.client.HTTPConnection("127.0.0.1", API_PORT, timeout=30)
    h.request("GET", "/v1/models", headers={"Authorization": "Bearer " + token})
    ids = [m["id"] for m in json.loads(h.getresponse().read())["data"]]
    return next((i for i in ids if "stub" in i), ids[0])


def run_stream(token, stop, c):
    body = json.dumps({"model": api_model(token), "stream": True, "max_tokens": 20,
                       "messages": [{"role": "user", "content": "say hi"}]})
    while not stop.is_set():
        try:
            h = http.client.HTTPConnection("127.0.0.1", API_PORT, timeout=30)
            h.request("POST", "/v1/chat/completions", body,
                      {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            r = h.getresponse(); data = r.read().decode(); h.close()
            if r.status != 200 or "[DONE]" not in data: raise RuntimeError(f"{r.status} {data[:120]}")
            c.good()
        except Exception as e:
            c.bad(e)
        stop.wait(1)


# ---- sampling ---------------------------------------------------------------------------------
def rss_kb(pid):
    return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0)


def fd_count(pid):
    out = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.splitlines()) - 1)


def summarize(samples, warmup_frac=0.1):
    body = samples[int(len(samples) * warmup_frac):]
    q = max(1, len(body) // 4)
    first = statistics.median(s["rss_kb"] for s in body[:q])
    last = statistics.median(s["rss_kb"] for s in body[-q:])
    fd_first = statistics.median(s["fds"] for s in body[:q])
    fd_last = statistics.median(s["fds"] for s in body[-q:])
    return {"rss_first_quarter_kb": first, "rss_last_quarter_kb": last,
            "rss_growth_pct": round((last - first) / first * 100, 2) if first else 0,
            "rss_peak_kb": max(s["rss_kb"] for s in samples),
            "fds_first_quarter": fd_first, "fds_last_quarter": fd_last}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=0)
    ap.add_argument("--hours", type=float, default=0)
    ap.add_argument("--interval", type=float, default=10, help="seconds between samples")
    ap.add_argument("--out", default=".")
    ap.add_argument("--max-growth-pct", type=float, default=5.0)
    a = ap.parse_args()
    seconds = a.hours * 3600 + a.minutes * 60
    if seconds <= 0: ap.error("give --minutes or --hours")
    for path in (APP, KORORO_MCP):
        if not os.path.exists(path): sys.exit(f"missing {path} - build it first (see the run-kororo skill / swift build)")
    os.makedirs(a.out, exist_ok=True)

    home = tempfile.mkdtemp(prefix="kororosoak-")
    token = "vc_" + secrets.token_urlsafe(32)
    support = f"{home}/Library/Application Support/VibeCockpit"
    os.makedirs(support); os.makedirs(f"{home}/Library/Preferences"); os.makedirs(f"{home}/.config/vibecockpit")
    json.dump([{"id": "stubcloud", "baseURL": f"http://127.0.0.1:{STUB_PORT}/v1", "modelIdentifier": "stub-model",
                "capabilities": 9, "apiStyle": "openAIChat", "envVarKey": "KORORO_STUBCLOUD_TOKEN"}],
              open(f"{home}/.config/vibecockpit/providers.json", "w"))
    plistlib.dump({"routingPolicy": "localFirst", "apiSharingEnabled": True, "apiSharingPort": API_PORT},
                  open(f"{home}/Library/Preferences/com.vibecockpit.app.plist", "wb"))
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json.dump([{"id": "00000000-0000-0000-0000-000000000001", "name": "soak", "scopes": ["models", "chat", "embeddings", "toolsRead"],
                "tokenHash": hashlib.sha256(token.encode()).hexdigest(), "tokenPrefix": token[:11], "createdAt": now}],
              open(f"{support}/clients.json", "w"))
    os.chmod(f"{support}/clients.json", 0o600)

    stub = ThreadingHTTPServer(("127.0.0.1", STUB_PORT), Stub)
    threading.Thread(target=stub.serve_forever, daemon=True).start()

    env = dict(os.environ, CFFIXED_USER_HOME=home, KORORO_STUBCLOUD_TOKEN="throwaway")
    app = subprocess.Popen([APP, "-routingPolicy", "localFirst", "-apiSharingEnabled", "YES",
                            "-apiSharingPort", str(API_PORT)], env=env,
                           stdout=open(f"{a.out}/app.log", "w"), stderr=subprocess.STDOUT)
    sock = f"{home}/.vibecockpit/mcp.sock"
    for _ in range(60):
        if os.path.exists(sock): break
        time.sleep(1)
    else:
        app.kill(); sys.exit("app never opened its socket")
    time.sleep(3)

    stop = threading.Event()
    counters = {k: Counter() for k in ("chat", "stream", "mcp")}
    threads = [threading.Thread(target=run_chat, args=(sock, stop, counters["chat"])),
               threading.Thread(target=run_stream, args=(token, stop, counters["stream"])),
               threading.Thread(target=run_mcp, args=(sock, stop, counters["mcp"]))]
    for t in threads: t.start()

    samples, start, alive = [], time.time(), True
    with open(f"{a.out}/soak.csv", "w") as csv:
        csv.write("t_s,rss_kb,fds," + ",".join(f"{k}_ok,{k}_err" for k in counters) + "\n")
        try:
            while time.time() - start < seconds:
                if app.poll() is not None: alive = False; break
                s = {"t": round(time.time() - start), "rss_kb": rss_kb(app.pid), "fds": fd_count(app.pid)}
                samples.append(s)
                csv.write(f"{s['t']},{s['rss_kb']},{s['fds']}," + ",".join(f"{c.ok},{c.err}" for c in counters.values()) + "\n")
                csv.flush()
                time.sleep(a.interval)
        except KeyboardInterrupt:
            pass
    stop.set()
    for t in threads: t.join(timeout=10)
    if app.poll() is None: app.send_signal(signal.SIGTERM); app.wait(timeout=20)
    stub.shutdown()
    shutil.rmtree(home, ignore_errors=True)

    result = {"seconds": round(time.time() - start), "app_alive_throughout": alive,
              "clients": {k: {"ok": c.ok, "errors": c.err, "last_error": c.last_error} for k, c in counters.items()}}
    problems = []
    if not alive: problems.append("app exited during the run")
    if len(samples) >= 8:
        result.update(summarize(samples))
        if result["rss_growth_pct"] > a.max_growth_pct: problems.append(f"RSS grew {result['rss_growth_pct']}%")
        if result["fds_last_quarter"] > result["fds_first_quarter"] + 10: problems.append("open files kept climbing")
    else:
        problems.append("too few samples to judge growth (run longer or lower --interval)")
    for k, c in counters.items():
        total = c.ok + c.err
        if total == 0 or c.err / total > 0.01: problems.append(f"client {k}: {c.err}/{total} failed ({c.last_error})")
    result["problems"] = problems
    result["pass"] = not problems
    json.dump(result, open(f"{a.out}/soak.json", "w"), indent=2)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
