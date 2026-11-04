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
        if body.get('stream') and not self.path.startswith(('/error', '/redirect', '/malformed', '/long')):
            try: self.stream_agent(body)
            except (BrokenPipeError, ConnectionResetError): pass
            return
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
    def stream_agent(self, body):
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        def event(delta, reason=None):
            frame = {'choices':[{'delta':delta,'finish_reason':reason}]}
            data = ('data: ' + json.dumps(frame, ensure_ascii=False) + '\n\n').encode()
            # Split even inside a multibyte UTF-8 code point.
            for i in range(0,len(data),7): self.wfile.write(data[i:i+7]); self.wfile.flush()
        def tool(index, ident, name, args):
            encoded = json.dumps(args,ensure_ascii=False)
            event({'tool_calls':[{'index':index,'id':ident,'type':'function','function':{'name':name,'arguments':''}}]})
            for i in range(0,len(encoded),5): event({'tool_calls':[{'index':index,'function':{'arguments':encoded[i:i+5]}}]})
        tools = [m for m in body['messages'] if m['role']=='tool']
        users = [m for m in body['messages'] if m['role']=='user']
        if self.path.startswith('/slow'): time.sleep(1.5)
        if self.path.startswith('/loop'):
            tool(0,'loop_'+str(len(tools)),'not_a_tool',{})
            event({},'tool_calls')
        elif self.path.startswith('/truncated'):
            tool(0,'partial','write_file',{'path':'must-not-exist.txt','content':'bad'})
            return
        elif self.path.startswith('/agent') and len(users)==1 and len(tools)==0:
            event({'content':'先写文件。'}); time.sleep(0.15)
            tool(0,'write_1','write_file',{'path':'note.txt','content':'你好，世界'})
            event({},'tool_calls')
        elif self.path.startswith('/agent') and len(users)==1 and len(tools)==1:
            tool(0,'edit_1','edit_file',{'path':'note.txt','old_string':'世界','new_string':'方寸'})
            tool(1,'read_1','read_file',{'path':'note.txt'})
            event({},'tool_calls')
        elif self.path.startswith('/agent') and len(users)==1 and len(tools)==3:
            tool(0,'shell_1','shell_exec',{'cmd':'printf "shell-ok"','yield_time_ms':1000})
            event({},'tool_calls')
        else:
            answer = '已完成。' if self.path.startswith('/agent') else 'Hello.'
            for ch in answer: event({'content':ch}); time.sleep(0.07)
            event({},'stop')
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
ThreadingHTTPServer(('127.0.0.1',18887), Handler).serve_forever()
