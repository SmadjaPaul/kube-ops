#!/usr/bin/env python3
"""Static backup coverage audit (PLT-222). Git only, no cluster access.

Renders every Argo ApplicationSet root with `kustomize build --enable-helm`,
plus the child Argo Applications that use an external Helm chart, then
crosses each declared PVC with the rendered Velero Schedules, Longhorn
RecurringJobs and CNPG ScheduledBackups/ObjectStores.

Output: a Markdown coverage table on stdout (or --output FILE).
STATIC evidence only: runtime state (attached volumes, Volume CR labels,
completed backups) must be confirmed separately.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
APPSETS = [
    'k8s/bootstrap/argocd-root/applications-applicationset.yaml',
    'k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml',
]
CLASSES_FILE = 'docs/operations/backup-coverage-classes.tsv'
R2_HINT = re.compile(r'homelab-backup-|r2\.cloudflarestorage|\br2\b', re.I)
LEGACY_HINT = re.compile(r'your-objectstorage|smadja-dev-homelab-backups', re.I)  # abandoned offsite store
# Opt-in on a CNPG Cluster (PLT-369): its instance PVCs are covered by the Velero
# FS backup of their namespace. Crash-consistent at best (data and WAL PVCs are
# captured separately), restore unproven: reported as Velero-crash, never CNPG(R2).
VELERO_CRASH_ANN = 'backup.smadja.dev/velero-crash-consistent'


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor('tag:yaml.org,2002:value', lambda l, n: l.construct_scalar(n))


def load_all(text):
    return [d for d in yaml.load_all(text, Loader=Loader) if isinstance(d, dict)]


def roots():
    out = []
    for f in APPSETS:
        for d in load_all(open(os.path.join(ROOT, f)).read()):
            for g in (d.get('spec') or {}).get('generators') or []:
                items = ((g.get('git') or {}).get('directories') or []) + \
                    ((g.get('list') or {}).get('elements') or [])
                for el in items:
                    path = str(el.get('path', '')) if isinstance(el, dict) else ''
                    # A git directory generator creates no Application for a
                    # missing directory, and `exclude: true` removes one.
                    if path.startswith('k8s/') and not el.get('exclude') \
                            and os.path.isdir(os.path.join(ROOT, path)):
                        out.append(path)
    return out


def run(cmd):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def render_root(path):
    rc, out, err = run(['kustomize', 'build', '--enable-helm', path])
    if rc != 0:
        return [], err.strip().splitlines()[-1:] or ['kustomize failed']
    return load_all(out), []


def render_external_app(app):
    """Render an Argo Application whose source is a Helm repository chart."""
    spec = app.get('spec', {})
    src = spec.get('source') or (spec.get('sources') or [{}])[0]
    chart, repo, ver = src.get('chart'), src.get('repoURL', ''), src.get('targetRevision')
    ns = spec.get('destination', {}).get('namespace', 'default')
    if not chart:
        return [], 'git-source chart not rendered'
    helm = src.get('helm', {})
    values = helm.get('valuesObject') or (yaml.safe_load(helm['values']) if helm.get('values') else {})
    with tempfile.NamedTemporaryFile('w', suffix='.yaml', delete=False) as tf:
        yaml.safe_dump(values or {}, tf)
    release = helm.get('releaseName') or app['metadata']['name']
    if repo.startswith('http'):
        cmd = ['helm', 'template', release, chart, '--repo', repo]
    else:
        cmd = ['helm', 'template', release, 'oci://' + repo.rstrip('/') + '/' + chart]
    cmd += ['--version', str(ver), '-n', ns, '-f', tf.name]
    rc, out, err = run(cmd)
    os.unlink(tf.name)
    if rc != 0:
        return [], 'helm template failed: ' + (err.strip().splitlines() or ['?'])[-1][:120]
    docs = load_all(out)
    for d in docs:
        d.setdefault('metadata', {}).setdefault('namespace', ns)
    return docs, None


def match_selector(sel, labels):
    if not sel:
        return True
    for k, v in (sel.get('matchLabels') or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get('matchExpressions') or []:
        k, op, vals = e['key'], e['operator'], e.get('values') or []
        if op == 'In' and labels.get(k) not in vals:
            return False
        if op == 'NotIn' and labels.get(k) in vals:
            return False
        if op == 'Exists' and k not in labels:
            return False
        if op == 'DoesNotExist' and k in labels:
            return False
    return True


def size_of(spec):
    return ((spec.get('resources') or {}).get('requests') or {}).get('storage', '?')


def collect(docs_by_root, errors_out):
    pvcs = {}          # (ns, name) -> dict
    pods = []          # pod templates: ns, owner, labels, annotations, claims, replicas
    schedules, rjobs, scs, clusters, sbs, stores = [], [], {}, {}, defaultdict(list), {}
    for root, docs in docs_by_root.items():
        for d in docs:
            kind, md = d.get('kind'), d.get('metadata') or {}
            ns, name = md.get('namespace', 'default'), md.get('name')
            spec = d.get('spec') or {}
            if kind == 'PersistentVolumeClaim':
                pvcs[(ns, name)] = dict(ns=ns, name=name, sc=spec.get('storageClassName'),
                                        size=size_of(spec), labels=md.get('labels') or {},
                                        source=root, owner='PVC')
            elif kind in ('Deployment', 'StatefulSet', 'DaemonSet', 'Job', 'CronJob', 'Pod'):
                tpl = spec
                if kind == 'CronJob':
                    tpl = (spec.get('jobTemplate') or {}).get('spec', {}).get('template', {})
                elif kind != 'Pod':
                    tpl = spec.get('template') or {}
                pmd = tpl.get('metadata') or {} if kind != 'Pod' else md
                pspec = tpl.get('spec') or {} if kind != 'Pod' else spec
                vols = [(v['name'], v['persistentVolumeClaim']['claimName'])
                        for v in pspec.get('volumes') or [] if v.get('persistentVolumeClaim')]
                replicas = spec.get('replicas', 1) if kind in ('Deployment', 'StatefulSet') else 1
                if kind == 'StatefulSet':
                    for t in spec.get('volumeClaimTemplates') or []:
                        tname = t['metadata']['name']
                        for i in range(max(replicas, 1)):
                            claim = '%s-%s-%d' % (tname, name, i)
                            vols.append((tname, claim))
                            pvcs.setdefault((ns, claim), dict(
                                ns=ns, name=claim, sc=(t.get('spec') or {}).get('storageClassName'),
                                size=size_of(t.get('spec') or {}), labels=t['metadata'].get('labels') or {},
                                source=root, owner='StatefulSet/' + name))
                pods.append(dict(ns=ns, owner='%s/%s' % (kind, name), labels=pmd.get('labels') or {},
                                 ann=pmd.get('annotations') or {}, vols=vols, replicas=replicas,
                                 cron=kind in ('CronJob', 'Job')))
            elif kind == 'Schedule' and str(d.get('apiVersion', '')).startswith('velero.io'):
                if ns != 'velero':
                    errors_out.append('Schedule %s/%s ignored: Velero reads only namespace velero' % (ns, name))
                    continue
                if spec.get('paused'):
                    errors_out.append('Schedule %s paused: not counted' % name)
                    continue
                schedules.append(dict(name=name, **(spec.get('template') or {})))
            elif kind == 'RecurringJob':
                rjobs.append(dict(name=name, task=spec.get('task'), groups=spec.get('groups') or []))
            elif kind == 'StorageClass':
                scs[name] = dict(provisioner=d.get('provisioner'), params=d.get('parameters') or {},
                                 default=(md.get('annotations') or {}).get(
                                     'storageclass.kubernetes.io/is-default-class') == 'true')
            elif kind == 'Cluster' and str(d.get('apiVersion', '')).startswith('postgresql.cnpg.io'):
                inst = spec.get('instances', 1)
                st = spec.get('storage') or {}
                plug = [p for p in spec.get('plugins') or [] if 'barman' in p.get('name', '')]
                wal_store = None
                for p in plug:
                    if p.get('isWALArchiver') is True and p.get('enabled', True) is not False:
                        wal_store = (p.get('parameters') or {}).get('barmanObjectName')
                clusters[(ns, name)] = dict(wal_store=wal_store, instances=inst,
                                            velero_crash=(md.get('annotations') or {}).get(VELERO_CRASH_ANN))
                for i in range(1, inst + 1):
                    pvcs[(ns, '%s-%d' % (name, i))] = dict(
                        ns=ns, name='%s-%d' % (name, i), sc=st.get('storageClass'), size=st.get('size', '?'),
                        labels={'cnpg.io/cluster': name}, source=root, owner='CNPG/' + name)
                    if spec.get('walStorage'):
                        w = spec['walStorage']
                        pvcs[(ns, '%s-%d-wal' % (name, i))] = dict(
                            ns=ns, name='%s-%d-wal' % (name, i), sc=w.get('storageClass'),
                            size=w.get('size', '?'), labels={'cnpg.io/cluster': name},
                            source=root, owner='CNPG/' + name)
            elif kind == 'ScheduledBackup':
                pc = spec.get('pluginConfiguration') or {}
                if spec.get('method') == 'plugin' and 'barman' in str(pc.get('name', '')) \
                        and not spec.get('suspend'):
                    sbs[(ns, (spec.get('cluster') or {}).get('name'))].append(
                        (pc.get('parameters') or {}).get('barmanObjectName'))
            elif kind == 'ObjectStore':
                c = spec.get('configuration') or {}
                dest = '%s %s' % (c.get('destinationPath'), c.get('endpointURL'))
                stores[(ns, name)] = 'Legacy' if LEGACY_HINT.search(dest) else (
                    'R2' if R2_HINT.search(dest) else '?')
    return pvcs, pods, schedules, rjobs, scs, clusters, sbs, stores


def velero_cover(pvc, pods, schedules):
    """Return (schedule names, reason) for Velero FS backup of one PVC."""
    if pvc['labels'].get('velero.io/exclude-from-backup') == 'true':
        return [], 'PVC label velero.io/exclude-from-backup'
    users = [p for p in pods if p['ns'] == pvc['ns'] and pvc['name'] in [c for _, c in p['vols']]]
    if not users:
        return [], 'no pod mounts it'
    users = [p for p in users if p['replicas'] != 0]
    if not users:
        return [], 'workload replicas=0'
    hits, off_r2 = [], []
    for s in schedules:
        inc = s.get('includedNamespaces') or ['*']
        if '*' not in inc and pvc['ns'] not in inc:
            continue
        if pvc['ns'] in (s.get('excludedNamespaces') or []):
            continue
        exres = set(s.get('excludedResources') or [])
        if {'pods', 'persistentvolumeclaims', 'persistentvolumes'} & exres:
            continue
        incres = set(s.get('includedResources') or ['*'])
        if not ('*' in incres or {'pods', 'persistentvolumeclaims'} <= incres):
            continue
        for p in users:
            if p['labels'].get('velero.io/exclude-from-backup') == 'true':
                continue
            sel_ok = match_selector(s.get('labelSelector'), p['labels'])
            ors = s.get('orLabelSelectors')
            if ors:
                sel_ok = any(match_selector(o, p['labels']) for o in ors)
            if not sel_ok:
                continue
            vol = [v for v, c in p['vols'] if c == pvc['name']][0]
            excl = [x.strip() for x in p['ann'].get('backup.velero.io/backup-volumes-excludes', '').split(',')]
            incl = [x.strip() for x in p['ann'].get('backup.velero.io/backup-volumes', '').split(',')]
            if s.get('defaultVolumesToFsBackup') and vol not in excl or vol in incl:
                if s.get('storageLocation') == 'r2':
                    hits.append(s['name'])
                else:
                    off_r2.append('%s@%s' % (s['name'], s.get('storageLocation')))
                break
    if hits:
        return hits, ''
    if off_r2:
        return [], 'only non-R2 Schedules: ' + ','.join(off_r2)
    return [], 'pod not selected by any Schedule'


def longhorn_cover(pvc, scs, rjobs):
    sc_name = pvc['sc'] or next((n for n, s in scs.items() if s['default']), None)
    sc = scs.get(sc_name or '')
    if not sc or sc['provisioner'] != 'driver.longhorn.io':
        return [], 'not Longhorn (%s)' % sc_name
    backup_jobs = [j for j in rjobs if j['task'] == 'backup']
    lab = pvc['labels']
    if lab.get('recurring-job.longhorn.io/source') == 'enabled':
        hits = [j['name'] for j in backup_jobs if lab.get('recurring-job.longhorn.io/' + j['name']) == 'enabled']
        groups = [k.split('/', 1)[1] for k, v in lab.items()
                  if k.startswith('recurring-job-group.longhorn.io/') and v == 'enabled']
        hits += [j['name'] for j in backup_jobs if set(j['groups']) & set(groups)]
        return sorted(set(hits)), '' if hits else 'PVC source labels name no backup job'
    sel = sc['params'].get('recurringJobSelector')
    if sel:
        items = json.loads(sel)
        hits = [j['name'] for j in backup_jobs for it in items
                if (it.get('isGroup') and it['name'] in j['groups']) or (not it.get('isGroup') and it['name'] == j['name'])]
        return hits, '' if hits else 'StorageClass selector names no backup job'
    hits = [j['name'] for j in backup_jobs if 'default' in j['groups']]
    return hits, '' if hits else 'no default-group backup job'


def load_classes():
    out = {}
    path = os.path.join(ROOT, CLASSES_FILE)
    if not os.path.exists(path):
        return out
    for line in open(path):
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.rstrip('\n').split('\t')
        out[(cols[0], cols[1])] = (cols[2], cols[3] if len(cols) > 3 else '')
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    docs_by_root, errors, pending_ns = {}, [], []
    for r in roots():
        docs, err = render_root(r)
        errors += ['%s: %s' % (r, e) for e in err]
        docs_by_root[r] = docs
        for d in list(docs):
            if d.get('kind') == 'Application':
                ext, e = render_external_app(d)
                key = 'Application/' + d['metadata']['name']
                if e:
                    ns = d['spec'].get('destination', {}).get('namespace')
                    pending_ns.append((key, ns, e))
                docs_by_root[key] = ext
            elif d.get('kind') == 'ApplicationSet':
                errors.append('ApplicationSet/%s: generated apps not rendered' % d['metadata']['name'])
    pvcs, pods, schedules, rjobs, scs, clusters, sbs, stores = collect(docs_by_root, errors)
    for key, ns, e in pending_ns:
        names = [x['name'] for x in schedules if ns in (x.get('includedNamespaces') or [])]
        errors.append('%s (namespace %s): %s; PVC inventory unknown; Velero Schedules on the namespace: %s'
                      % (key, ns, e, ', '.join(names) or 'none'))
    classes = load_classes()
    rows = []
    for key in sorted(pvcs):
        p = pvcs[key]
        cover, notes = [], []
        if p['owner'].startswith('CNPG/'):
            cname = p['owner'].split('/', 1)[1]
            c = clusters.get((p['ns'], cname), {})
            wal = stores.get((p['ns'], c.get('wal_store')), '-') if c.get('wal_store') else '-'
            # A plugin ScheduledBackup without barmanObjectName uses the Cluster WAL store.
            sched = [stores.get((p['ns'], s or c.get('wal_store')), '?')
                     for s in sbs.get((p['ns'], cname), [])]
            if wal == 'R2' and 'R2' in sched:
                cover.append('CNPG(R2)')
            else:
                notes.append('CNPG WAL=%s base=%s' % (wal, ','.join(sched) or 'none'))
                if c.get('velero_crash'):
                    # The instance pod is rendered by the CNPG operator, not in Git:
                    # a synthetic pod carrying the cluster label stands for it, so
                    # the same Schedule selection as for any other PVC applies.
                    twin = [dict(ns=p['ns'], owner=p['owner'], labels={'cnpg.io/cluster': cname},
                                 ann={}, vols=[('data', p['name'])], replicas=1, cron=False)]
                    v, why = velero_cover(p, twin, schedules)
                    if v:
                        cover.append('Velero-crash(' + ','.join(v) + ')')
                        notes.append('PVC CNPG: FS backup crash-consistent, restauration non prouvee')
                    else:
                        notes.append('Velero: ' + why)
        else:
            v, why = velero_cover(p, pods, schedules)
            if v:
                cover.append('Velero(' + ','.join(v) + ')')
            else:
                notes.append('Velero: ' + why)
            users = [x for x in pods if x['ns'] == p['ns'] and p['name'] in [c for _, c in x['vols']]]
            lh, why = longhorn_cover(p, scs, rjobs)
            if lh:
                if users and all(u['replicas'] == 0 or u['cron'] for u in users):
                    notes.append('Longhorn(%s) only while attached' % ','.join(lh))
                elif not users:
                    notes.append('Longhorn(%s) but no pod: detached' % ','.join(lh))
                else:
                    cover.append('Longhorn(' + ','.join(lh) + ')')
            else:
                notes.append('Longhorn: ' + why)
            if users and all(u['replicas'] == 0 for u in users if not u['cron']):
                notes.append('workload replicas=0')
        cls, why = classes.get(key, ('UNCLASSIFIED', ''))
        rows.append(dict(ns=p['ns'], pvc=p['name'], sc=p['sc'] or '(default)', size=p['size'],
                         app=p['source'].split('/')[-1] if not p['source'].startswith('Application/') else p['source'],
                         owner=p['owner'], cover=cover, notes=notes, cls=cls, why=why))
    if a.json:
        print(json.dumps(dict(rows=rows, errors=errors), indent=1))
        return
    covered = sum(1 for r in rows if r['cover'])
    at_risk = [r for r in rows if not r['cover'] and r['cls'] == 'IRREPLACEABLE']
    lines = [
        '# Couverture statique des sauvegardes PVC (PLT-222)',
        '',
        'Généré par `just backup-coverage-static` (`scripts/backup-coverage-static.py`). Ne pas éditer à la main.',
        'Niveau de preuve : `STATIC`. Le rendu Git ne prouve ni un volume attaché, ni une sauvegarde `Completed` sur R2.',
        '',
        'Règles : Velero couvre un PVC si un pod qui le monte est sélectionné par un Schedule actif (namespace, labels, `defaultVolumesToFsBackup`). '
        'Longhorn couvre un PVC Longhorn rattaché à un RecurringJob `backup` (labels source, sélecteur de StorageClass ou groupe `default`) et monté par un pod actif '
        '(`allowRecurringJobWhileVolumeDetached: false`). CNPG couvre un PVC de cluster si le WAL et une ScheduledBackup visent un ObjectStore R2. '
        'Un Cluster annoté `backup.smadja.dev/velero-crash-consistent` est crédité `Velero-crash` si un Schedule Velero FS couvre son namespace : '
        'couverture crash-consistent non prouvée par restauration, jamais comptée comme CNPG(R2).',
        '',
        '- PVC déclarés : %d' % len(rows),
        '- PVC couverts vers R2 : %d' % covered,
        '- PVC irremplaçables non couverts : %d' % len(at_risk),
        '',
        '| Namespace | PVC | StorageClass | Taille | Source | Couverture R2 | Écarts | Classe |',
        '|---|---|---|---:|---|---|---|---|',
    ]
    for r in rows:
        lines.append('| %s | %s | %s | %s | %s | %s | %s | %s |' % (
            r['ns'], r['pvc'], r['sc'], r['size'], r['app'], ' + '.join(r['cover']) or '**aucune**',
            '; '.join(r['notes']) or '-', r['cls'] + (' — ' + r['why'] if r['why'] else '')))
    if errors:
        lines += ['', '## Sources non rendues', ''] + ['- ' + e for e in errors]
    text = '\n'.join(lines) + '\n'
    if a.output:
        open(a.output, 'w').write(text)
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
