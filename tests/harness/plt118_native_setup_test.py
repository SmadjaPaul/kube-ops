"""Offline regression checks for PLT-118 native one-shot configuration."""
import importlib.util
import os
import pathlib
import unittest
from unittest.mock import patch

modpath = pathlib.Path(__file__).resolve().parents[2] / 'scripts/media/plt118-native-setup.py'
spec = importlib.util.spec_from_file_location('native_media_setup', modpath)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class FakeJellyfin:
    def __init__(self, existing=None):
        self.items = existing or []
        self.posted = []
    def call(self, method, path, payload=None, params=None, statuses=(200,)):
        if method == 'GET':
            return self.items
        self.posted.append((path, payload, params))
        self.items.append({'Name':params['name'], 'CollectionType':params['collectionType'], 'Locations':params['paths']})

class FakeArr:
    def __init__(self, folder, quality='1080p'):
        self.folder = folder
        self.token = 'test-placeholder'
        self.quality = quality
    def call(self, method, path, *a, **kw):
        if path.endswith('qualityprofile'):
            return [{'id': 7, 'name': self.quality}]
        if path.endswith('rootfolder'):
            return [{'path': self.folder}]
        raise AssertionError(path)

class FakeSeerr:
    def __init__(self, existing=None):
        self.saved = existing or {'radarr': [], 'sonarr': []}
        self.calls = []
    def call(self, method, path, payload=None, params=None, statuses=(200,)):
        app = path.split('/')[-1]
        if method == 'GET':
            return self.saved[app]
        self.calls.append((app, payload))
        self.saved[app].append(payload)

class TestNative(unittest.TestCase):
    def test_jellyfin_plans_without_mutation_and_apply_once(self):
        a = FakeJellyfin()
        m.jellyfin_libraries(a, False)
        self.assertEqual(0, len(a.posted))
        m.jellyfin_libraries(a, True)
        self.assertEqual(2, len(a.posted))
        m.jellyfin_libraries(a, True)
        self.assertEqual(2, len(a.posted))

    def test_jellyfin_conflict_blocks(self):
        a = FakeJellyfin([{'Name':'Other', 'CollectionType':'movies', 'Locations':['/data/media/movies']}])
        with self.assertRaisesRegex(RuntimeError, 'already owned'):
            m.jellyfin_libraries(a, True)
        self.assertFalse(a.posted)

    def test_seerr_creates_only_after_both_profile_checks(self):
        a = FakeSeerr()
        r = FakeArr('/data/media/movies')
        s = FakeArr('/data/media/tv')
        with patch.dict(os.environ, {'RADARR_PROFILE_NAME':'1080p', 'SONARR_PROFILE_NAME':'1080p'}):
            m.seerr_servers(a, r, s, False)
            self.assertFalse(a.calls)
            m.seerr_servers(a, r, s, True)
            self.assertEqual(['radarr','sonarr'], [x[0] for x in a.calls])
            self.assertTrue(all(x[1]['preventSearch'] for x in a.calls))
            m.seerr_servers(a, r, s, True)
            self.assertEqual(2, len(a.calls))

    def test_seerr_profile_missing_never_mutates(self):
        a = FakeSeerr()
        with patch.dict(os.environ, {'RADARR_PROFILE_NAME':'1080p', 'SONARR_PROFILE_NAME':'missing'}):
            with self.assertRaisesRegex(RuntimeError, 'quality profile'):
                m.seerr_servers(a, FakeArr('/data/media/movies'), FakeArr('/data/media/tv'), True)
        self.assertFalse(a.calls)

    def test_seerr_existing_different_default_blocks(self):
        a = FakeSeerr({'radarr':[{'id':0,'hostname':'other','port':7878,'isDefault':True,'is4k':False}], 'sonarr':[]})
        with patch.dict(os.environ, {'RADARR_PROFILE_NAME':'1080p', 'SONARR_PROFILE_NAME':'1080p'}):
            with self.assertRaisesRegex(RuntimeError, 'other default'):
                m.seerr_servers(a, FakeArr('/data/media/movies'), FakeArr('/data/media/tv'), True)
        self.assertFalse(a.calls)

if __name__ == '__main__':
    unittest.main()
