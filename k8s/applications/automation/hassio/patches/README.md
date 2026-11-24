# Correctif hass-openid (PRD-87b)

`openid-ui_views.py` = `custom_components/openid/ui_views.py` du commit amont épinglé
(`OPENID_COMMIT` dans `../statefulset.yaml`) + `openid-ui_views.diff` (PR cavefire/hass-openid#101,
head b957becc, relue : un seul fichier, `inspect.signature` + `request.scheme`/`request.host`, aucun
appel réseau ni secret). Corrige `TypeError: verify_client_id() missing ... request_scheme` avec HA 2026.11.

Retirer ce dossier, le générateur `ha-openid-ui-views-patch`, le montage et les 3 lignes de
l'initContainer quand la PR #101 est mergée en amont et le commit épinglé la contient.
Garde : `tests/harness/hass-openid-patch-test.sh`.
