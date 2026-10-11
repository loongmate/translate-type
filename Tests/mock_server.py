"""Test-only OpenAI-compatible service; production never uses this server."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import json
import threading
import time
records = []
lock = threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        with lock: payload = {'count': len(records), 'requests': list(records)}
        data = json.dumps(payload).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with lock: records.append(body)
        time.sleep(0.2)
        if self.path.startswith('/error'):
            self.send_response(429); self.end_headers(); return
        if self.path.startswith('/redirect'):
            self.send_response(307); self.send_header('Location','http://localhost:18887/v1/chat/completions'); self.end_headers(); return
        if self.path.startswith('/malformed'):
            data = b'{"wrong":true}'
        elif self.path.startswith('/long'):
            answer = ('Please show this entire sentence so I can review every word before confirming it. ' * 45) + 'END OF TRANSLATION'
            data = json.dumps({'choices':[{'message':{'content':answer}}]}).encode()
        else:
            data = json.dumps({'choices':[{'message':{'content':'Hello.'}}]}).encode()
        try:
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
ThreadingHTTPServer(('127.0.0.1',18887), Handler).serve_forever()
