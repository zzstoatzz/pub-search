# /// script
# dependencies = ["pytest", "httpx", "openai"]
# ///
import gzip
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from atlas_summaries import generate, lite, prepare_evidence, sample_members, validate_answer, write_preview


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
    assert json.loads((tmp_path / 'atlas-summaries-lite.json').read_text())['status'] == 'unavailable'


def test_lite_sidecar_keeps_verification_fields_and_drops_excerpts():
    sources = [{'id': i, 'uri': f'at://a/{i}', 'title': 't', 'excerpt': 'x' * 3000, 'role': 'member'} for i in (1, 2, 3)]
    sources.append({'id': 4, 'uri': 'at://b/4', 'title': 't', 'excerpt': 'y' * 3000, 'role': 'context', 'cosineSimilarity': 0.9})
    entry = {'level': 'fine', 'id': 7, 'label': 'agents', 'memberCount': 3, 'membershipHash': 'h', 'evidenceHash': 'e',
             'summary': 'Posts about agents.', 'sourceIds': [1, 4], 'sources': sources, 'usage': {}, 'cached': True}
    full = {'version': 2, 'status': 'ready', 'atlasGeneratedAt': 'today', 'generatedAt': 'now', 'prompt': 'p',
            'clusters': [entry], 'regions': [{**entry, 'level': 'coarse'}]}
    slim = lite(full)
    assert slim['clusters'] == slim['regions'] == [{'id': 7, 'label': 'agents', 'memberCount': 3, 'membershipHash': 'h',
                                                    'summary': 'Posts about agents.', 'sourceIds': [1, 4],
                                                    'memberSourceCount': 3, 'contextSourceCount': 1}]
    assert {k: slim[k] for k in ('version', 'status', 'atlasGeneratedAt', 'generatedAt')} == {k: full[k] for k in ('version', 'status', 'atlasGeneratedAt', 'generatedAt')}
    assert 'prompt' not in slim


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


@pytest.mark.parametrize('first', ['invalid json', '{"summary":"Topic.","sourceIds":[99]}', '{"summary":"Sample topic repeats the heading.","sourceIds":[1]}'])
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
        usage_log = []
        with OpenAI(api_key='local-test', base_url=f'http://127.0.0.1:{server.server_port}/v1') as client:
            answer, usage = request_summary(client, 'sample topic', [{'id': 1, 'text': 'Topic evidence.'}], usage_log=usage_log)
        assert answer == {'summary': 'Topic.', 'sourceIds': [1]}
        assert usage == {'inputTokens': 20, 'outputTokens': 10}
        assert len(requests) == 2
        assert len(usage_log) == 2
        assert sum(r['inputTokens'] for r in usage_log) == 20
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    raise SystemExit(pytest.main([__file__, '-q']))


def test_region_sampling_uses_region_strength():
    points = [{"uri": f"at://did:plc:{i}/site.standard.document/1",
               "membershipProbabilityFine": i / 20,
               "membershipProbabilityCoarse": 1 - i / 20} for i in range(20)]
    assert sample_members(points, "coarse") == points[:10]
    assert sample_members(points, "fine") == list(reversed(points))[:10]


def test_cache_keeps_region_and_cluster_evidence_separate():
    from atlas_summaries import summary_cache
    fine = {"evidenceHash": "same", "summary": "Fine topic."}
    coarse = {"evidenceHash": "same", "summary": "Broad topic."}
    cache = summary_cache({"version": 2, "clusters": [fine], "regions": [coarse]})
    assert cache[("fine", "same")] == fine
    assert cache[("coarse", "same")] == coarse
    assert summary_cache({"version": 2, "clusters": [fine]}) == {("fine", "same"): fine}


def test_context_gate_drops_weak_duplicate_and_member_matches():
    from atlas_context import select_context, NOTES_DID, NOTES_HOST
    rows = [
        {'uri': 'at://a/x/member', '$dist': 0.01},
        {'uri': 'at://a/x/weak', '$dist': 0.4},
        {'uri': 'at://a/x/nan', '$dist': float('nan')},
        {'uri': 'at://a/x/negative', '$dist': -0.1},
        {'uri': 'at://a/x/note', '$dist': 0.1, 'did': NOTES_DID, 'base_path': NOTES_HOST},
        {'uri': 'at://a/x/note', '$dist': 0.2, 'did': NOTES_DID, 'base_path': NOTES_HOST},
        {'uri': 'at://a/x/other', '$dist': 0.2, 'did': 'other', 'base_path': NOTES_HOST},
    ]
    chosen = select_context(rows, {'at://a/x/member'})
    assert [p['uri'] for p in chosen] == ['at://a/x/note', 'at://a/x/other']
    assert chosen[0]['cosineSimilarity'] == 0.9
    assert [p['includeUndiscoverable'] for p in chosen] == [True, False]
    assert select_context(rows[:4], {'at://a/x/member'}) == []


def test_context_retrieval_over_http_uses_member_vectors_and_scoped_notes():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import threading
    import httpx
    from atlas_context import ContextReader, NOTES_DID, NOTES_HOST

    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            if body['rank_by'] == ['id', 'asc']:
                rows = [{'vector': v} for v in [[2, 0], [0, 2], [1, 1]]]
            elif 'filters' in body:
                rows = [{'uri': 'at://a/x/note', '$dist': .1, 'did': NOTES_DID, 'base_path': NOTES_HOST}]
            else:
                rows = [{'uri': 'at://a/x/member', '$dist': .01}, {'uri': 'at://a/x/weak', '$dist': .6}]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'rows': rows}).encode())

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with httpx.Client() as http:
            reader = ContextReader(http, 'local-test', url=f'http://127.0.0.1:{server.server_port}/query')
            chosen = reader.retrieve([{'uri': f'at://a/x/{i}'} for i in range(3)], {'at://a/x/member'})
        assert [p['uri'] for p in chosen] == ['at://a/x/note']
        assert requests[1]['rank_by'][2] == pytest.approx([.5690355937, .5690355937])
        assert requests[2]['filters'] == ['And', [['did', 'Eq', NOTES_DID], ['base_path', 'Eq', NOTES_HOST]]]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_archive_restores_exact_inputs_and_deduplicates(tmp_path):
    import sqlite3
    from atlas_history import archive, restore
    atlas = tmp_path / 'atlas.json.gz'
    raw = b'{"meta":{"generatedAt":"today"},"points":[]}'
    atlas.write_bytes(gzip.compress(raw))
    summary = tmp_path / 'atlas-summaries.json'
    summary.write_text('{"status":"ready","clusters":[],"prompt":"original prompt"}')
    database = tmp_path / 'history.sqlite3'
    first = archive(atlas, database)
    assert archive(atlas, database) == first
    summary.write_text('{"status":"unavailable","clusters":[]}')
    second = archive(atlas, database)
    assert second != first
    with sqlite3.connect(database) as db:
        assert db.execute('SELECT count(*) FROM objects').fetchone()[0] == 3
        assert db.execute('SELECT count(*) FROM snapshots').fetchone()[0] == 2
    restore(database, first, tmp_path / 'restored')
    assert gzip.decompress((tmp_path / 'restored/atlas.json.gz').read_bytes()) == raw
    assert json.loads((tmp_path / 'restored/atlas-summaries.json').read_text())['prompt'] == 'original prompt'
    with pytest.raises(FileExistsError):
        restore(database, first, tmp_path / 'restored')
    with sqlite3.connect(database) as db:
        db.execute("UPDATE objects SET gzip=? WHERE sha256=(SELECT atlas_sha256 FROM snapshots LIMIT 1)", (gzip.compress(b'changed'),))
    with pytest.raises(ValueError, match='checksum'):
        restore(database, first, tmp_path / 'corrupt')


def test_opening_cannot_echo_the_heading_or_its_shortened_phrase():
    for label, summary in [('AI coding agents', 'AI coding agents use terminals.'),
                           ('AI coding agents', 'Coding agents use terminals.'),
                           ('gardening', 'Gardening takes patience.')]:
        with pytest.raises(ValueError, match='repeats the displayed label'):
            validate_answer({'summary': summary, 'sourceIds': [1]}, 3, label)
    assert validate_answer({'summary': 'Terminal access lets models edit files.', 'sourceIds': [1]}, 3, 'AI coding agents')

def test_recommendations_add_central_members_without_promoting_outliers():
    points = [{'uri': f'at://did:plc:a{i}/site.standard.document/post',
               'membershipProbabilityFine': 1 - i / 100} for i in range(30)]
    counts = {points[12]['uri']: 4, points[14]['uri']: 3, points[28]['uri']: 1000}
    baseline = sample_members(points)
    selected = sample_members(points, recommendations=counts)
    assert points[12] not in baseline and points[14] not in baseline
    assert selected[:2] == [points[12], points[14]]
    assert points[28] not in selected
    assert len(selected) == 10 and len({p['uri'] for p in selected}) == 10
    assert selected == sample_members(list(reversed(points)), recommendations=counts)
