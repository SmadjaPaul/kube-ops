#!/usr/bin/env python3
"""PLT-475: keep ONE Linear ticket about pending updates of the Proxmox host.

Weekly. Reads Prometheus only (apt_info.py metrics scraped from tatouine); it
never connects to the host. Then, in Linear (team PLT):
  - an open ticket with TITLE exists  -> its description and priority are
    refreshed (never a second ticket);
  - none exists and something is pending -> one ticket is created;
  - nothing pending and no ticket -> nothing.
Without LINEAR_API_KEY it prints the ticket and exits 0 (dry run).
Python stdlib only.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

PROM = os.environ.get("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
LINEAR = "https://api.linear.app/graphql"
TEAM_KEY = os.environ.get("LINEAR_TEAM_KEY", "PLT")
PROJECT = os.environ.get("LINEAR_PROJECT", "Cluster et ressources")
LABELS = [s for s in os.environ.get("LINEAR_LABELS", "cluster,J3").split(",") if s]
TITLE = "Proxmox tatouine : mises à jour en attente (ticket automatique)"
SEL = 'job="proxmox-host"'
RUNBOOK = "https://github.com/SmadjaPaul/kube-ops/blob/main/docs/operations/proxmox-updates.md"


def prom(query: str) -> list[dict]:
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=30) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"prometheus query failed: {query}")
    return body["data"]["result"]


def scalar(query: str) -> float | None:
    res = prom(query)
    return float(res[0]["value"][1]) if res else None


def collect() -> dict:
    by_origin = {
        r["metric"].get("exported_origin", "?"): int(float(r["value"][1]))
        for r in prom(f"sum by (exported_origin) (apt_upgrades_pending{{{SEL}}})")
    }
    kernel = prom(f"node_uname_info{{{SEL}}}")
    return {
        "telemetry": scalar(f"max(apt_autoremove_pending{{{SEL}}})") is not None,
        "pending": sum(by_origin.values()),
        "security": sum(v for k, v in by_origin.items() if "security" in k.lower()),
        "proxmox": sum(v for k, v in by_origin.items() if "proxmox" in k.lower()),
        "by_origin": by_origin,
        "held": int(scalar(f"sum(apt_upgrades_held{{{SEL}}})") or 0),
        "reboot": bool(scalar(f"max(node_reboot_required{{{SEL}}})") or 0),
        "index_age_days": (lambda v: None if v is None else round(v / 86400, 1))(
            scalar(f"time() - max(apt_package_cache_timestamp_seconds{{{SEL}}})")
        ),
        "kernel": kernel[0]["metric"].get("release", "?") if kernel else "?",
    }


def priority(s: dict) -> int:
    # Linear: 2 High, 3 Medium, 4 Low.
    if s["security"] or s["reboot"] or not s["telemetry"]:
        return 2
    return 3 if s["pending"] else 4


def description(s: dict) -> str:
    today = dt.date.today().isoformat()
    if not s["telemetry"]:
        state = "**Télémétrie absente** : `apt_autoremove_pending` n'est pas scrapé. Appliquer le rôle `proxmox_node_exporter` (homelab-infra, `proxmox_node_exporter_enable_apt_updates`)."
    elif s["pending"] == 0 and not s["reboot"]:
        state = "**Rien en attente.** Ce ticket peut être fermé ; un nouveau sera créé à la prochaine mise à jour disponible."
    else:
        state = f"**{s['pending']} paquets en attente**, dont **{s['security']} de sécurité** et {s['proxmox']} Proxmox."
    origins = "\n".join(f"| `{k}` | {v} |" for k, v in sorted(s["by_origin"].items())) or "| (aucun) | 0 |"
    return f"""Ticket tenu à jour chaque semaine par le CronJob `monitoring/proxmox-updates-backlog` (kube-ops). Il lit Prometheus seulement, jamais l'hôte. Ne pas renommer : le titre sert à retrouver ce ticket unique.

## État au {today}

{state}

| Signal | Valeur |
| -- | -- |
| Redémarrage requis (`/run/reboot-required`) | {"**oui**" if s["reboot"] else "non"} |
| Noyau en cours | `{s["kernel"]}` |
| Paquets retenus (hold) | {s["held"]} |
| Âge de l'index APT | {s["index_age_days"]} j |

| Origine APT | Paquets |
| -- | -- |
{origins}

Criticité : sécurité en attente ou redémarrage requis → priorité haute. Un redémarrage de l'hôte arrête la VM Talos, donc tout le cluster.

## Procédure (poste de Paul, jamais la CI)

```sh
cd ~/Desktop/perso/homelab-infra && git pull
export ANSIBLE_CONFIG=ansible/ansible.cfg
# 1. Liste exacte des paquets et garde-fous ZFS, sans rien changer
ansible-playbook ansible/playbooks/proxmox-upgrade.yml --check
# 2. Mise à jour sans redémarrage (snapshot ZFS avant)
ansible-playbook ansible/playbooks/proxmox-upgrade.yml -e proxmox_upgrade_confirm=tatouine
# 3. Seulement si un redémarrage est requis, dans une fenêtre annoncée
ansible-playbook ansible/playbooks/proxmox-upgrade.yml -e proxmox_upgrade_confirm=tatouine -e proxmox_upgrade_allow_reboot=true
```

Runbook : {RUNBOOK}
"""


def gql(key: str, query: str, variables: dict) -> dict:
    req = urllib.request.Request(
        LINEAR,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Content-Type": "application/json", "Authorization": key},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    if body.get("errors"):
        raise RuntimeError(f"linear: {body['errors']}")
    return body["data"]


def main() -> int:
    s = collect()
    desc, prio = description(s), priority(s)
    needed = s["pending"] > 0 or s["reboot"] or not s["telemetry"]
    key = os.environ.get("LINEAR_API_KEY", "").strip()
    print(json.dumps({k: v for k, v in s.items() if k != "by_origin"}))
    if not key:
        print("LINEAR_API_KEY absent: dry run, ticket not written\n" + desc)
        return 0

    found = gql(
        key,
        """query($team:String!,$title:String!){issues(first:5,orderBy:createdAt,filter:{
             team:{key:{eq:$team}},title:{eq:$title},state:{type:{nin:["completed","canceled"]}}}){
             nodes{id identifier createdAt}}}""",
        {"team": TEAM_KEY, "title": TITLE},
    )["issues"]["nodes"]
    if found:
        issue = sorted(found, key=lambda n: n["createdAt"])[0]
        if len(found) > 1:
            print(f"warning: {len(found)} open tickets titled '{TITLE}', updating the oldest only")
        gql(
            key,
            "mutation($id:String!,$d:String!,$p:Int!){issueUpdate(id:$id,input:{description:$d,priority:$p}){success}}",
            {"id": issue["id"], "d": desc, "p": prio},
        )
        print(f"updated {issue['identifier']}")
        return 0
    if not needed:
        print("nothing pending, no ticket")
        return 0

    meta = gql(
        key,
        """query($team:String!,$project:String!,$labels:[String!]){
             teams(filter:{key:{eq:$team}}){nodes{id}}
             projects(filter:{name:{eq:$project}}){nodes{id}}
             issueLabels(filter:{name:{in:$labels},or:[{team:{key:{eq:$team}}},{team:{null:true}}]}){nodes{id name}}}""",
        {"team": TEAM_KEY, "project": PROJECT, "labels": LABELS},
    )
    team_id = meta["teams"]["nodes"][0]["id"]
    project = meta["projects"]["nodes"]
    labels = list({n["name"]: n["id"] for n in meta["issueLabels"]["nodes"]}.values())
    inp = {"teamId": team_id, "title": TITLE, "description": desc, "priority": prio, "labelIds": labels}
    if project:
        inp["projectId"] = project[0]["id"]
    created = gql(
        key,
        "mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier}}}",
        {"i": inp},
    )
    print(f"created {created['issueCreate']['issue']['identifier']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
