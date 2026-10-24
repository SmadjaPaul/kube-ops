import test from 'node:test';
import assert from 'node:assert/strict';
import {
  checkAgentDocs,
  findPublicDocumentationViolations,
  validateAgentText,
} from '../../scripts/check-documentation-integrity.mjs';

test('tracked agent routers reference existing paths and commands', () => {
  assert.deepEqual(checkAgentDocs(), []);
});

test('private network and credential material fail closed', () => {
  const violations = findPublicDocumentationViolations([
    'connect to 10.0.0.1',
    'token=ghp_123456789012345678901234567890',
  ].join('\n'));
  assert.ok(violations.includes('private network address'));
  assert.ok(violations.includes('GitHub token material'));
  assert.ok(findPublicDocumentationViolations('Use `~/.kube/config` only.').includes('ambient kubeconfig path'));
});

test('broken agent-router paths fail closed', () => {
  const errors = validateAgentText(
    process.cwd(),
    'AGENTS.md',
    'Read `docs/missing-runbook.md` and [open the runbook](docs/missing-runbook.md); run `just missing-recipe`.',
    new Set(['AGENTS.md']),
    new Set(['check']),
    new Set(),
    new Set(),
  );
  assert.ok(errors.some(error => error.includes('missing tracked path')));
  assert.ok(errors.some(error => error.includes('unknown just recipe')));
});

test('tracked wildcard paths resolve to at least one tracked file', () => {
  const errors = validateAgentText(
    process.cwd(),
    'AGENTS.md',
    'Read `scripts/*.sh`.',
    new Set(['AGENTS.md', 'scripts/example.sh']),
    new Set(['check']),
    new Set(),
    new Set(),
  );
  assert.deepEqual(errors, []);
});

test('active retired platform and IAM instructions fail closed', () => {
  const violations = findPublicDocumentationViolations('Deploy with Flux and read from bitwarden-backend.');
  assert.ok(violations.includes('active retired platform reference'));
  assert.ok(violations.includes('active retired IAM reference'));
  assert.ok(findPublicDocumentationViolations('Never use Flux; use Argo CD.').includes('active retired platform reference'));
});

test('historical references remain reviewable without being treated as active', () => {
  assert.deepEqual(
    findPublicDocumentationViolations('Historical note: the legacy Flux cluster no longer exists.'),
    [],
  );
});
