import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// PLT-263: Alertmanager receivers are active. Their URLs are secrets (Healthchecks
// ping UUID, ntfy topic) and must reach Alertmanager only as ExternalSecret files.
const read = p => readFileSync(p, 'utf8');
const root = 'k8s/infrastructure/monitoring/prometheus-stack';
const activeValues = read(`${root}/values.yaml`);
const activeKustomization = read(`${root}/kustomization.yaml`);
const secrets = read(`${root}/alertmanager-secrets.yaml`);
const ntfyPolicy = read('k8s/applications/catalog/ntfy/app.yaml');

test('the Watchdog dead-man route pings Healthchecks from a secret file', () => {
  assert.match(activeValues, /receiver: healthchecks-watchdog\s+matchers: \['alertname = Watchdog'\]/);
  assert.match(activeValues, /repeat_interval: 2m/);
  assert.match(activeValues, /url_file: \/etc\/alertmanager\/secrets\/alertmanager-healthchecks-ping\/url/);
  assert.doesNotMatch(activeValues, /hc-ping\.com/);
  assert.match(secrets, /HEALTHCHECKS_WATCHDOG_PING_URL/);
});

test('the critical receiver publishes firing and resolved to ntfy from a secret file', () => {
  assert.match(activeValues, /receiver: ntfy-critical\s+matchers: \['severity = critical'\]/);
  assert.match(activeValues, /url_file: \/etc\/alertmanager\/secrets\/alertmanager-ntfy-url\/url/);
  assert.match(activeValues, /send_resolved: true/);
  assert.doesNotMatch(activeValues, /ntfy\.sh\/|homelab-alerts-/);
  assert.match(secrets, /ALERTMANAGER_NTFY_URL/);
  assert.doesNotMatch(secrets, /property: value/);
});

test('the ExternalSecrets are in the Kustomization and mounted by Alertmanager', () => {
  assert.match(activeKustomization, /alertmanager-secrets\.yaml/);
  assert.match(activeValues, /secrets:\s+- alertmanager-healthchecks-ping\s+- alertmanager-ntfy-url/);
  assert.match(activeValues, /receiver: 'null'/);
});

test('the ntfy ingress selector names only monitoring Alertmanager pods', () => {
  assert.match(ntfyPolicy, /k8s:io\.kubernetes\.pod\.namespace: monitoring\s+app\.kubernetes\.io\/name: alertmanager/);
  assert.match(ntfyPolicy, /port: "8080"/);
});
