import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const exists = file => existsSync(file);
const read = file => readFileSync(file, 'utf8');
const hasTrackedFiles = pathspec =>
  execFileSync('git', ['ls-files', '--', pathspec], { encoding: 'utf8' }).trim().length > 0;

test('Paperclip local CLI/agent scaffolding is retired from Git', () => {
  // Empty/generated directories may remain in a developer worktree. The
  // retirement boundary is the tracked desired state, not filesystem shape.
  assert.equal(hasTrackedFiles('scripts/paperclip/**'), false);
  assert.equal(hasTrackedFiles('k8s/applications/ai/paperclip/company/**'), false);
  assert.equal(exists('tests/harness/paperclip-kubernetes-candidate-test.sh'), false);
  assert.ok(exists('docs/contracts/agent-test-result-v1.schema.json'));
  assert.ok(exists('scripts/check-agent-harness-contract.sh'));
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.scripts['check:paperclip-kubernetes-candidate'], undefined);
  assert.match(pkg.scripts.check, /check:argocd-roots/);
});

test('Paperclip server, data and monitoring roots are fully retired', () => {
  assert.equal(exists('k8s/applications/ai/paperclip/kustomization.yaml'), false);
  assert.equal(exists('k8s/infrastructure/controllers/velero/schedules/daily-paperclip.yaml'), false);
  assert.doesNotMatch(read('k8s/infrastructure/monitoring/blackbox/values.yaml'), /paperclip/i);
  assert.doesNotMatch(read('k8s/infrastructure/monitoring/blackbox/networkpolicy.yaml'), /paperclip/i);
  assert.doesNotMatch(read('k8s/infrastructure/network/policies/auth/allow-authentik-access.yaml'), /paperclip/i);
  assert.doesNotMatch(read('k8s/applications/platform/agentgateway/resources.yaml'), /paperclip/i);
  assert.doesNotMatch(read('k8s/applications/ai/executor/networkpolicy.yaml'), /paperclip/i);
  assert.equal(exists('k8s/infrastructure/controllers/paperclip-operator/application.yaml'), false);
  assert.equal(exists('k8s/infrastructure/controllers/paperclip-operator/kustomization.yaml'), false);
  assert.equal(read('k8s/infrastructure/controllers/vpa/recommendations.yaml').includes('paperclip.inc/v1alpha1'), false);
  assert.doesNotMatch(read('k8s/infrastructure/controllers/kustomization.yaml'), /^- paperclip-operator\s*$/m);
  assert.equal(read('k8s/infrastructure/controllers/project.yaml').includes('ghcr.io/paperclipinc/charts'), false);
  assert.equal(read('k8s/infrastructure/controllers/project.yaml').includes('paperclip-operator-system'), false);
  assert.equal(read('k8s/bootstrap/argocd-root/infrastructure-project.yaml').includes('paperclip-operator-system'), false);
  assert.equal(exists('k8s/infrastructure/controllers/paperclip-operator-namespace.yaml'), false);
  assert.doesNotMatch(read('k8s/applications/ai/kustomization.yaml'), /^- paperclip\s*$/m);
});

test('Docusaurus remains independent of the retired Paperclip scaffolding', () => {
  assert.ok(exists('website/package.json'));
  assert.ok(exists('netlify.toml'));
});
