# /// script
# dependencies = ["pytest", "httpx", "openai"]
# ///
import gzip
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from atlas_summaries import generate, prepare_evidence, sample_members, validate_answer, write_preview


def test_crossposts_do_not_count_as_independent_evidence():
    selected = [{'uri': uri} for uri in ['first', 'crosspost', 'unavailable', 'other']]
    docs = {'first': {'title': 'Original', 'content': 'Some text here'},
            'crosspost': {'title': 'Copied', 'content': 'Some  text\nhere'},
            'other': {'title': 'Another', 'content': 'Different content'}}
    evidence = prepare_evidence(selected, docs)
    assert [item['uri'] for item in evidence] == ['first', 'other']
    assert [item['id'] for item in evidence] == [1, 2]


def test_sampling_is_deterministic_and_limits_author_dominance():
    points = [{"uri": f"at://did:plc:{author}/site.standard.document/{i}", "membershipProbabilityFine": 1 - i / 100}
              for i, author in enumerate(['a'] * 12 + list('bcdefghijk'))]
    chosen = sample_members(points)
    assert len(chosen) == 10
    assert sum('/did:plc:a/' in p['uri'] for p in chosen) == 2
    assert chosen == sample_members(list(reversed(points)))
    assert chosen[0] == points[0]


def test_model_cannot_cite_nonexistent_sources():
    valid = dict(summary='A shared topic.', sourceIds=[1, 3])
    assert validate_answer(valid, 3) == valid
    for ids in ([4], [0], [True], [], ['1']):
        with pytest.raises(ValueError):
            validate_answer({**valid, 'sourceIds': ids}, 3)
    with pytest.raises(ValueError):
        validate_answer({**valid, 'summary': 'x' * 1601}, 3)


def test_summary_word_limit_prevents_long_panel_copy():
    concise = {'summary': ' '.join(['word'] * 50), 'sourceIds': [1]}
    assert validate_answer(concise, 1) == concise
    with pytest.raises(ValueError):
        validate_answer({**concise, 'summary': concise['summary'] + ' extra'}, 1)


def test_missing_key_and_legacy_dataset_preserve_atlas(tmp_path):
    path = tmp_path / 'atlas.json.gz'
    raw = gzip.compress(json.dumps({'meta': {'generatedAt': '2026-09-28'}, 'points': []}).encode())
    path.write_bytes(raw)
    assert generate(path, 'unused-key')['clusters'] == []
    write_preview(path, '')
    assert path.read_bytes() == raw
    assert json.loads((tmp_path / 'atlas-summaries.json').read_text())['status'] == 'unavailable'


def test_failure_removes_stale_preview(tmp_path):
    path = tmp_path / 'atlas.json.gz'
    path.write_bytes(b'invalid gzip')
    sidecar = tmp_path / 'atlas-summaries.json'
    sidecar.write_text('{"status":"ready","clusters":[{"id":9}]}')
    write_preview(path, '')
    assert json.loads(sidecar.read_text())['clusters'] == []
    assert path.read_bytes() == b'invalid gzip'


def test_document_reader_recovers_from_real_http_throttling():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import threading
    import httpx
    from atlas_summaries import DocumentReader

    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(429 if len(requests) == 1 else 200)
            self.send_header('Retry-After', '0')
            self.end_headers()
            self.wfile.write(b'{"documents":[],"missing":["at://a/x/1"]}')

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with httpx.Client() as http:
            reader = DocumentReader(http, f'http://127.0.0.1:{server.server_port}/document', interval=0.01)
            result = reader.read([{'uri': 'at://a/x/1'}])
        assert result == {'documents': [], 'missing': ['at://a/x/1']}
        assert len(requests) == 2
        assert requests[0] == requests[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@pytest.mark.parametrize('first', ['invalid json', '{"summary":"Topic.","sourceIds":[99]}'])
def test_summary_retries_invalid_output_over_http(first):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import threading
    from openai import OpenAI
    from atlas_summaries import request_summary

    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            text = first if len(requests) == 1 else '{"summary":"Topic.","sourceIds":[1]}'
            payload = {'id': 'resp_test', 'object': 'response', 'created_at': 0,
                       'status': 'completed', 'model': 'gpt-6-luna',
                       'output': [{'id': 'msg_test', 'type': 'message', 'role': 'assistant',
                                   'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}],
                       'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with OpenAI(api_key='local-test', base_url=f'http://127.0.0.1:{server.server_port}/v1') as client:
            answer, usage = request_summary(client, 'topic', [{'id': 1, 'text': 'Topic evidence.'}])
        assert answer == {'summary': 'Topic.', 'sourceIds': [1]}
        assert usage == {'inputTokens': 20, 'outputTokens': 10}
        assert len(requests) == 2
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    raise SystemExit(pytest.main([__file__, '-q']))
