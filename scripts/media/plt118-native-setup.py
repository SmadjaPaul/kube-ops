#!/usr/bin/env python3
"""PLT-118: bounded operator-run native API configuration for Jellyfin and Seerr.

No Kubernetes control loops, no edits to on-disk settings, no media requests.
No network calls at module import. Dry-run is the default.
"""
import argparse
import json
import os
from urllib import error, parse, request


class NativeAPI:
    def __init__(self, url, token, key_header):
        if not url.startswith(('http://', 'https://')) or not token:
            raise ValueError('API URL and existing credential are required')
        self.url = url.rstrip('/')
        self.token = token
        self.key_header = key_header

    def call(self, method, path, payload=None, params=None, statuses=(200,)):
        url = self.url + path
        if params:
            url += '?' + parse.urlencode(params, doseq=True)
        headers = {self.key_header: self.token, 'Accept': 'application/json'}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode('utf-8')
            headers['Content-Type'] = 'application/json'
        req = request.Request(url, data=data, method=method, headers=headers)
        try:
            with request.urlopen(req, timeout=15) as resp:
                if resp.status not in statuses:
                    raise RuntimeError(f'HTTP {resp.status} on {method} {path}')
                raw = resp.read()
                return json.loads(raw) if raw else None
        except error.HTTPError as exc:
            # Never log response bodies or Authorization/API keys.
            raise RuntimeError(f'HTTP {exc.code} on {method} {path}') from None
        except error.URLError:
            raise RuntimeError(f'connection failed on {method} {path}') from None


def require(name):
    value = os.environ.get(name, '').strip()
    if not value:
        raise RuntimeError(f'missing required environment variable {name}')
    return value


def jellyfin_libraries(api, apply):
    desired = {'Films': ('movies', '/data/media/movies'),
               'Séries': ('tvshows', '/data/media/tv')}
    current = api.call('GET', '/Library/VirtualFolders')
    if not isinstance(current, list):
        raise RuntimeError('Jellyfin returned an unexpected library list')
    for name, (type_, path) in desired.items():
        matches = [l for l in current if l.get('Name') == name]
        path_users = [l for l in current if path in (l.get('Locations') or [])]
        if len(matches) > 1 or len(path_users) > 1:
            raise RuntimeError(f'ambiguous library or duplicate path: {name}')
        if matches:
            item = matches[0]
            if item.get('CollectionType') != type_ or set(item.get('Locations') or []) != {path}:
                raise RuntimeError(f'existing library conflicts with desired path/type: {name}')
            print(f'JELLYFIN_LIBRARY={name} NO_CHANGES')
            continue
        if path_users:
            raise RuntimeError(f'path already owned by another library: {path}')
        print(f'JELLYFIN_LIBRARY={name} WOULD_CREATE' if not apply else f'JELLYFIN_LIBRARY={name} CREATING')
        if apply:
            api.call('POST', '/Library/VirtualFolders',
                     {'LibraryOptions': {'PathInfos': [{'Path': path}]}},
                     {'name': name, 'collectionType': type_, 'paths': [path], 'refreshLibrary': 'false'},
                     statuses=(200, 204))
            refreshed = api.call('GET', '/Library/VirtualFolders')
            if not any(l.get('Name') == name and l.get('CollectionType') == type_
                       and path in (l.get('Locations') or []) for l in refreshed):
                raise RuntimeError(f'Jellyfin library not verified after create: {name}')
            current = refreshed
            print(f'JELLYFIN_LIBRARY={name} PASS')


def one_profile(arr, expected_name, folder):
    profiles = arr.call('GET', '/api/v3/qualityprofile')
    roots = arr.call('GET', '/api/v3/rootfolder')
    if not isinstance(profiles, list) or not isinstance(roots, list):
        raise RuntimeError('unexpected Arr profiles/root folders')
    eligible = [p for p in profiles if p.get('name') == expected_name]
    if len(eligible) != 1 or not isinstance(eligible[0].get('id'), int):
        raise RuntimeError(f'quality profile missing or ambiguous: {expected_name}')
    if sum(root.get('path') == folder for root in roots) != 1:
        raise RuntimeError(f'root folder missing or ambiguous: {folder}')
    return eligible[0]['id']


def seerr_servers(seerr, radarr, sonarr, apply):
    specs = [
        ('radarr', radarr, 'radarr.media.svc.cluster.local', 7878,
         '/data/media/movies', require('RADARR_PROFILE_NAME')),
        ('sonarr', sonarr, 'sonarr.media.svc.cluster.local', 8989,
         '/data/media/tv', require('SONARR_PROFILE_NAME')),
    ]
    # Validate both remote targets and profile choices BEFORE any write.
    targets = []
    for app, api, hostname, port, folder, profile in specs:
        profile_id = one_profile(api, profile, folder)
        existing = seerr.call('GET', '/api/v1/settings/' + app)
        if not isinstance(existing, list):
            raise RuntimeError(f'unexpected Seerr {app} settings')
        equivalent = [e for e in existing if e.get('hostname') == hostname and e.get('port') == port]
        if len(equivalent) > 1:
            raise RuntimeError(f'duplicate Seerr {app} service')
        if equivalent:
            record = equivalent[0]
            if (record.get('activeProfileId') != profile_id
                    or record.get('activeDirectory') != folder
                    or record.get('apiKey') != api.token
                    or not record.get('isDefault')):
                raise RuntimeError(f'existing Seerr {app} config conflicts with desired state')
            targets.append((app, 'noop', None))
        else:
            if any(e.get('isDefault') and not e.get('is4k') for e in existing):
                raise RuntimeError(f'other default Seerr {app} exists; operator review required')
            body = {
                'name': 'Main ' + app.title(), 'hostname': hostname, 'port': port,
                'apiKey': api.token, 'useSsl': False, 'baseUrl': '',
                'activeProfileId': profile_id, 'activeProfileName': profile,
                'activeDirectory': folder, 'is4k': False, 'isDefault': True,
                'syncEnabled': False, 'preventSearch': True,
            }
            if app == 'radarr':
                body['minimumAvailability'] = 'released'
            else:
                body['enableSeasonFolders'] = True
            targets.append((app, 'create', body))
    for app, action, body in targets:
        if action == 'noop':
            print(f'SEERR_{app.upper()}=NO_CHANGES')
            continue
        print(f'SEERR_{app.upper()}=' + ('CREATING' if apply else 'WOULD_CREATE'))
        if apply:
            # No response body printed, because it contains apiKey.
            seerr.call('POST', '/api/v1/settings/' + app, body, statuses=(200, 201))
            actual = seerr.call('GET', '/api/v1/settings/' + app)
            if sum(e.get('hostname') == body['hostname'] and e.get('port') == body['port']
                   and e.get('activeDirectory') == body['activeDirectory'] for e in actual) != 1:
                raise RuntimeError(f'Seerr {app} creation not verified')
            print(f'SEERR_{app.upper()}=PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=('jellyfin', 'seerr'))
    parser.add_argument('--apply', action='store_true', help='perform only missing creates after safe plan')
    args = parser.parse_args()
    if args.target == 'jellyfin':
        jellyfin_libraries(NativeAPI(require('JELLYFIN_URL'), require('JELLYFIN_API_KEY'), 'X-Emby-Token'), args.apply)
    else:
        s = NativeAPI(require('SEERR_URL'), require('SEERR_API_KEY'), 'X-Api-Key')
        r = NativeAPI(require('RADARR_URL'), require('RADARR_API_KEY'), 'X-Api-Key')
        so = NativeAPI(require('SONARR_URL'), require('SONARR_API_KEY'), 'X-Api-Key')
        seerr_servers(s, r, so, args.apply)
    print('PLT118_NATIVE_CONFIG=' + ('APPLIED' if args.apply else 'DRY_RUN'))


if __name__ == '__main__':
    main()
