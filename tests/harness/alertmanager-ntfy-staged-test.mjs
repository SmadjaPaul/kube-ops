import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';

// PLT-263: Alertmanager receivers are active. Their URLs are secrets (Healthchecks
// ping UUID, ntfy topic) and must reach Alertmanager only as ExternalSecret files.
const read = p => readFileSync(p, 'utf8');
const root = 'k8s/infrastructure/monitoring/prometheus-stack';
const activeValues = read(`${root}/values.yaml`);
const activeKustomization = read(`${root}/kustomization.yaml`);
const secrets = read(`${root}/alertmanager-secrets.yaml`);
const ntfyPolicy = read('k8s/applications/catalog/ntfy/app.yaml');
const valuesFile = `${root}/values.yaml`;

const haveYq = spawnSync('yq', ['--version'], { encoding: 'utf8' }).status === 0;
// The rendered check needs the Helm toolchain of the repository (mise.toml).
const haveRenderTools = ['helm', 'kustomize'].every(
  tool => spawnSync(tool, ['version'], { encoding: 'utf8' }).status === 0,
);
const MAX_BUFFER = 64 * 1024 * 1024;

function yqJson(expression, file) {
  const r = spawnSync('yq', ['-o=json', '-I=0', expression, file], { encoding: 'utf8', maxBuffer: MAX_BUFFER });
  if (r.status !== 0) return null;
  try {
    return JSON.parse(r.stdout);
  } catch {
    return null;
  }
}

function yqDocsFromText(text) {
  const r = spawnSync('yq', ['eval-all', '-o=json', '-I=0', '[.]'], {
    encoding: 'utf8',
    input: text,
    maxBuffer: MAX_BUFFER,
  });
  if (r.status !== 0) return null;
  try {
    return JSON.parse(r.stdout);
  } catch {
    return null;
  }
}

// Alertmanager matcher: `label op value`, value optionally quoted.
function matches(matcher, labels) {
  const parsed = /^([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*(.*)$/.exec(String(matcher).trim());
  if (!parsed) return false;
  const [, name, op, raw] = parsed;
  const value = raw.trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
  const actual = labels[name] ?? '';
  if (op === '=') return actual === value;
  if (op === '!=') return actual !== value;
  if (op === '=~') return new RegExp(`^${value}$`).test(actual);
  return !new RegExp(`^${value}$`).test(actual);
}

// The rendered Helm output of the monitoring root (Secret/ConfigMap carrying the
// Alertmanager configuration). Returns null when the render is unavailable: no
// helm, no network or a render still locked by another job.
function renderPrometheusStack() {
  const r = spawnSync('bash', ['scripts/lib/render-cache.sh', 'render', root], {
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    timeout: 180000,
  });
  if (r.status !== 0) return null;
  const file = r.stdout.trim().split('\n').filter(Boolean).pop();
  return file && existsSync(file) ? file : null;
}

function decodeValue(key, value) {
  const buffer = Buffer.from(String(value), 'base64');
  if (key.endsWith('.gz')) {
    try {
      return gunzipSync(buffer).toString('utf8');
    } catch {
      return null;
    }
  }
  return buffer.toString('utf8');
}

// Every data map of the Secrets and ConfigMaps of a rendered manifest.
function renderedDataMaps(file) {
  const expression = 'select((.kind == "Secret" or .kind == "ConfigMap") and (.data != null)) | .data';
  const r = spawnSync('yq', ['eval-all', '-o=json', '-I=0', expression, file], {
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
  });
  if (r.status !== 0) return null;
  const maps = [];
  for (const line of r.stdout.split('\n')) {
    if (!line.trim()) continue;
    try {
      maps.push(JSON.parse(line));
    } catch {
      // not a JSON document
    }
  }
  return maps;
}

// The Alertmanager configurations held by a text (base64 decoded Secret value
// or plain ConfigMap value).
function configsFromText(text) {
  const found = [];
  for (const parsed of yqDocsFromText(text) ?? []) {
    if (parsed?.route && Array.isArray(parsed.route.routes)) found.push(parsed);
  }
  return found;
}

// Every Alertmanager configuration found in a rendered manifest: the chart
// stores it base64 encoded in a Secret (`alertmanager.yaml`), possibly gzipped.
function alertmanagerConfigs(file) {
  const found = [];
  for (const data of renderedDataMaps(file) ?? []) {
    for (const [key, value] of Object.entries(data ?? {})) {
      const decoded = decodeValue(key, value);
      for (const text of [decoded, String(value)]) {
        if (!text) continue;
        const configs = configsFromText(text);
        if (!configs.length) continue;
        found.push(...configs);
        break;
      }
    }
  }
  return found;
}

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

// PLT-526: the three Optio capacity alerts are warnings. The root route sends
// every warning to the null receiver, so a blocked factory stayed silent.
const optioMatchers = ['alertname =~ "Optio.*"', 'severity = "warning"'];
const optioLabels = { alertname: 'OptioAgentSlotsStuck', severity: 'warning', namespace: 'optio' };

test('the Optio warnings reach ntfy through a sub-route of the root route', { skip: !haveYq }, () => {
  const route = yqJson('.alertmanager.config.route', valuesFile);
  assert.ok(route, 'the Alertmanager route must be readable');
  assert.equal(route.receiver, 'null', 'the fallback receiver of the root route must stay null');
  const optio = route.routes.filter(r => (r.matchers ?? []).includes(optioMatchers[0]));
  assert.equal(optio.length, 1, 'exactly one Optio sub-route is expected');
  const [sub] = optio;
  assert.equal(sub.receiver, 'ntfy-critical', 'the Optio warnings reuse the existing ntfy receiver');
  assert.deepEqual(sub.matchers, optioMatchers);
  assert.equal(sub.group_wait, '5m');
  assert.equal(sub.group_interval, '30m');
  assert.equal(sub.repeat_interval, '12h');
  // A sub-route is matched before the receiver of its parent route: an Optio
  // warning never reaches the null fallback.
  const position = route.routes.indexOf(sub);
  for (const earlier of route.routes.slice(0, position)) {
    const matchers = earlier.matchers ?? [];
    assert.ok(
      !(matchers.length && matchers.every(m => matches(m, optioLabels))),
      `route ${earlier.receiver} must not capture the Optio warnings`,
    );
  }
});

test('the Optio sub-route adds no receiver, no URL and no inhibition', { skip: !haveYq }, () => {
  const config = yqJson('.alertmanager.config', valuesFile);
  assert.deepEqual(
    config.receivers.map(r => r.name),
    ['null', 'healthchecks-watchdog', 'ntfy-critical'],
    'no new receiver is allowed',
  );
  const critical = config.route.routes.filter(r => (r.matchers ?? []).includes('severity = critical'));
  assert.equal(critical.length, 1, 'the critical route must stay unique');
  assert.deepEqual(critical[0].matchers, ['severity = critical']);
  assert.equal(critical[0].receiver, 'ntfy-critical');
  const watchdog = config.route.routes.filter(r => (r.matchers ?? []).includes('alertname = Watchdog'));
  assert.equal(watchdog.length, 1, 'the Watchdog route must stay unique');
  assert.equal(watchdog[0].receiver, 'healthchecks-watchdog');
  assert.deepEqual(
    config.inhibit_rules.map(rule => [rule.source_matchers ?? [], rule.target_matchers ?? [], rule.equal ?? []]),
    [
      [['severity = critical'], ['severity =~ warning|info'], ['namespace', 'alertname']],
      [['severity = warning'], ['severity = info'], ['namespace', 'alertname']],
      [['alertname = InfoInhibitor'], ['severity = info'], ['namespace']],
      [[], ['alertname = InfoInhibitor'], []],
    ],
    'the inhibition rules must stay untouched',
  );
});

test('the Alertmanager configuration is read back from a rendered Secret', { skip: !haveYq }, () => {
  // Shape of the kube-prometheus-stack output: the Alertmanager configuration is
  // a base64 encoded `alertmanager.yaml` key of a Secret.
  const dir = mkdtempSync(join(tmpdir(), 'kube-ops-alertmanager-'));
  try {
    const config = [
      'route:',
      '  receiver: "null"',
      '  routes:',
      '  - receiver: ntfy-critical',
      '    matchers:',
      '    - alertname =~ "Optio.*"',
      '    - severity = "warning"',
      '    group_wait: 5m',
      '    group_interval: 30m',
      '    repeat_interval: 12h',
      '',
    ].join('\n');
    const manifest = [
      'apiVersion: v1',
      'kind: Secret',
      'metadata:',
      '  name: alertmanager-kube-prometheus-stack-alertmanager',
      'type: Opaque',
      'data:',
      `  alertmanager.yaml: ${Buffer.from(config, 'utf8').toString('base64')}`,
      '',
    ].join('\n');
    const file = join(dir, 'rendered.yaml');
    writeFileSync(file, manifest);
    const configs = alertmanagerConfigs(file);
    assert.equal(configs.length, 1, 'the rendered Secret must hold one Alertmanager configuration');
    assert.equal(configs[0].route.receiver, 'null');
    assert.deepEqual(configs[0].route.routes[0].matchers, optioMatchers);
    assert.equal(configs[0].route.routes[0].receiver, 'ntfy-critical');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the rendered Alertmanager configuration routes the Optio warnings before the null fallback', { skip: !haveRenderTools }, t => {
  const rendered = renderPrometheusStack();
  if (!rendered) return t.skip('the Helm render of the monitoring root is unavailable here');
  const configs = alertmanagerConfigs(rendered);
  if (!configs.length) return t.skip('no Alertmanager configuration found in the rendered output');
  for (const config of configs) {
    assert.equal(config.route.receiver, 'null', 'the rendered fallback receiver must stay null');
    const optio = config.route.routes.filter(r => (r.matchers ?? []).includes(optioMatchers[0]));
    assert.equal(optio.length, 1, 'the rendered configuration must hold exactly one Optio sub-route');
    assert.equal(optio[0].receiver, 'ntfy-critical');
    assert.deepEqual(optio[0].matchers, optioMatchers);
    assert.equal(optio[0].group_wait, '5m');
    assert.equal(optio[0].group_interval, '30m');
    assert.equal(optio[0].repeat_interval, '12h');
  }
});
