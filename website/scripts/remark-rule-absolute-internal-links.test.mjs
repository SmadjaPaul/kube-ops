import assert from 'node:assert/strict';
import test from 'node:test';
import {remark} from 'remark';

import remarkRuleAbsoluteInternalLinks from './remark-rule-absolute-internal-links.js';

function messages(markdown) {
  return remark().use(remarkRuleAbsoluteInternalLinks).processSync(markdown).messages;
}

test('accepts relative internal documentation links', () => {
  assert.equal(messages('[Guide](../guide.md)').length, 0);
});

test('rejects root-relative internal documentation links', () => {
  const result = messages('[Guide](/docs/guide)');

  assert.equal(result.length, 1);
  assert.match(result[0].reason, /must be relative/);
  assert.equal(result[0].ruleId, 'remark-rule-absolute-internal-links');
});

test('accepts external, fragment, and protocol-relative links', () => {
  const result = messages(
    '[External](https://example.com/docs) [Section](#section) [CDN](//cdn.example.com/file)'
  );

  assert.equal(result.length, 0);
});
