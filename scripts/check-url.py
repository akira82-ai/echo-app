"""Run local URL and existing chat regressions after `swift build`. No API key needed."""
import json
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path.startswith('/v1/tools/'):
            self.send_response(500 if body.get('query') == 'fail' else 200)
            self.end_headers()
            self.wfile.write(json.dumps({'results': [{'url': 'https://example.com/article', 'title': 'Source'}],
                                        'content': 'Verified content'}).encode())
            return
        native = body['model'] == 'deepseek-flash'
        text = body['messages'][-1]['content'] if native else body['messages'][1]['content']
        if native:
            assert body['tools'] == ([] if 'Application-fetched webpage' in text else [{'type': 'deepseek_read_url', 'name': 'deepseek_read_url'}])
            assert len(body['messages']) == 2 and body['messages'][-1]['role'] == 'user'
            assert 'No web access is available' not in body['messages'][0]['content']
            if 'User instruction:' in text:
                assert 'User instruction:\n总结' in text
                assert 'Application-fetched webpage' in text and 'Verified content' in text
        if text == 'error':
            self.send_response(500)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def event(choice):
            payload = {'id': 'test', 'object': 'chat.completion.chunk', 'created': 1,
                       'model': body['model'], 'choices': [dict(index=0, **choice)]}
            # CRLF and an SSE comment exercise framing, not just JSON parsing.
            self.wfile.write((': comment\r\ndata: ' + json.dumps(payload, ensure_ascii=False) + '\r\n\r\n').encode())
            self.wfile.flush()

        try:
            if native:
                event({'server_tool_event': {'type': 'call_started', 'call': {
                    'action': {'url': 'https://example.com/article'}}}})
                if text.startswith('cancel '):
                    time.sleep(.2)
                event({'delta': {'content': '中文回答'}})
                if text.startswith('truncated '):
                    return
                call = {'status': 'failed'} if text.startswith('failed ') else {
                    'status': 'completed', 'page': {'url': 'https://example.com/article', 'title': '来源'}}
                event({'server_tool_event': {'type': 'call_completed', 'call': call}})
            elif text in ('web', 'loop', 'web-error'):
                tools = [m for m in body['messages'] if m['role'] == 'tool']
                if len(tools) >= 2 and text != 'loop':
                    event({'delta': {'content': 'Verified https://example.com/article'}})
                else:
                    fetch = len(tools) % 2 == 1
                    name = 'web_fetch' if fetch else 'web_search'
                    arguments = json.dumps({'url': 'https://example.com/article'} if fetch else {'query': 'fail' if text == 'web-error' else 'test'})
                    event({'delta': {'reasoning_content': 'Checking sources', 'tool_calls': [{
                        'index': 0, 'id': 'call-' + str(len(tools)), 'type': 'function',
                        'function': {'name': name, 'arguments': arguments[:5]}}]}})
                    event({'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': arguments[5:]}}]},
                           'finish_reason': 'tool_calls'})
                    self.wfile.write(b'data: [DONE]\n\n')
                    return
            elif text != 'empty':
                if text == 'slow':
                    time.sleep(.5)
                event({'delta': {'content': '你'}})
                event({'delta': {'content': '好'}})
            event({'delta': {}, 'finish_reason': 'stop'})
            self.wfile.write(b'data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancellation deliberately closes the connection.


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for flag in ('--url-self-test', '--chat-self-test'):
            result = subprocess.run([str(root / '.build/debug/Echo'), flag, str(server.server_port)], cwd=root)
            if result.returncode:
                raise SystemExit(result.returncode)
    finally:
        server.shutdown()
