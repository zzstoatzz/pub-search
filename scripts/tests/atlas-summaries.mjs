import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validatePreview } from '../../site/atlas-summary-preview.js';

const atlas = { clusters: { fine: [{ id: 7, label: 'agents', count: 3 }] }, points: [1, 2, 3].map((i) => ({ uri: `at://did:plc:a/site.standard.document/${i}`, clusterFine: 7 })) };
const data = { version: 1, atlasSha256: 'current', model: 'test', sampling: 'sample', clusters: [{ id: 7, label: 'agents', memberCount: 3, summary: 'A reading guide.', caveat: 'Excerpts only.', coherence: 'focused', sourceIds: [1], sources: atlas.points.map((p, i) => ({ id: i + 1, uri: p.uri, title: 'Document', excerpt: 'Some content' })) }] };

test('accepts a preview bound to the exact dataset and actual members', () => {
  assert.equal(validatePreview(data, 'current', atlas), data);
});
test('rejects cached summaries from another build before displaying them', () => {
  assert.throws(() => validatePreview(data, 'new-build', atlas), /different Atlas build/);
});
test('rejects evidence from unassigned documents or a different cluster', () => {
  for (const clusterFine of [-1, 8]) {
    const changed = structuredClone(atlas);
    changed.points[0].clusterFine = clusterFine;
    assert.throws(() => validatePreview(data, 'current', changed), /sources/);
  }
});
test('rejects references outside the supplied evidence', () => {
  const changed = structuredClone(data);
  changed.clusters[0].sourceIds = [4];
  assert.throws(() => validatePreview(changed, 'current', atlas), /reference/);
});
test('rejects counts and labels from a different membership snapshot', () => {
  for (const field of ['memberCount', 'label']) {
    const changed = structuredClone(data);
    changed.clusters[0][field] = field === 'label' ? 'new topic' : 4;
    assert.throws(() => validatePreview(changed, 'current', atlas), /membership/);
  }
});
