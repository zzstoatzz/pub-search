# /// script
# dependencies = ["httpx", "openai"]
# ///
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path

from openai import OpenAI

from atlas_summaries import MODEL, SYSTEM, fingerprint, request_summary, validate_answer


def rewrite(atlas_path: Path, source_path: Path, output_path: Path, limit: int | None = None):
    raw = gzip.decompress(atlas_path.read_bytes())
    atlas = json.loads(raw)
    source = json.loads(source_path.read_text())
    if source.get('atlasSha256') != hashlib.sha256(raw).hexdigest():
        raise ValueError('Evidence belongs to a different Atlas snapshot')
    previous = json.loads(output_path.read_text()) if output_path.exists() else {}
    can_resume = previous.get('prompt') == SYSTEM and previous.get('atlasSha256') == source['atlasSha256']
    reuse = {(c['level'], c['id']): c for field in ('clusters', 'regions') for c in previous.get(field, [])} if can_resume else {}
    entries = source['clusters'] + source.get('regions', [])
    if limit is not None:
        entries = entries[:limit]
    requests = list(previous.get('requests', [])) if can_resume else []
    result = {**source, 'generatedAt': datetime.now(timezone.utc).isoformat(), 'prompt': SYSTEM,
              'model': MODEL, 'clusters': [], 'regions': [], 'requests': requests,
              'rewrittenFrom': source['generatedAt'], 'status': 'generating'}
    failures = []

    def build(entry):
        field = 'clusterFine' if entry['level'] == 'fine' else 'clusterCoarse'
        members = sorted(p['uri'] for p in atlas['points'] if p[field] == entry['id'])
        if fingerprint(members) != entry['membershipHash']:
            raise ValueError('Evidence membership mismatch')
        evidence, context = [], []
        for s in entry['sources']:
            e = {'id': s['id'], 'uri': s['uri'], 'title': s['title'], 'text': s['excerpt']}
            if 'cosineSimilarity' in s:
                context.append({**e, 'cosineSimilarity': s['cosineSimilarity'], 'role': s['role']})
            else:
                evidence.append(e)
        evidence_hash = fingerprint({'members': entry['membershipHash'], 'evidence': evidence, 'context': context, 'label': entry['label'], 'system': SYSTEM, 'model': MODEL})
        cached = reuse.get((entry['level'], entry['id']))
        if cached and cached['evidenceHash'] == evidence_hash:
            validate_answer({k: cached[k] for k in ('summary', 'sourceIds')}, len(entry['sources']), entry['label'])
            return cached
        with OpenAI(api_key=os.environ['OPENAI_API_KEY'], timeout=60, max_retries=1) as model:
            answer, usage = request_summary(model, entry['label'], evidence, context, requests)
        return {**entry, **answer, 'usage': usage, 'cached': False, 'evidenceHash': evidence_hash}

    def save():
        result['usage'] = {key: sum(r.get(key, 0) for r in requests) for key in ('inputTokens', 'cachedInputTokens', 'outputTokens')}
        result['rewriteFailures'] = failures
        output_path.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')))

    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {pool.submit(build, entry): entry for entry in entries}
        for future in as_completed(futures):
            entry = futures[future]
            try:
                updated = future.result()
                result['clusters' if entry['level'] == 'fine' else 'regions'].append(updated)
                print(f"{entry['level']} {entry['id']} {entry['label']}: {updated['summary']}", flush=True)
            except Exception as exc:
                failures.append({'level': entry['level'], 'id': entry['id'], 'error': type(exc).__name__})
                print(f"FAILED {entry['level']} {entry['id']}: {type(exc).__name__}", flush=True)
            save()
    result['generated'] = len(result['clusters']) + len(result['regions'])
    result['failed'] = source['failed'] + len(failures)
    result['status'] = 'ready' if result['generated'] else 'unavailable'
    result['rewriteLimit'] = limit
    save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Rewrite summaries from archived source excerpts without repeating retrieval.')
    parser.add_argument('atlas', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--limit', type=int)
    args = parser.parse_args()
    rewrite(args.atlas, args.source, args.output, args.limit)
