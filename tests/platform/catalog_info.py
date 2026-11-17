"""Generateur de reference du catalog-info.yaml d'une application (contrat v1).

Doit produire le MEME texte octet pour octet que le skeleton
golden-paths/platform-application/skeleton/.../catalog-info.yaml rendu par nunjucks.
Le test test_template.py verifie cette parite ; CI verifie aussi que chaque
k8s/apps-generated/<name>/catalog-info.yaml committe correspond a app.yaml.
"""
import json
import pathlib
import sys

import yaml


def _dump(value: str) -> str:
    # Equivalent du filtre nunjucks `dump` (JSON.stringify) pour des chaines ASCII/UTF-8.
    return json.dumps(value, ensure_ascii=False)


def render_catalog_info(app: dict) -> str:
    md = app["metadata"]
    name = md["name"]
    return (
        "apiVersion: backstage.io/v1alpha1\n"
        "kind: Component\n"
        "metadata:\n"
        f"  name: {name}\n"
        f"  description: {_dump(md['description'])}\n"
        "  annotations:\n"
        "    homelab.smadja.dev/golden-path: platform-application@v1\n"
        "    homelab.smadja.dev/contract: platform.smadja.dev/v1\n"
        "    homelab.smadja.dev/cluster: homelab\n"
        f"    homelab.smadja.dev/namespace: svc-{name}\n"
        "    homelab.smadja.dev/exposure: private\n"
        f"    homelab.smadja.dev/hostname: {name}.smadja.dev\n"
        "spec:\n"
        "  type: service\n"
        "  lifecycle: experimental\n"
        f"  owner: {_dump(md['owner'])}\n"
    )


if __name__ == "__main__":
    # Usage : catalog_info.py <app.yaml>  -> imprime le catalog-info attendu.
    sys.stdout.write(render_catalog_info(yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))))
