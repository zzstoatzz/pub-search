import gzip
import hashlib
from urllib.parse import parse_qs, urlsplit
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POINTS = [
    {"x": x, "y": 0, "uri": f"at://fixture/{i}", "title": title,
     "platform": "other", "basePath": "example.com", "path": f"/{i}",
     "clusterCoarse": 0 if i < 2 else -1,
     "clusterFine": 65535 if i < 2 else -1}
    for i, (x, title) in enumerate([
        (0, "agent tools"), (0.015, "agent workflows"),
        (0.030, "AI and friendship"), (0.045, "unassigned essay"),
    ])
]
DATA = gzip.compress(json.dumps({
    "points": POINTS,
    "clusters": {
        "coarse": [{"id": 0, "label": "AI agents", "cx": 0.0075, "cy": 0, "count": 2}],
        "fine": [{"id": 65535, "label": "agent tools", "cx": 0.0075, "cy": 0,
                  "count": 2, "parent": 0}],
    },
    "publications": [],
    "meta": {"membershipVersion": 1, "nDocuments": 4},
}).encode())
PAGE = b'''<!doctype html><html><head><meta charset="utf-8"><title>Atlas membership regression</title></head><body>
<pre id="result">Checking actual WebGL renderer...</pre>
<iframe src="/site/atlas.html?x=0.0225&y=0&z=30" style="width:1280px;height:720px;border:0"></iframe>
<script>
const frame = document.querySelector('iframe');
if (new URLSearchParams(location.search).has('phone')) frame.style.width = '390px';
const deadline = Date.now() + 20000;
const timer = setInterval(() => {
  try {
    const win = frame.contentWindow;
    if (!win.atlas || !win.document.querySelector('#loading').classList.contains('hidden')) {
      if (Date.now() > deadline) throw Error('Atlas did not load');
      return;
    }
    const state = win.atlas._debug();
    if (state.animating) return;
    const check = (value, message) => { if (!value) throw Error(message); };
    check(state.connectionVertexCount === 2, 'Only the assigned pair should have a connection');
    check(win.atlas._debug(0).membership.fine === 65535, 'High cluster ID must survive');
    for (const i of [2, 3]) {
      const member = win.atlas._debug(i).membership;
      check(member.coarse === -1 && member.fine === -1, 'Noise must remain unassigned');
      check(member.hue === 255, 'Noise must retain platform color');
      check(state.planetIndices.includes(i), 'Unassigned document must still render');
    }
    document.querySelector('#result').textContent = 'PASS: only assigned pair connected; high ID intact; both unassigned documents visible with platform colors';
    clearInterval(timer);
  } catch (error) {
    document.querySelector('#result').textContent = 'FAIL: ' + error.message;
    clearInterval(timer);
  }
}, 50);
</script></body></html>'''


class Handler(SimpleHTTPRequestHandler):
    summary_attempts = {}
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/summary-states":
            body, kind = (ROOT / "scripts/tests/atlas-summary-states.html").read_bytes(), "text/html"
        elif path == "/atlas-summaries.json":
            build = parse_qs(urlsplit(self.path).query).get("build", [""])[0]
            attempt = self.summary_attempts.get(build, 0) + 1
            self.summary_attempts[build] = attempt
            if attempt == 1:
                self.send_error(503)
                return
            uris = [f"at://did:plc:test/site.standard.document/{i}" for i in range(1, 4)]
            sources = [{"id": i+1, "uri": uri, "title": f"Document {i+1}", "excerpt": "Member evidence."} for i, uri in enumerate(uris)]
            sources.append({"id": 4, "uri": "at://did:plc:notes/site.standard.document/related", "title": "Related note", "excerpt": "Supplemental evidence.", "role": "context", "cosineSimilarity": 0.85})
            cluster = {"id": 1, "label": "agent tools", "memberCount": 3,
                       "membershipHash": hashlib.sha256(json.dumps(uris, separators=(",", ":")).encode()).hexdigest(),
                       "summary": "Tools inspect files and coordinate changes.", "sources": sources, "sourceIds": [1, 4]}
            body = json.dumps({"version": 2, "atlasGeneratedAt": build, "status": "unavailable" if attempt == 2 else "ready", "clusters": [cluster] if attempt >= 4 else []}).encode()
            kind = "application/json"
        elif path == "/topics":
            body, kind = (ROOT / "scripts/tests/atlas-topics.html").read_bytes(), "text/html"
        elif path == "/site/atlas-summaries.json":
            body, kind = b'{"version":2,"status":"unavailable","clusters":[]}', "application/json"
        elif path == "/":
            body, kind = PAGE, "text/html"
        elif path == "/site/atlas.json.gz":
            body, kind = DATA, "application/gzip"
        elif path.startswith("/api/"):
            body, kind = b'[]', "application/json"
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print("Open http://127.0.0.1:8794/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8794), Handler).serve_forever()
