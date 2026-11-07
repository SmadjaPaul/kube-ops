import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const config = JSON.parse(await readFile(new URL('../renovate.json', import.meta.url), 'utf8'));
const yamlManager = config.customManagers.find((manager) => manager.managerFilePatterns.includes('/\\.yaml$/'));
const dockerfileManager = config.customManagers.find((manager) => manager.managerFilePatterns.includes('/Dockerfile$/'));

function extract(manager, text) {
  for (const source of manager.matchStrings) {
    const match = new RegExp(source).exec(text);
    if (match?.groups) return match.groups;
  }
  return undefined;
}

test('canonical Docker annotation keeps datasource and depName separate', () => {
  const groups = extract(
    yamlManager,
    'image: onerahmet/openai-whisper-asr-webservice:v1.9.1 # renovate: datasource=docker depName=onerahmet/openai-whisper-asr-webservice',
  );
  assert.deepEqual(
    { datasource: groups?.datasource, depName: groups?.depName, currentValue: groups?.currentValue },
    { datasource: 'docker', depName: 'onerahmet/openai-whisper-asr-webservice', currentValue: 'v1.9.1' },
  );
});

test('digest-pinned Docker annotation keeps the release tag discoverable', () => {
  const groups = extract(
    yamlManager,
    'image: ghcr.io/moodiness/polyfin:0.61.1@sha256:1e55720ea21bca9448ddbdd80a21251622d21448ee2e31974ad18ae2a9f6c975 # renovate: datasource=docker depName=ghcr.io/moodiness/polyfin',
  );
  assert.deepEqual(
    { datasource: groups?.datasource, depName: groups?.depName, currentValue: groups?.currentValue },
    { datasource: 'docker', depName: 'ghcr.io/moodiness/polyfin', currentValue: '0.61.1' },
  );
});

test('canonical Helm annotation keeps datasource and depName separate', () => {
  const groups = extract(
    yamlManager,
    'version: 88.3.0 # renovate: datasource=helm depName=prometheus-community/kube-prometheus-stack',
  );
  assert.deepEqual(
    { datasource: groups?.datasource, depName: groups?.depName, currentValue: groups?.currentValue },
    { datasource: 'helm', depName: 'prometheus-community/kube-prometheus-stack', currentValue: '88.3.0' },
  );
});

test('legacy docker= annotation remains supported', () => {
  const groups = extract(
    yamlManager,
    'name: "ghcr.io/zapier/kubechecks:v0.3.0" # renovate: docker=ghcr.io/zapier/kubechecks',
  );
  assert.deepEqual(
    { datasource: groups?.datasource, depName: groups?.depName, currentValue: groups?.currentValue },
    { datasource: 'docker', depName: 'ghcr.io/zapier/kubechecks', currentValue: 'v0.3.0' },
  );
});

test('legacy Dockerfile github-releases annotation remains supported', () => {
  const groups = extract(
    dockerfileManager,
    'ARG IMAGE_VERSION=3.5.0 # renovate: github-releases=assafelovic/gpt-researcher',
  );
  assert.deepEqual(
    { datasource: groups?.datasource, depName: groups?.depName, currentValue: groups?.currentValue },
    { datasource: 'github-releases', depName: 'assafelovic/gpt-researcher', currentValue: '3.5.0' },
  );
});

test('canonical annotations never regress to datasource=datasource', () => {
  for (const text of [
    'image: example/image:v1.2.3 # renovate: datasource=docker depName=example/image',
    'version: 1.2.3 # renovate: datasource=helm depName=example/chart',
  ]) {
    const groups = extract(yamlManager, text);
    assert.notEqual(groups?.datasource, 'datasource');
  }
});
