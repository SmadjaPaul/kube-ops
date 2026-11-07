import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const cfg = JSON.parse(await readFile(new URL('../renovate.json', import.meta.url), 'utf8'));
const packages = ['@mdx-js/react', 'clsx', 'prism-react-renderer', 'react-icons', 'typed.js'];
const rule = cfg.packageRules.find((r) => r.description?.startsWith('PLT-140 documentation UI libraries minor-only'));

test('Renovate global defaults remain fail-closed', () => {
  assert.equal(cfg.automerge, false);
  assert.equal(cfg.platformAutomerge, false);
  assert.equal(cfg.ignoreTests, false);
  assert.equal(cfg.internalChecksFilter, 'strict');
});

test('new minor rule scopes to 5 stable website dependencies only', async () => {
  assert.ok(rule);
  assert.deepEqual(rule.matchManagers, ['npm']);
  assert.deepEqual(rule.matchFileNames, ['website/package.json']);
  assert.deepEqual(rule.matchDepTypes, ['dependencies']);
  assert.deepEqual(rule.matchUpdateTypes, ['minor']);
  assert.deepEqual([...rule.matchPackageNames].sort(), [...packages].sort());
  assert.equal(rule.matchCurrentVersion, '!/^0\\./');
  assert.equal(rule.minimumReleaseAge, '14 days');
  assert.equal(rule.rangeStrategy, 'bump');
  assert.equal(rule.automerge, true);
  assert.equal(rule.automergeType, 'pr');
  assert.equal(rule.platformAutomerge, true);
  const manifest = JSON.parse(await readFile(new URL('../website/package.json', import.meta.url), 'utf8'));
  for (const name of packages) assert.ok(manifest.dependencies[name], name);
});

test('reject majors, prerelease-0.x, other files and critical dependencies', () => {
  const eligible = (o) => rule.matchManagers.includes(o.manager) &&
    rule.matchFileNames.includes(o.file) &&
    rule.matchDepTypes.includes(o.depType) &&
    rule.matchPackageNames.includes(o.name) &&
    rule.matchUpdateTypes.includes(o.type) && !/^0\./.test(o.current);
  const good = {manager: 'npm', file: 'website/package.json', depType: 'dependencies',
    name: 'clsx', type: 'minor', current: '2.1.0'};
  assert.equal(eligible(good), true);
  for (const change of [
    {...good, type: 'major'}, {...good, current: '0.9.0'},
    {...good, file: 'package.json'}, {...good, name: '@docusaurus/core'},
    {...good, manager: 'docker'}, {...good, depType: 'devDependencies'}
  ]) assert.equal(eligible(change), false, JSON.stringify(change));
});
