import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const exists = file => existsSync(file);
const read = file => readFileSync(file, 'utf8');

test('Paperclip local CLI/agent scaffolding is retired, generic harness retained', () => {
  assert.equal(exists('scripts/paperclip'), false);
  assert.equal(exists('k8s/applications/ai/paperclip/company'), false);
  assert.equal(exists('tests/harness/paperclip-kubernetes-candidate-test.sh'), false);
  assert.ok(exists('docs/contracts/agent-test-result-v1.schema.json'));
  assert.ok(exists('scripts/check-agent-harness-contract.sh'));
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.scripts['check:paperclip-kubernetes-candidate'], undefined);
  assert.match(pkg.scripts.check, /check:argocd-roots/);
});

test('Paperclip server Instance is retired before data and operator prune', () => {
  assert.ok(exists('k8s/applications/ai-paperclip-h3/kustomization.yaml'));
  assert.equal(exists('k8s/applications/ai/paperclip/instance.yaml'), false);
  assert.ok(exists('k8s/applications/ai/paperclip/database.yaml'));
  assert.ok(exists('k8s/applications/ai/paperclip/database-scheduled-backup.yaml'));
  assert.ok(exists('k8s/infrastructure/controllers/paperclip-operator/application.yaml'));
  assert.ok(exists('k8s/infrastructure/controllers/velero/schedules/daily-paperclip.yaml'));
  assert.match(read('k8s/bootstrap/argocd-root/applications-applicationset.yaml'), /path: k8s\/applications\/ai-paperclip-h3/);
  assert.match(read('k8s/applications/ai/kustomization.yaml'), /^- paperclip\s*$/m);
});

test('Docusaurus remains independent of the retired Paperclip scaffolding', () => {
  assert.ok(exists('website/package.json'));
  assert.ok(exists('netlify.toml'));
});
