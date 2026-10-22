#!/usr/bin/env bash

set -euo pipefail

statefulset="k8s/applications/media/jellyfin/statefulset.yaml"
blueprint="k8s/infrastructure/auth/authentik/extra/blueprints/apps-jellyfin.yaml"
e2e="tests/e2e/specs/jellyfin.spec.ts"

grep -F 'client_secret_path = pathlib.Path("/run/jellyfin-oidc/client_secret")' "$statefulset" >/dev/null
grep -F 'root.findall("./Providers/OidcProviderConfig")' "$statefulset" >/dev/null
grep -F 'set_provider_value("ServerBaseUrl", server_base_url)' "$statefulset" >/dev/null
grep -F 'set_root_value("MigrateLocalUsers", "true")' "$statefulset" >/dev/null
grep -F 'config_path.chmod(0o600)' "$statefulset" >/dev/null

python3 - "$statefulset" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
provider_block = re.search(
    r"<OidcProviderConfig>.*?</OidcProviderConfig>", source, re.DOTALL
)
assert provider_block, "provider XML block missing"
assert "<ClientSecret>{client_secret}</ClientSecret>" in provider_block.group(0)
assert "<ServerBaseUrl>{server_base_url}</ServerBaseUrl>" in provider_block.group(0)
assert "<MigrateLocalUsers>true</MigrateLocalUsers>" in source
assert "<ServerBaseUrl>{server_base_url}</ServerBaseUrl>" not in source[
    provider_block.end() :
]
PY

if grep -F '<ClientSecretFile>' "$statefulset" >/dev/null; then
  echo 'JELLYFIN_OIDC_CONTRACT=FAIL unsupported ClientSecretFile remains in v1 config' >&2
  exit 1
fi

grep -F 'https://jellyfin.smadja.dev/sso/OIDC/Callback/authentik' "$blueprint" >/dev/null
grep -F 'https://jellyfin.smadja.dev/sso/OIDC/Start/authentik' "$blueprint" >/dev/null
if grep -F 'sso/OID/' "$blueprint" >/dev/null; then
  echo 'JELLYFIN_OIDC_CONTRACT=FAIL legacy OID path remains in Authentik blueprint' >&2
  exit 1
fi

grep -F '/sso/OIDC/Start/authentik' "$e2e" >/dev/null
if grep -F '/sso/Oid/start/authentik' "$e2e" >/dev/null; then
  echo 'JELLYFIN_OIDC_CONTRACT=FAIL legacy Oid path remains in browser test' >&2
  exit 1
fi

echo 'JELLYFIN_OIDC_CONTRACT=PASS'
