import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const schema = JSON.parse(await readFile(join(root, "docs/contracts/agent-test-result-v1.schema.json"), "utf8"));
const example = JSON.parse(await readFile(join(root, "docs/contracts/agent-test-result-v1.example.json"), "utf8"));

function validateResult(result) {
  assert.equal(result.schemaVersion, "agent-test-result/v1");
  assert.ok(result.resultId && result.producedAt && result.actor?.name);
  assert.ok(result.repository?.name && result.repository?.revision);
  assert.ok(Array.isArray(result.tests) && result.tests.length > 0);
  for (const item of result.tests) {
    assert.ok(item.id && item.name && item.reason);
    assert.ok(["executed", "not-executed"].includes(item.execution));
    assert.ok(["passed", "failed", "skipped", "unavailable", "not-applicable"].includes(item.classification));
    assert.ok(["none", "low", "medium", "high", "unknown"].includes(item.risk));
    assert.ok(["required", "expected", "optional", "not-expected", "unknown"].includes(item.expectedCi));
    if (item.execution === "executed") assert.ok(["passed", "failed"].includes(item.classification));
    if (item.execution === "not-executed") assert.ok(["skipped", "unavailable", "not-applicable"].includes(item.classification));
  }
  const summary = result.summary;
  assert.equal(summary.total, result.tests.length);
  assert.equal(summary.executed + summary.notExecuted, summary.total);
  assert.equal(result.transmission.target, "factory-platform");
  assert.equal(result.transmission.eventType, "agent.test.result");
  assert.equal(result.transmission.schema, "agent-test-result/v1");
  assert.equal(result.transmission.payload.resultId, result.resultId);
  assert.equal(result.transmission.payload.repository, result.repository.name);
  assert.equal(result.transmission.payload.revision, result.repository.revision);
  assert.ok(result.transmission.payload.tests.length > 0);
}

test("schema is versioned and declares the required result vocabulary", () => {
  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
  assert.equal(schema.properties.schemaVersion.const, "agent-test-result/v1");
  assert.deepEqual(schema.$defs.test.properties.execution.enum, ["executed", "not-executed"]);
  assert.deepEqual(schema.$defs.test.properties.classification.enum, ["passed", "failed", "skipped", "unavailable", "not-applicable"]);
  assert.ok(schema.properties.transmission.properties.payload);
});

test("checked-in example satisfies the semantic contract", () => {
  validateResult(example);
});

test("not-executed checks cannot be reported as passed or failed", () => {
  const invalid = structuredClone(example);
  invalid.tests[1].classification = "passed";
  assert.throws(() => validateResult(invalid));
});

test("transmission is an explicit projection and cannot carry credentials", () => {
  const serialized = JSON.stringify(example.transmission);
  assert.doesNotMatch(serialized, /token|password|secret|private[_-]?key/i);
  assert.ok(example.transmission.idempotencyKey.includes(example.repository.revision));
});
