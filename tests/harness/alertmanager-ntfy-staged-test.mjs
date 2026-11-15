import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Prevent credentials-dependent Alertmanager activation from accidentally
// riding an unrelated GitOps sync while the ntfy publisher token is absent.
const read = p => readFileSync(p, 'utf8');
const root = 'k8s/infrastructure/monitoring/prometheus-stack';
const activeValues = read(`${root}/values.yaml`);
const activeKustomization = read(`${root}/kustomization.yaml`);
const dormantSecret = read(`${root}/alertmanager-ntfy-secret.dormant.yaml`);
const dormantValues = read('docs/operations/alertmanager-ntfy-values.dormant.yaml');
const ntfyPolicy = read('k8s/applications/catalog/ntfy/app.yaml');

test('the active Alertmanager configuration is unchanged until scoped token admission', () => {
  assert.doesNotMatch(activeValues, /ntfy-critical|alertmanager-ntfy-publisher|template=alertmanager/);
  assert.doesNotMatch(activeKustomization, /alertmanager-ntfy-secret/);
  assert.match(dormantValues, /receiver: ntfy-critical/);
  assert.match(dormantValues, /severity = critical/);
  assert.match(dormantValues, /credentials_file:/);
  assert.match(dormantValues, /receiver: 'null'/);
});

test('the unreferenced ESO secret uses scalar Doppler remoteRef', () => {
  assert.match(dormantSecret, /kind: ExternalSecret/);
  assert.match(dormantSecret, /APP_ALERTMANAGER_NTFY_PUBLISHER_TOKEN/);
  assert.doesNotMatch(dormantSecret, /property: value/);
});

test('the dormant Watchdog dead-man route pings Healthchecks from a secret file (PLT-263)', () => {
  assert.match(dormantValues, /receiver: healthchecks-watchdog\s+matchers: \['alertname = Watchdog'\]/);
  assert.match(dormantValues, /repeat_interval: 2m/);
  assert.match(dormantValues, /url_file: \/etc\/alertmanager\/secrets\/alertmanager-healthchecks-ping\/url/);
  assert.doesNotMatch(dormantValues, /hc-ping\.com/);
  assert.match(dormantSecret, /HEALTHCHECKS_WATCHDOG_PING_URL/);
  assert.doesNotMatch(activeValues, /healthchecks/);
});

test('the ntfy ingress selector names only monitoring Alertmanager pods', () => {
  assert.match(ntfyPolicy, /k8s:io\.kubernetes\.pod\.namespace: monitoring\s+app\.kubernetes\.io\/name: alertmanager/);
  assert.match(ntfyPolicy, /port: "8080"/);
});
