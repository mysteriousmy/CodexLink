import json, os, socket, subprocess, tempfile, unittest
from pathlib import Path
from test_gateway import COMMAND, GatewayFixture


def lan_address():
    # Choose an actual LAN interface rather than the default VPN/TUN route.
    try:
        adapters = json.loads(subprocess.check_output(['ip','-j','-4','addr','show']))
        for adapter in adapters:
            if 'UP' not in adapter.get('flags',[]): continue
            for address in adapter.get('addr_info',[]):
                value = address['local']; octets = [int(x) for x in value.split('.')]
                if octets[0] == 10 or octets[:2] == [192,168] or octets[0] == 172 and 16 <= octets[1] <= 31:
                    return value
    except (OSError, subprocess.SubprocessError):
        pass
    raise unittest.SkipTest('No private IPv4 LAN interface is available')


class StartupDefaultsTests(unittest.TestCase):
    def test_init_defaults_to_all_ipv4_interfaces(self):
        with tempfile.TemporaryDirectory(prefix='codexlink-init-') as directory:
            result = subprocess.run(COMMAND + ['--init'], env={**os.environ,'CODEXLINK_DATA':directory}, capture_output=True, timeout=15)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            config = json.loads(Path(directory,'config.json').read_text())
            self.assertEqual(config['listenUrl'],'http://0.0.0.0:47821')
            self.assertNotIn('projects',config)
            self.assertEqual(len(Path(directory,'access-token.txt').read_text().strip()),64)


class StartupAddressTests(GatewayFixture):
    def configure_runtime(self, config):
        config['listenUrl'] = f'http://0.0.0.0:{self.port}'
        (self.data/'access-token.txt').write_text(self.token)

    def test_startup_prints_gui_key_and_interface_urls(self):
        self.until(lambda: 'GUI 登录密钥：' in (self.data/'gateway.log').read_text())
        output = (self.data/'gateway.log').read_text()
        self.assertIn('GUI 登录密钥：'+self.token,output)
        self.assertIn(self.base+'/',output)
        self.assertNotIn('?token=',output)
        local = lan_address()
        self.assertIn(f'http://{local}:{self.port}/',output)

    def test_private_lan_login_and_unassigned_host_rejection(self):
        original = self.base
        local = lan_address()
        self.base = f'http://{local}:{self.port}'
        try:
            code, _, headers = self.request('POST','/api/auth/session',{'token':self.token},headers={'Origin':self.base},auth=False)
            self.assertEqual(code,200)
            cookie = headers['Set-Cookie']
            self.assertIn('httponly',cookie.lower())
            self.assertIn('samesite=strict',cookie.lower())
            self.assertNotIn('secure',cookie.lower())
            self.assertEqual(self.request('GET','/api/status',headers={'Cookie':cookie.split(';')[0]},auth=False)[0],200)
        finally:
            self.base = original
        self.assertEqual(self.request('POST','/api/auth/session',{'token':self.token},headers={'Host':f'203.0.113.88:{self.port}','Origin':f'http://203.0.113.88:{self.port}'},auth=False)[1]['code'],'https_required')
        self.assertEqual(self.request('POST','/api/auth/session',{'token':'wrong'},headers={'Origin':self.base},auth=False)[0],401)
