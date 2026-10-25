import platform
import re
from test_gateway import GatewayFixture, ROOT


class VersionTests(GatewayFixture):
    activate_runtime = False

    def test_server_version_endpoint_is_authenticated_and_passive(self):
        self.assertEqual(self.request('GET', '/api/version', auth=False)[0], 401)
        code, version, headers = self.request('GET', '/api/version')
        self.assertEqual(code, 200)
        self.assertRegex(version['version'], r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$')
        expected_version = re.search(r'^version: ([^+\s]+)', (ROOT / 'client/pubspec.yaml').read_text(), re.M)[1]
        self.assertEqual(version['version'], expected_version)
        expected_platform = {'Linux': 'linux', 'Windows': 'windows', 'Darwin': 'macos'}[platform.system()]
        expected_arch = {'x86_64': 'x64', 'AMD64': 'x64', 'aarch64': 'arm64', 'ARM64': 'arm64'}[platform.machine()]
        self.assertEqual(version['platform'], expected_platform)
        self.assertEqual(version['architecture'], expected_arch)
        self.assertEqual(version['packageTarget'], f'{expected_platform}-{expected_arch}' if expected_platform in ('linux', 'windows') else None)
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.assertEqual(self.request('GET', '/api/status')[1]['codex'], 'idle')
        self.assertFalse((self.data / 'rpc-calls.jsonl').exists())
