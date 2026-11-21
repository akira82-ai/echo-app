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
        raw = self.rfile.read(int(self.headers['Content-Length']))
        if self.path.startswith('/files'):
            assert raw.index(b'name="purpose"') < raw.index(b'name="file"')
            assert b'user_data' in raw and b'3600' in raw
            if self.path == '/files-slow':
                time.sleep(.4)
            self.send_response(503 if self.path == '/files-fail' else 200)
            self.end_headers()
            try:
                self.wfile.write(b'{"error":{"code":"unavailable"}}' if self.path == '/files-error' else b'{"id":"file-api-test"}')
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = json.loads(raw)
        parts = body.get('messages', [{}])[-1].get('content')
        if isinstance(parts, list) and any(p.get('type') == 'file' for p in parts):
            assert len(body['messages']) == 2 and body['messages'][0]['content'].startswith('Start your answer with DOC_OK.')
            assert parts[1]['file_id'] == 'file-api-test' and body['tools'] == []
            self.send_response(200)
            self.end_headers()
            result = {'choices':[{'delta':{'content':'DOC_OK ORCHID-742'},'finish_reason':'stop'}]}
            self.wfile.write(('data: '+json.dumps(result)+'\n\ndata: [DONE]\n\n').encode())
            return
        if self.path.startswith('/v1/tools/'):
            self.send_response(500 if body.get('query') == 'fail' or '/unreadable' in body.get('url', '') else 200)
            self.end_headers()
            self.wfile.write(json.dumps({'results': [{'url': 'https://example.com/article', 'title': 'Source'}],
                                        'content': 'Verified content'}).encode())
            return
        image = isinstance(body['messages'][-1]['content'], list)
        if image:
            assert len(body['messages']) == 2
            assert body['messages'][0]['content'].startswith('Custom image system prompt')
            assert not body.get('tools')
            parts = body['messages'][-1]['content']
            assert len(parts) == 2 and parts[1]['image_url']['url'].startswith('data:image/png;base64,')
            assert parts[1]['image_url']['detail'] == 'high'
        native = body['model'] == 'deepseek-flash' and not image
        text = body['messages'][-1]['content'] if native else body['messages'][1]['content']
        if native:
            assert body['tools'] == []
            assert len(body['messages']) == 2
            if 'Select webpage reading targets' in body['messages'][0]['content']:
                catalog = text.split('URL catalog:\n')[-1].splitlines()
                ids = [] if '翻译原文' in text else list(range(1, len(catalog) + 1))
                if '第二条' in text:
                    ids = [2]
                self.send_response(200)
                self.end_headers()
                choice = {'index': 0, 'delta': {'content': json.dumps(ids)}, 'finish_reason': 'stop'}
                self.wfile.write(('data: ' + json.dumps({'choices': [choice]}) + '\n\ndata: [DONE]\n\n').encode())
                return
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
                if '"source_text"' in text:
                    assert '翻译原文' in text
                if text.startswith('cancel '):
                    time.sleep(.2)
                event({'delta': {'content': '中文回答'}})
                if text.startswith('truncated '):
                    return
                if text.startswith('failed '):
                    event({'server_tool_event': {'type': 'call_completed', 'call': {'status': 'failed'}}})
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
        for flag in ('--document-self-test', '--image-self-test', '--url-self-test', '--chat-self-test'):
            result = subprocess.run([str(root / '.build/debug/Echo'), flag, str(server.server_port)], cwd=root)
            if result.returncode:
                raise SystemExit(result.returncode)
    finally:
        server.shutdown()
