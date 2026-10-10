import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = 'k8s/applications/ai/paperclip';
const read = (suffix) => readFileSync(`${root}/${suffix}`, 'utf8');

test('live Paperclip does not load unqualified Kubernetes execution overlay', () => {
  const parent = read('kustomization.yaml');
  const instance = read('instance.yaml');
  assert.doesNotMatch(parent, /poc\/kubernetes-execution|sandbox-activation/i);
  assert.doesNotMatch(instance, /^  plugins:\s*$/m);
  assert.doesNotMatch(instance, /^  adapters:\s*$/m);
  assert.match(instance, /^  heartbeat:\n\s+enabled: false\s*$/m);
});

test('unreleased v1alpha1 plugin cannot be labeled compatible with v1beta1 controller', () => {
  const lock = read('poc/kubernetes-execution/version-lock.yaml');
  assert.match(lock, /^  sandboxApiExpected: "agents\.x-k8s\.io\/v1alpha1"\s*$/m);
  assert.match(lock, /^  sandboxCr: blocked\s*$/m);
  assert.match(lock, /servedSandboxApi: agents\.x-k8s\.io\/v1beta1/);
  assert.match(lock, /published plugin expects v1alpha1/i);
});

test('non-live candidate has bounded resources and no production secret reference', () => {
  const candidate = read('poc/kubernetes-execution/instance-candidate.yaml');
  assert.match(candidate, /namespacePrefix: paperclip-exec-/);
  assert.match(candidate, /egressMode: cilium/);
  assert.match(candidate, /perTenantQuota:/);
  assert.match(candidate, /perTenantLimitRange:/);
  assert.doesNotMatch(candidate, /(APP_PAPERCLIP|APP_FACTORY_PLATFORM|HETZNER_S3|githubToken|GITHUB_TOKEN|imagePullSecrets)/);
});

test('qualification calls out both image and control-plane permission boundaries', () => {
  const contract = read('KUBERNETES-EXECUTION.md');
  for (const phrase of [
    'HUMAN_GATE=H3_AGENT_IMAGE_EXTERNAL_OWNER',
    'per-tenant ResourceQuota',
    'Paperclip server remains healthy',
    'no existing Company agent',
    'H3',
  ]) assert.ok(contract.includes(phrase), `missing acceptance gate: ${phrase}`);
});

test('SMA-31 remains unexecuted until the operator explicitly accepts H1-H3', () => {
  const s = readFileSync('docs/factory/SMA-31_ACCEPTANCE.md','utf8');
  assert.match(s, /Status: `PREPARED_NOT_EXECUTED`/);
  assert.match(s, /SMA31_ACCEPTANCE=NOT_OBSERVED/);
  assert.match(s, /BLOCKED_PENDING_H1_H3_AND_ORCHESTRATOR_VALIDATION/);
});
