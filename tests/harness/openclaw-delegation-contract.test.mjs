import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// Static, dependency-free GitOps preflight only. A live sessions_spawn / LiteLLM
// call must be independently observed before native delegation can be marked PASS.
const read = (path) => readFileSync(path, "utf8");

function openclawConfig(cell) {
  const yaml = read(`k8s/applications/ai/${cell}/configmap.yaml`);
  const match = yaml.match(/^  openclaw\.json: \|\n((?: {4}.*\n?)+)/m);
  assert.ok(match, `${cell}: embedded openclaw.json missing`);
  return JSON.parse(match[1].replace(/^ {4}/gm, ""));
}

test("all OpenClaw cell JSON payloads remain valid", () => {
  for (const cell of [
    "openclaw",
    "openclaw-talos-ops",
    "openclaw-talos-personal",
    "openclaw-talos-test",
  ]) {
    assert.ok(openclawConfig(cell).gateway, `${cell}: gateway missing`);
  }
});

test("delegation is bounded to a suspended, low-privilege test cell", () => {
  const cell = "openclaw-talos-test";
  const cfg = openclawConfig(cell);
  const instance = read(`k8s/applications/ai/${cell}/instance.yaml`);
  const sa = read(`k8s/applications/ai/${cell}/serviceaccount.yaml`);

  assert.match(instance, /^  suspended: true\s*$/m, "do not activate test cell through this PR");
  assert.match(sa, /^automountServiceAccountToken: false\s*$/m);
  assert.doesNotMatch(instance, /kubernetes-api-access|extraVolumeMounts|\/var\/run\/secrets\/kubernetes/);
  assert.equal(cfg.tools.elevated.enabled, false);
  assert.deepEqual(cfg.agents.defaults.subagents.allowAgents, ["talos-test"]);
  assert.deepEqual(Object.keys(cfg.agents.entries), ["talos-test"]);
  assert.equal(cfg.agents.defaults.subagents.model, "litellm/factory/fast");
  assert.ok(cfg.agents.defaults.subagents.maxConcurrent <= 2);
  assert.ok(cfg.agents.defaults.subagents.maxChildrenPerAgent <= 2);
  assert.ok(cfg.agents.defaults.subagents.runTimeoutSeconds <= 180);
  assert.ok(cfg.agents.defaults.subagents.runTimeoutSeconds > 0);
});

test("spawn and completion tools are allowed, but no execution or escalation", () => {
  const cfg = openclawConfig("openclaw-talos-test");
  for (const tool of ["sessions_spawn", "sessions_yield", "subagents", "sessions_list", "sessions_history"]) {
    assert.ok(cfg.tools.allow.includes(tool), `missing delegation tool: ${tool}`);
    assert.ok(!cfg.tools.deny.includes(tool), `delegation tool denied: ${tool}`);
  }
  for (const tool of ["exec", "process", "write", "edit", "apply_patch", "gateway", "message"]) {
    assert.ok(cfg.tools.deny.includes(tool), `parent tool must be denied: ${tool}`);
    assert.ok(cfg.tools.subagents.tools.deny.includes(tool), `child tool must be denied: ${tool}`);
    assert.ok(!cfg.tools.allow.includes(tool), `parent tool must not be allowed: ${tool}`);
  }
  for (const tool of ["sessions_spawn", "subagents"]) {
    assert.ok(cfg.tools.subagents.tools.deny.includes(tool), `prevent recursive delegation: ${tool}`);
  }
  assert.notEqual(cfg.tools.profile, "full");
});

test("shared and personal cells are not silently converted to delegation workers", () => {
  const shared = openclawConfig("openclaw");
  const personal = openclawConfig("openclaw-talos-personal");
  const ops = openclawConfig("openclaw-talos-ops");
  for (const cfg of [shared, personal, ops]) {
    assert.ok(!cfg.tools.allow.includes("sessions_spawn"));
    assert.ok(!cfg.agents.defaults.subagents, "do not expand production delegation in smoke PR");
  }
  assert.ok(personal.tools.deny.includes("exec"));
  assert.ok(personal.tools.deny.includes("process"));
  assert.ok(ops.tools.deny.includes("write"));
});

test("test network policy keeps GitHub and Kubernetes API outside its egress", () => {
  const cnp = read("k8s/applications/ai/openclaw-talos-test/networkpolicy.yaml");
  assert.doesNotMatch(cnp, /github\.com|api\.github\.com/);
  assert.doesNotMatch(cnp, /kube-apiserver/);
  assert.match(cnp, /namespace: litellm/);
  const models = read("k8s/applications/ai/litellm/proxy_server_config.yaml");
  assert.match(models, /^  - model_name: factory\/fast\s*$/m);
  assert.match(models, /^  - model_name: factory\/code\s*$/m);
});
