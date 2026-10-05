import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

EXPECTED_MODELS = {
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

BASE_URL = "http://127.0.0.1:4000"


def request(path, method="GET", body=None, token=master):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()

    req = urllib.request.Request(
        BASE_URL + path,
        method=method,
        headers=headers,
        data=data,
    )
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

print(
    json.dumps(
        {
            "keyInfoHttp": key_info_status,
            "keyModels": sorted(str(model) for model in key_models),
            "keyModelsExactExpected": set(map(str, key_models)) == EXPECTED_MODELS,
            "keyAliasPresent": bool(info.get("key_alias")),
            "teamIdPresent": bool(info.get("team_id")),
            "userIdPresent": bool(info.get("user_id")),
            "masterModelsHttp": master_models_status,
            "masterExpectedModelsPresent": EXPECTED_MODELS.issubset(set(master_ids)),
            "masterCompletionHttp": master_completion_status,
            "masterCompletionPass": master_completion_ok,
        }
    )
)
