#!/usr/bin/env bash
set -euo pipefail

for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }
done

source "$(dirname "$0")/../lib/kube-preflight.sh"
require_kube_access

PAPERCLIP_NS="${PAPERCLIP_NS:-paperclip}"
LITELLM_NS="${LITELLM_NS:-litellm}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://litellm.litellm.svc.cluster.local:80/v1}"
RUN_MODEL_REQUEST="${RUN_MODEL_REQUEST:-yes}"

yesno() {
  [[ "$1" == "true" ]] && printf 'YES' || printf 'NO'
}

secret_has_key() {
  local ns="$1" name="$2" key="$3"
  kubectl get secret -n "$ns" "$name" -o json 2>/dev/null |
    jq -e --arg key "$key" '.data | has($key)' >/dev/null
}

secret_key_encoded() {
  local ns="$1" name="$2" key="$3"
  kubectl get secret -n "$ns" "$name" -o json |
    jq -r --arg key "$key" '.data[$key] // empty'
}

eso_json="$(kubectl get externalsecret.external-secrets.io -n "$PAPERCLIP_NS" paperclip-runtime-secrets -o json)"
eso_ready="$(jq -r 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' <<<"$eso_json")"

paperclip_key_present=false
if secret_has_key "$PAPERCLIP_NS" paperclip-runtime-secrets LITELLM_API_KEY; then
  paperclip_key_present=true
fi

master_key_present=false
if secret_has_key "$LITELLM_NS" litellm-secrets LITELLM_MASTER_KEY; then
  master_key_present=true
fi

key_differs_from_master=unknown
if [[ "$paperclip_key_present" == true && "$master_key_present" == true ]]; then
  paperclip_key_encoded="$(secret_key_encoded "$PAPERCLIP_NS" paperclip-runtime-secrets LITELLM_API_KEY)"
  master_key_encoded="$(secret_key_encoded "$LITELLM_NS" litellm-secrets LITELLM_MASTER_KEY)"
  if [[ -n "$paperclip_key_encoded" && "$paperclip_key_encoded" == "$master_key_encoded" ]]; then
    key_differs_from_master=false
  elif [[ -n "$paperclip_key_encoded" && -n "$master_key_encoded" ]]; then
    key_differs_from_master=true
  fi
fi

runtime_cfg="$(kubectl get configmap -n "$PAPERCLIP_NS" paperclip-runtime-config -o json)"
opencode_cfg="$(jq -r '.data.OPENCODE_CONFIG_CONTENT // empty' <<<"$runtime_cfg")"

logical_models_ok=false
base_url_ok=false
if [[ -n "$opencode_cfg" ]] && jq -e . >/dev/null 2>&1 <<<"$opencode_cfg"; then
  if jq -e '
    (.provider.litellm.models | keys | sort) ==
    (["factory/code","factory/default","factory/embedding","factory/fast","factory/research","factory/review"] | sort)
  ' >/dev/null <<<"$opencode_cfg"; then
    logical_models_ok=true
  fi
  if [[ "$(jq -r '.provider.litellm.options.baseURL // empty' <<<"$opencode_cfg")" == "$LITELLM_BASE_URL" ]]; then
    base_url_ok=true
  fi
fi

pod_row="$(
  kubectl get pods -n "$PAPERCLIP_NS" -o json |
    jq -r '
      [
        .items[]
        | select(.status.phase == "Running")
        | . as $pod
        | $pod.spec.containers[]
        | select(.image | startswith("ghcr.io/paperclipai/paperclip"))
        | [$pod.metadata.name, .name]
      ][0] // empty
      | @tsv
    '
)"

if [[ -z "$pod_row" ]]; then
  echo "ERROR: no running Paperclip server container found" >&2
  exit 3
fi

IFS=
env_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" -- node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const dirs = String(process.env.PATH || "")
      .split(":")
      .filter(Boolean);
    const present = (name) =>
      dirs.some((dir) => fs.existsSync(path.join(dir, name)));
    process.stdout.write(JSON.stringify({
      litellmApiKeyPresent: Boolean(process.env.LITELLM_API_KEY),
      litellmMasterKeyPresent: Boolean(process.env.LITELLM_MASTER_KEY),
      gitPresent: present("git"),
      ghPresent: present("gh"),
      opencodePresent: present("opencode")
    }))
  '
)"
pod_vkey_present="$(jq -r '.litellmApiKeyPresent' <<<"$env_probe")"
pod_master_present="$(jq -r '.litellmMasterKeyPresent' <<<"$env_probe")"
pod_git_present="$(jq -r '.gitPresent' <<<"$env_probe")"
pod_gh_present="$(jq -r '.ghPresent' <<<"$env_probe")"
pod_opencode_present="$(jq -r '.opencodePresent' <<<"$env_probe")"

vkey_key_info_http="$(jq -r '.keyInfoHttp // "N/A"' <<<"$vkey_diagnostic")"
vkey_allowed_models="$(jq -c '.keyModels // []' <<<"$vkey_diagnostic")"
vkey_scope_exact="$(jq -r '.keyModelsExactExpected // false' <<<"$vkey_diagnostic")"
vkey_alias_present="$(jq -r '.keyAliasPresent // false' <<<"$vkey_diagnostic")"
vkey_team_present="$(jq -r '.teamIdPresent // false' <<<"$vkey_diagnostic")"
vkey_user_present="$(jq -r '.userIdPresent // false' <<<"$vkey_diagnostic")"
master_models_http="$(jq -r '.masterModelsHttp // "N/A"' <<<"$vkey_diagnostic")"
master_expected_models="$(jq -r '.masterExpectedModelsPresent // false' <<<"$vkey_diagnostic")"
master_completion_http="$(jq -r '.masterCompletionHttp // "N/A"' <<<"$vkey_diagnostic")"
master_completion_pass="$(jq -r '.masterCompletionPass // false' <<<"$vkey_diagnostic")"

models_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --     env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
      const base = process.env.LITELLM_BASE_URL;
      const key = process.env.LITELLM_API_KEY;
      const expected = new Set([
        "factory/default",
        "factory/fast",
        "factory/code",
        "factory/research",
        "factory/review",
        "factory/embedding",
      ]);
      if (!key) {
        console.error("LITELLM_API_KEY missing");
        process.exit(10);
      }
      const response = await fetch(`${base}/models`, {
        headers: { authorization: `Bearer ${key}` },
      });
      if (!response.ok) {
        console.error(`models HTTP ${response.status}`);
        process.exit(11);
      }
      const payload = await response.json();
      const ids = Array.isArray(payload.data)
        ? payload.data.map((item) => item?.id).filter(Boolean)
        : [];
      const visible = new Set(ids);
      const missing = [...expected].filter((id) => !visible.has(id));
      const unexpected = ids.filter((id) => !expected.has(id));
      process.stdout.write(JSON.stringify({
        httpStatus: response.status,
        visibleModelCount: ids.length,
        expectedModelsPresent: missing.length === 0,
        unexpectedModelCount: unexpected.length,
      }));
    '
)"
models_http="$(jq -r '.httpStatus' <<<"$models_probe")"
models_expected="$(jq -r '.expectedModelsPresent' <<<"$models_probe")"
models_visible_count="$(jq -r '.visibleModelCount' <<<"$models_probe")"
models_unexpected_count="$(jq -r '.unexpectedModelCount' <<<"$models_probe")"

model_request="SKIPPED"
if [[ "$RUN_MODEL_REQUEST" == "yes" ]]; then
  completion_probe="$(
    kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --       env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
        const base = process.env.LITELLM_BASE_URL;
        const key = process.env.LITELLM_API_KEY;
        if (!key) {
          console.error("LITELLM_API_KEY missing");
          process.exit(20);
        }
        const response = await fetch(`${base}/chat/completions`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${key}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            model: "factory/default",
            messages: [{ role: "user", content: "Reply with OK." }],
            max_tokens: 4,
            temperature: 0,
          }),
        });
        if (!response.ok) {
          console.error(`completion HTTP ${response.status}`);
          process.exit(21);
        }
        const payload = await response.json();
        process.stdout.write(JSON.stringify({
          httpStatus: response.status,
          hasChoice: Array.isArray(payload.choices) && payload.choices.length > 0,
        }));
      '
  )"
  if [[ "$(jq -r '.httpStatus' <<<"$completion_probe")" == "200" &&
        "$(jq -r '.hasChoice' <<<"$completion_probe")" == "true" ]]; then
    model_request="PASS"
  else
    model_request="FAIL"
  fi
fi

printf 'PAPERCLIP_ESO_READY=%s\n' "$(yesno "$eso_ready")"
printf 'PAPERCLIP_LITELLM_SECRET_KEY_PRESENT=%s\n' "$(yesno "$paperclip_key_present")"
printf 'LITELLM_MASTER_SECRET_KEY_PRESENT=%s\n' "$(yesno "$master_key_present")"
case "$key_differs_from_master" in
  true)  echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=YES" ;;
  false) echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=NO" ;;
  *)     echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=UNKNOWN" ;;
esac
printf 'PAPERCLIP_LOGICAL_MODELS_CONFIGURED=%s\n' "$(yesno "$logical_models_ok")"
printf 'PAPERCLIP_LITELLM_BASE_URL_OK=%s\n' "$(yesno "$base_url_ok")"
printf 'PAPERCLIP_POD=%s\n' "$paperclip_pod"
printf 'PAPERCLIP_LITELLM_ENV_PRESENT=%s\n' "$(yesno "$pod_vkey_present")"
printf 'PAPERCLIP_LITELLM_MASTER_ENV_PRESENT=%s\n' "$(yesno "$pod_master_present")"
printf 'PAPERCLIP_GIT_BIN_PRESENT=%s\n' "$(yesno "$pod_git_present")"
printf 'PAPERCLIP_GH_BIN_PRESENT=%s\n' "$(yesno "$pod_gh_present")"
printf 'PAPERCLIP_OPENCODE_BIN_PRESENT=%s\n' "$(yesno "$pod_opencode_present")"
printf 'PAPERCLIP_VKEY_KEY_INFO_HTTP=%s\n' "$vkey_key_info_http"
printf 'PAPERCLIP_VKEY_ALLOWED_MODELS=%s\n' "$vkey_allowed_models"
printf 'PAPERCLIP_VKEY_SCOPE_EXACT=%s\n' "$(yesno "$vkey_scope_exact")"
printf 'PAPERCLIP_VKEY_ALIAS_PRESENT=%s\n' "$(yesno "$vkey_alias_present")"
printf 'PAPERCLIP_VKEY_TEAM_PRESENT=%s\n' "$(yesno "$vkey_team_present")"
printf 'PAPERCLIP_VKEY_USER_PRESENT=%s\n' "$(yesno "$vkey_user_present")"
printf 'LITELLM_MASTER_MODELS_HTTP=%s\n' "$master_models_http"
printf 'LITELLM_MASTER_EXPECTED_MODELS_PRESENT=%s\n' "$(yesno "$master_expected_models")"
printf 'LITELLM_MASTER_FACTORY_DEFAULT_HTTP=%s\n' "$master_completion_http"
printf 'LITELLM_MASTER_FACTORY_DEFAULT_REQUEST=%s\n' "$([[ "$master_completion_pass" == true ]] && echo PASS || echo FAIL)"
printf 'PAPERCLIP_VKEY_MODELS_HTTP=%s\n' "$models_http"
printf 'PAPERCLIP_VKEY_VISIBLE_MODEL_COUNT=%s\n' "$models_visible_count"
printf 'PAPERCLIP_VKEY_EXPECTED_MODELS_PRESENT=%s\n' "$(yesno "$models_expected")"
printf 'PAPERCLIP_VKEY_UNEXPECTED_MODEL_COUNT=%s\n' "$models_unexpected_count"
printf 'PAPERCLIP_FACTORY_DEFAULT_REQUEST=%s\n' "$model_request"

runtime_ready=PASS
[[ "$eso_ready" == true ]] || runtime_ready=FAIL
[[ "$paperclip_key_present" == true ]] || runtime_ready=FAIL
[[ "$key_differs_from_master" == true ]] || runtime_ready=FAIL
[[ "$logical_models_ok" == true ]] || runtime_ready=FAIL
[[ "$base_url_ok" == true ]] || runtime_ready=FAIL
[[ "$pod_vkey_present" == true ]] || runtime_ready=FAIL
[[ "$pod_master_present" == false ]] || runtime_ready=FAIL
[[ "$pod_git_present" == true ]] || runtime_ready=FAIL
[[ "$pod_gh_present" == true ]] || runtime_ready=FAIL
[[ "$pod_opencode_present" == true ]] || runtime_ready=FAIL
[[ "$vkey_key_info_http" == 200 ]] || runtime_ready=FAIL
[[ "$vkey_scope_exact" == true ]] || runtime_ready=FAIL
[[ "$master_models_http" == 200 ]] || runtime_ready=FAIL
[[ "$master_expected_models" == true ]] || runtime_ready=FAIL
[[ "$master_completion_pass" == true ]] || runtime_ready=FAIL
[[ "$models_http" == 200 ]] || runtime_ready=FAIL
[[ "$models_expected" == true ]] || runtime_ready=FAIL
if [[ "$RUN_MODEL_REQUEST" == "yes" && "$model_request" != PASS ]]; then
  runtime_ready=FAIL
fi

echo "PAPERCLIP_VKEY_RUNTIME=$runtime_ready"

[[ "$runtime_ready" == PASS ]]
\t' read -r paperclip_pod paperclip_container <<<"$pod_row"


litellm_pod_row="$(
  kubectl get pods -n "$LITELLM_NS" -l app=litellm -o json |
    jq -r '
      [
        .items[]
        | select(.status.phase == "Running")
        | . as $pod
        | $pod.spec.containers[]
        | [$pod.metadata.name, .name]
      ][0] // empty
      | @tsv
    '
)"

if [[ -z "$litellm_pod_row" ]]; then
  echo "ERROR: no running LiteLLM container found" >&2
  exit 4
fi

IFS=
env_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" -- node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const dirs = String(process.env.PATH || "")
      .split(":")
      .filter(Boolean);
    const present = (name) =>
      dirs.some((dir) => fs.existsSync(path.join(dir, name)));
    process.stdout.write(JSON.stringify({
      litellmApiKeyPresent: Boolean(process.env.LITELLM_API_KEY),
      litellmMasterKeyPresent: Boolean(process.env.LITELLM_MASTER_KEY),
      gitPresent: present("git"),
      ghPresent: present("gh"),
      opencodePresent: present("opencode")
    }))
  '
)"
pod_vkey_present="$(jq -r '.litellmApiKeyPresent' <<<"$env_probe")"
pod_master_present="$(jq -r '.litellmMasterKeyPresent' <<<"$env_probe")"
pod_git_present="$(jq -r '.gitPresent' <<<"$env_probe")"
pod_gh_present="$(jq -r '.ghPresent' <<<"$env_probe")"
pod_opencode_present="$(jq -r '.opencodePresent' <<<"$env_probe")"

models_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --     env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
      const base = process.env.LITELLM_BASE_URL;
      const key = process.env.LITELLM_API_KEY;
      const expected = new Set([
        "factory/default",
        "factory/fast",
        "factory/code",
        "factory/research",
        "factory/review",
        "factory/embedding",
      ]);
      if (!key) {
        console.error("LITELLM_API_KEY missing");
        process.exit(10);
      }
      const response = await fetch(`${base}/models`, {
        headers: { authorization: `Bearer ${key}` },
      });
      if (!response.ok) {
        console.error(`models HTTP ${response.status}`);
        process.exit(11);
      }
      const payload = await response.json();
      const ids = Array.isArray(payload.data)
        ? payload.data.map((item) => item?.id).filter(Boolean)
        : [];
      const visible = new Set(ids);
      const missing = [...expected].filter((id) => !visible.has(id));
      const unexpected = ids.filter((id) => !expected.has(id));
      process.stdout.write(JSON.stringify({
        httpStatus: response.status,
        visibleModelCount: ids.length,
        expectedModelsPresent: missing.length === 0,
        unexpectedModelCount: unexpected.length,
      }));
    '
)"
models_http="$(jq -r '.httpStatus' <<<"$models_probe")"
models_expected="$(jq -r '.expectedModelsPresent' <<<"$models_probe")"
models_visible_count="$(jq -r '.visibleModelCount' <<<"$models_probe")"
models_unexpected_count="$(jq -r '.unexpectedModelCount' <<<"$models_probe")"

model_request="SKIPPED"
if [[ "$RUN_MODEL_REQUEST" == "yes" ]]; then
  completion_probe="$(
    kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --       env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
        const base = process.env.LITELLM_BASE_URL;
        const key = process.env.LITELLM_API_KEY;
        if (!key) {
          console.error("LITELLM_API_KEY missing");
          process.exit(20);
        }
        const response = await fetch(`${base}/chat/completions`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${key}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            model: "factory/default",
            messages: [{ role: "user", content: "Reply with OK." }],
            max_tokens: 4,
            temperature: 0,
          }),
        });
        if (!response.ok) {
          console.error(`completion HTTP ${response.status}`);
          process.exit(21);
        }
        const payload = await response.json();
        process.stdout.write(JSON.stringify({
          httpStatus: response.status,
          hasChoice: Array.isArray(payload.choices) && payload.choices.length > 0,
        }));
      '
  )"
  if [[ "$(jq -r '.httpStatus' <<<"$completion_probe")" == "200" &&
        "$(jq -r '.hasChoice' <<<"$completion_probe")" == "true" ]]; then
    model_request="PASS"
  else
    model_request="FAIL"
  fi
fi

printf 'PAPERCLIP_ESO_READY=%s\n' "$(yesno "$eso_ready")"
printf 'PAPERCLIP_LITELLM_SECRET_KEY_PRESENT=%s\n' "$(yesno "$paperclip_key_present")"
printf 'LITELLM_MASTER_SECRET_KEY_PRESENT=%s\n' "$(yesno "$master_key_present")"
case "$key_differs_from_master" in
  true)  echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=YES" ;;
  false) echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=NO" ;;
  *)     echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=UNKNOWN" ;;
esac
printf 'PAPERCLIP_LOGICAL_MODELS_CONFIGURED=%s\n' "$(yesno "$logical_models_ok")"
printf 'PAPERCLIP_LITELLM_BASE_URL_OK=%s\n' "$(yesno "$base_url_ok")"
printf 'PAPERCLIP_POD=%s\n' "$paperclip_pod"
printf 'PAPERCLIP_LITELLM_ENV_PRESENT=%s\n' "$(yesno "$pod_vkey_present")"
printf 'PAPERCLIP_LITELLM_MASTER_ENV_PRESENT=%s\n' "$(yesno "$pod_master_present")"
printf 'PAPERCLIP_GIT_BIN_PRESENT=%s\n' "$(yesno "$pod_git_present")"
printf 'PAPERCLIP_GH_BIN_PRESENT=%s\n' "$(yesno "$pod_gh_present")"
printf 'PAPERCLIP_OPENCODE_BIN_PRESENT=%s\n' "$(yesno "$pod_opencode_present")"
printf 'PAPERCLIP_VKEY_MODELS_HTTP=%s\n' "$models_http"
printf 'PAPERCLIP_VKEY_VISIBLE_MODEL_COUNT=%s\n' "$models_visible_count"
printf 'PAPERCLIP_VKEY_EXPECTED_MODELS_PRESENT=%s\n' "$(yesno "$models_expected")"
printf 'PAPERCLIP_VKEY_UNEXPECTED_MODEL_COUNT=%s\n' "$models_unexpected_count"
printf 'PAPERCLIP_FACTORY_DEFAULT_REQUEST=%s\n' "$model_request"

runtime_ready=PASS
[[ "$eso_ready" == true ]] || runtime_ready=FAIL
[[ "$paperclip_key_present" == true ]] || runtime_ready=FAIL
[[ "$key_differs_from_master" == true ]] || runtime_ready=FAIL
[[ "$logical_models_ok" == true ]] || runtime_ready=FAIL
[[ "$base_url_ok" == true ]] || runtime_ready=FAIL
[[ "$pod_vkey_present" == true ]] || runtime_ready=FAIL
[[ "$pod_master_present" == false ]] || runtime_ready=FAIL
[[ "$pod_git_present" == true ]] || runtime_ready=FAIL
[[ "$pod_gh_present" == true ]] || runtime_ready=FAIL
[[ "$pod_opencode_present" == true ]] || runtime_ready=FAIL
[[ "$models_http" == 200 ]] || runtime_ready=FAIL
[[ "$models_expected" == true ]] || runtime_ready=FAIL
if [[ "$RUN_MODEL_REQUEST" == "yes" && "$model_request" != PASS ]]; then
  runtime_ready=FAIL
fi

echo "PAPERCLIP_VKEY_RUNTIME=$runtime_ready"

[[ "$runtime_ready" == PASS ]]
\t' read -r litellm_pod litellm_container <<<"$litellm_pod_row"

vkey_diagnostic="$(
  printf '%s' "$paperclip_key_encoded" |
    kubectl exec -i -n "$LITELLM_NS" "$litellm_pod" -c "$litellm_container" --       python -c '
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

expected = {
    "factory/default",
    "factory/fast",
    "factory/code",
    "factory/research",
    "factory/review",
    "factory/embedding",
}

encoded = sys.stdin.read().strip()
if not encoded:
    print(json.dumps({"error": "paperclip_vkey_missing"}))
    raise SystemExit(30)
vkey = base64.b64decode(encoded).decode()
master = os.environ.get("LITELLM_MASTER_KEY", "")
if not master:
    print(json.dumps({"error": "master_key_missing"}))
    raise SystemExit(31)

base = "http://127.0.0.1:4000"

def request(path, method="GET", body=None, token=master):
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(base + path, method=method, headers=headers, data=data)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            payload = json.loads(response.read().decode() or "{}")
            return response.status, payload
    except urllib.error.HTTPError as error:
        try:
            payload = json.loads(error.read().decode() or "{}")
        except Exception:
            payload = {}
        return error.code, payload

key_info_status, key_info_payload = request(
    "/key/info?key=" + urllib.parse.quote(vkey, safe="")
)
info = key_info_payload.get("info", key_info_payload)
key_models = info.get("models", [])
if not isinstance(key_models, list):
    key_models = []

master_models_status, master_models_payload = request(
    "/v1/models",
    token=master,
)
master_ids = [
    item.get("id")
    for item in master_models_payload.get("data", [])
    if isinstance(item, dict) and isinstance(item.get("id"), str)
]

master_completion_status, master_completion_payload = request(
    "/v1/chat/completions",
    method="POST",
    body={
        "model": "factory/default",
        "messages": [{"role": "user", "content": "Reply with OK."}],
        "max_tokens": 4,
        "temperature": 0,
    },
    token=master,
)
master_completion_ok = (
    master_completion_status == 200
    and isinstance(master_completion_payload.get("choices"), list)
    and len(master_completion_payload["choices"]) > 0
)

print(json.dumps({
    "keyInfoHttp": key_info_status,
    "keyModels": sorted(str(model) for model in key_models),
    "keyModelsExactExpected": set(map(str, key_models)) == expected,
    "keyAliasPresent": bool(info.get("key_alias")),
    "teamIdPresent": bool(info.get("team_id")),
    "userIdPresent": bool(info.get("user_id")),
    "masterModelsHttp": master_models_status,
    "masterExpectedModelsPresent": expected.issubset(set(master_ids)),
    "masterCompletionHttp": master_completion_status,
    "masterCompletionPass": master_completion_ok,
}))
      '
)"

env_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" -- node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const dirs = String(process.env.PATH || "")
      .split(":")
      .filter(Boolean);
    const present = (name) =>
      dirs.some((dir) => fs.existsSync(path.join(dir, name)));
    process.stdout.write(JSON.stringify({
      litellmApiKeyPresent: Boolean(process.env.LITELLM_API_KEY),
      litellmMasterKeyPresent: Boolean(process.env.LITELLM_MASTER_KEY),
      gitPresent: present("git"),
      ghPresent: present("gh"),
      opencodePresent: present("opencode")
    }))
  '
)"
pod_vkey_present="$(jq -r '.litellmApiKeyPresent' <<<"$env_probe")"
pod_master_present="$(jq -r '.litellmMasterKeyPresent' <<<"$env_probe")"
pod_git_present="$(jq -r '.gitPresent' <<<"$env_probe")"
pod_gh_present="$(jq -r '.ghPresent' <<<"$env_probe")"
pod_opencode_present="$(jq -r '.opencodePresent' <<<"$env_probe")"

models_probe="$(
  kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --     env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
      const base = process.env.LITELLM_BASE_URL;
      const key = process.env.LITELLM_API_KEY;
      const expected = new Set([
        "factory/default",
        "factory/fast",
        "factory/code",
        "factory/research",
        "factory/review",
        "factory/embedding",
      ]);
      if (!key) {
        console.error("LITELLM_API_KEY missing");
        process.exit(10);
      }
      const response = await fetch(`${base}/models`, {
        headers: { authorization: `Bearer ${key}` },
      });
      if (!response.ok) {
        console.error(`models HTTP ${response.status}`);
        process.exit(11);
      }
      const payload = await response.json();
      const ids = Array.isArray(payload.data)
        ? payload.data.map((item) => item?.id).filter(Boolean)
        : [];
      const visible = new Set(ids);
      const missing = [...expected].filter((id) => !visible.has(id));
      const unexpected = ids.filter((id) => !expected.has(id));
      process.stdout.write(JSON.stringify({
        httpStatus: response.status,
        visibleModelCount: ids.length,
        expectedModelsPresent: missing.length === 0,
        unexpectedModelCount: unexpected.length,
      }));
    '
)"
models_http="$(jq -r '.httpStatus' <<<"$models_probe")"
models_expected="$(jq -r '.expectedModelsPresent' <<<"$models_probe")"
models_visible_count="$(jq -r '.visibleModelCount' <<<"$models_probe")"
models_unexpected_count="$(jq -r '.unexpectedModelCount' <<<"$models_probe")"

model_request="SKIPPED"
if [[ "$RUN_MODEL_REQUEST" == "yes" ]]; then
  completion_probe="$(
    kubectl exec -n "$PAPERCLIP_NS" "$paperclip_pod" -c "$paperclip_container" --       env LITELLM_BASE_URL="$LITELLM_BASE_URL" node -e '
        const base = process.env.LITELLM_BASE_URL;
        const key = process.env.LITELLM_API_KEY;
        if (!key) {
          console.error("LITELLM_API_KEY missing");
          process.exit(20);
        }
        const response = await fetch(`${base}/chat/completions`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${key}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            model: "factory/default",
            messages: [{ role: "user", content: "Reply with OK." }],
            max_tokens: 4,
            temperature: 0,
          }),
        });
        if (!response.ok) {
          console.error(`completion HTTP ${response.status}`);
          process.exit(21);
        }
        const payload = await response.json();
        process.stdout.write(JSON.stringify({
          httpStatus: response.status,
          hasChoice: Array.isArray(payload.choices) && payload.choices.length > 0,
        }));
      '
  )"
  if [[ "$(jq -r '.httpStatus' <<<"$completion_probe")" == "200" &&
        "$(jq -r '.hasChoice' <<<"$completion_probe")" == "true" ]]; then
    model_request="PASS"
  else
    model_request="FAIL"
  fi
fi

printf 'PAPERCLIP_ESO_READY=%s\n' "$(yesno "$eso_ready")"
printf 'PAPERCLIP_LITELLM_SECRET_KEY_PRESENT=%s\n' "$(yesno "$paperclip_key_present")"
printf 'LITELLM_MASTER_SECRET_KEY_PRESENT=%s\n' "$(yesno "$master_key_present")"
case "$key_differs_from_master" in
  true)  echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=YES" ;;
  false) echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=NO" ;;
  *)     echo "PAPERCLIP_LITELLM_KEY_DIFFERS_FROM_MASTER=UNKNOWN" ;;
esac
printf 'PAPERCLIP_LOGICAL_MODELS_CONFIGURED=%s\n' "$(yesno "$logical_models_ok")"
printf 'PAPERCLIP_LITELLM_BASE_URL_OK=%s\n' "$(yesno "$base_url_ok")"
printf 'PAPERCLIP_POD=%s\n' "$paperclip_pod"
printf 'PAPERCLIP_LITELLM_ENV_PRESENT=%s\n' "$(yesno "$pod_vkey_present")"
printf 'PAPERCLIP_LITELLM_MASTER_ENV_PRESENT=%s\n' "$(yesno "$pod_master_present")"
printf 'PAPERCLIP_GIT_BIN_PRESENT=%s\n' "$(yesno "$pod_git_present")"
printf 'PAPERCLIP_GH_BIN_PRESENT=%s\n' "$(yesno "$pod_gh_present")"
printf 'PAPERCLIP_OPENCODE_BIN_PRESENT=%s\n' "$(yesno "$pod_opencode_present")"
printf 'PAPERCLIP_VKEY_MODELS_HTTP=%s\n' "$models_http"
printf 'PAPERCLIP_VKEY_VISIBLE_MODEL_COUNT=%s\n' "$models_visible_count"
printf 'PAPERCLIP_VKEY_EXPECTED_MODELS_PRESENT=%s\n' "$(yesno "$models_expected")"
printf 'PAPERCLIP_VKEY_UNEXPECTED_MODEL_COUNT=%s\n' "$models_unexpected_count"
printf 'PAPERCLIP_FACTORY_DEFAULT_REQUEST=%s\n' "$model_request"

runtime_ready=PASS
[[ "$eso_ready" == true ]] || runtime_ready=FAIL
[[ "$paperclip_key_present" == true ]] || runtime_ready=FAIL
[[ "$key_differs_from_master" == true ]] || runtime_ready=FAIL
[[ "$logical_models_ok" == true ]] || runtime_ready=FAIL
[[ "$base_url_ok" == true ]] || runtime_ready=FAIL
[[ "$pod_vkey_present" == true ]] || runtime_ready=FAIL
[[ "$pod_master_present" == false ]] || runtime_ready=FAIL
[[ "$pod_git_present" == true ]] || runtime_ready=FAIL
[[ "$pod_gh_present" == true ]] || runtime_ready=FAIL
[[ "$pod_opencode_present" == true ]] || runtime_ready=FAIL
[[ "$models_http" == 200 ]] || runtime_ready=FAIL
[[ "$models_expected" == true ]] || runtime_ready=FAIL
if [[ "$RUN_MODEL_REQUEST" == "yes" && "$model_request" != PASS ]]; then
  runtime_ready=FAIL
fi

echo "PAPERCLIP_VKEY_RUNTIME=$runtime_ready"

[[ "$runtime_ready" == PASS ]]
