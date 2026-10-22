#!/usr/bin/env bash

set -euo pipefail

statefulset="k8s/applications/media/jellyfin/statefulset.yaml"
blueprint="k8s/infrastructure/auth/authentik/extra/blueprints/apps-jellyfin.yaml"
e2e="tests/e2e/specs/jellyfin.spec.ts"

grep -F 'client_secret_path = pathlib.Path("/run/jellyfin-oidc/client_secret")' "$statefulset" >/dev/null
grep -F 'root.findall("./Providers/OidcProviderConfig")' "$statefulset" >/dev/null
grep -F 'set_provider_value("ServerBaseUrl", server_base_url)' "$statefulset" >/dev/null
grep -F 'set_root_value("MigrateLocalUsers", "true")' "$statefulset" >/dev/null
grep -F 'requested_scopes = "openid profile email groups"' "$statefulset" >/dev/null
grep -F 'managed_role_mappings = {' "$statefulset" >/dev/null
grep -F 'duplicate managed RoleMapping' "$statefulset" >/dev/null
grep -F 'unmanaged admin RoleMapping is not allowed' "$statefulset" >/dev/null
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
assert "<Scopes>{requested_scopes}</Scopes>" in provider_block.group(0)
assert "<ServerBaseUrl>{server_base_url}</ServerBaseUrl>" not in source[
    provider_block.end() :
]
PY

if grep -F '<ClientSecretFile>' "$statefulset" >/dev/null; then
  echo 'JELLYFIN_OIDC_CONTRACT=FAIL unsupported ClientSecretFile remains in v1 config' >&2
  exit 1
fi

python3 - <<'PY'
import xml.etree.ElementTree as ET

MANAGED = {
    "media": {
        "IsAdmin": "false",
        "EnableAllLibraries": "true",
        "EnableMediaPlayback": "true",
        "EnableRemoteAccess": "true",
        "EnableTranscoding": "true",
    },
    "Jellyfin Users": {
        "IsAdmin": "false",
        "EnableAllLibraries": "true",
        "EnableMediaPlayback": "true",
        "EnableRemoteAccess": "true",
        "EnableTranscoding": "true",
    },
    "authentik-admins": {
        "IsAdmin": "true",
        "EnableAllLibraries": "true",
        "EnableMediaPlayback": "true",
        "EnableRemoteAccess": "true",
        "EnableTranscoding": "true",
        "EnableContentDeletion": "true",
        "EnableCollectionManagement": "true",
        "EnableSubtitleManagement": "true",
    },
    "Jellyfin Admins": {
        "IsAdmin": "true",
        "EnableAllLibraries": "true",
        "EnableMediaPlayback": "true",
        "EnableRemoteAccess": "true",
        "EnableTranscoding": "true",
        "EnableContentDeletion": "true",
        "EnableCollectionManagement": "true",
        "EnableSubtitleManagement": "true",
    },
}


def reconcile(document):
    root = ET.fromstring(document)
    provider = root.find("./Providers/OidcProviderConfig")
    scopes = provider.find("Scopes")
    scopes.text = "openid profile email groups"
    mappings = root.find("RoleMappings")
    if mappings is None:
        mappings = ET.SubElement(root, "RoleMappings")
    admin_roles = {"authentik-admins", "Jellyfin Admins"}
    for mapping in mappings.findall("RoleMapping"):
        role = mapping.findtext("RoleName")
        if mapping.findtext("IsAdmin", "false").lower() == "true":
            assert role in admin_roles, f"unmanaged admin mapping: {role}"
    for role, values in MANAGED.items():
        matches = [
            item for item in mappings.findall("RoleMapping")
            if item.findtext("RoleName") == role
        ]
        assert len(matches) <= 1, f"duplicate managed mapping: {role}"
        mapping = matches[0] if matches else ET.SubElement(mappings, "RoleMapping")
        for name, value in {"RoleName": role, **values}.items():
            element = mapping.find(name)
            if element is None:
                element = ET.SubElement(mapping, name)
            element.text = value
    return ET.tostring(root, encoding="unicode")


existing = """<PluginConfiguration><Providers><OidcProviderConfig><ProviderId>authentik</ProviderId><Scopes>openid profile email</Scopes></OidcProviderConfig></Providers><RoleMappings><RoleMapping><RoleName>custom</RoleName><CustomSetting>keep</CustomSetting></RoleMapping></RoleMappings></PluginConfiguration>"""
first = reconcile(existing)
second = reconcile(first)
assert first == second, "existing XML reconciliation is not idempotent"
assert "<RoleName>custom</RoleName><CustomSetting>keep</CustomSetting>" in first
assert "<RoleName>authentik-admins</RoleName>" in first
assert "<IsAdmin>true</IsAdmin>" in first
assert "<RoleName>media</RoleName>" in first

unmanaged_admin = existing.replace(
    "<CustomSetting>keep</CustomSetting>",
    "<CustomSetting>keep</CustomSetting><IsAdmin>true</IsAdmin>",
)
try:
    reconcile(unmanaged_admin)
except AssertionError:
    pass
else:
    raise AssertionError("unmanaged admin mapping was accepted")

absent = (
    "<PluginConfiguration><Providers><OidcProviderConfig>"
    "<ProviderId>authentik</ProviderId><Scopes>openid</Scopes>"
    "</OidcProviderConfig></Providers></PluginConfiguration>"
)
created = reconcile(absent)
assert created.count("<RoleMapping>") == 4, "absent mappings were not created"
assert "<Scopes>openid profile email groups</Scopes>" in created
assert "<RoleName>Jellyfin Users</RoleName>" in created
print("JELLYFIN_XML_RECONCILIATION=PASS")
PY

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
