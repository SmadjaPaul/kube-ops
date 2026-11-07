import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../', import.meta.url);
const config = JSON.parse(await readFile(new URL('renovate.json', root), 'utf8'));

const rules = config.packageRules.filter((rule) =>
  rule.description?.includes('PLT-140') &&
  rule.matchDatasources?.includes('docker'),
);

const ruleFor = (path, packageName) => rules.find((rule) =>
  rule.matchFileNames?.includes(path) &&
  rule.matchPackageNames?.includes(packageName),
);

async function manifest(path) {
  return readFile(new URL(path, root), 'utf8');
}

test('it-tools discovery rule is scoped, mature and non-automerging', async () => {
  const rule = ruleFor(
    'k8s/applications/tools/it-tools/deployment.yaml',
    'corentinth/it-tools',
  );
  assert.ok(rule);
  assert.deepEqual(rule.matchUpdateTypes, ['digest', 'patch']);
  assert.equal(rule.minimumReleaseAge, '14 days');
  assert.equal(rule.automerge, false);
  assert.equal(rule.platformAutomerge, false);

  const deployment = await manifest('k8s/applications/tools/it-tools/deployment.yaml');
  const kustomization = await manifest('k8s/applications/tools/it-tools/kustomization.yaml');
  assert.match(deployment, /# renovate: docker=corentinth\/it-tools/);
  assert.match(deployment, /readinessProbe:/);
  assert.match(deployment, /livenessProbe:/);
  assert.match(kustomization, /- deployment\.yaml/);
});

test('whisper ASR discovery rule is scoped, mature and non-automerging', async () => {
  const rule = ruleFor(
    'k8s/applications/media/whisperasr/deployment.yaml',
    'onerahmet/openai-whisper-asr-webservice',
  );
  assert.ok(rule);
  assert.deepEqual(rule.matchUpdateTypes, ['patch', 'digest']);
  assert.equal(rule.minimumReleaseAge, '14 days');
  assert.equal(rule.automerge, false);
  assert.equal(rule.platformAutomerge, false);

  const deployment = await manifest('k8s/applications/media/whisperasr/deployment.yaml');
  const kustomization = await manifest('k8s/applications/media/whisperasr/kustomization.yaml');
  assert.match(deployment, /# renovate: datasource=docker depName=onerahmet\/openai-whisper-asr-webservice/);
  assert.match(deployment, /ASR_MODEL/);
  assert.match(deployment, /readinessProbe:/);
  assert.match(deployment, /livenessProbe:/);
  assert.match(deployment, /emptyDir:/);
  assert.match(kustomization, /- deployment\.yaml/);
});

test('candidate rules cannot enable automerge indirectly', () => {
  for (const rule of rules) {
    if (rule.groupName?.includes('candidate')) {
      assert.notEqual(rule.automerge, true);
      assert.notEqual(rule.platformAutomerge, true);
    }
  }
});
