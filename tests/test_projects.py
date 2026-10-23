import json, urllib.parse, uuid
from test_gateway import GatewayFixture


class ProjectTests(GatewayFixture):
    def test_codex_projects(self):
        code, projects, _ = self.request('GET', '/api/projects')
        self.assertEqual(code, 200)
        self.assertEqual([p['name'] for p in projects], ['Codex fixture project'])
        self.assertNotIn('test', [p['id'] for p in projects])
        for name in ['One', 'Two', 'Three']:
            self.request('POST', '/api/projects', {'name':name, 'path':str(self.data), 'requestId':str(uuid.uuid4())})
        projects = self.request('GET', '/api/projects')[1]
        self.assertEqual(len(projects), 4)
        self.assertEqual(self.calls('project/list')[-1]['params']['cursor'], '2')
        self.assertFalse(any(c['params'].get('cwd') for c in self.calls('project/list')))

    def test_project_creation(self):
        root = self.data/'new workspace'; root.mkdir()
        body = {'name':'新项目', 'path':str(root), 'requestId':str(uuid.uuid4())}
        code, result, _ = self.request('POST', '/api/projects', body)
        self.assertEqual(code, 201)
        project = result['project']
        self.assertEqual(project['name'], '新项目')
        self.assertEqual(project['roots'], [{'path':str(root)}])
        self.assertEqual(self.request('POST', '/api/projects', body)[1]['project']['id'], project['id'])
        code, result, _ = self.request('POST', '/api/threads', {'projectId':project['id'], 'path':str(root)})
        self.assertEqual(code, 201)
        self.assertEqual(result['thread']['cwd'], str(root))
        self.assertEqual(result['thread']['projectId'], project['id'])
        start = self.calls('thread/start')[-1]['params']
        self.assertEqual(start['runtimeWorkspaceRoots'], [str(root)])
        self.assertEqual(start['sandbox'], 'workspace-write')
        self.assertEqual(start['approvalPolicy'], 'on-request')
        self.assertEqual(self.request('POST', '/api/threads', {'projectId':project['id'], 'path':str(self.data)})[1]['code'], 'invalid_project_root')
        for invalid in ['relative', '/bad\0path']:
            self.assertEqual(self.request('POST', '/api/threads', {'projectId':project['id'], 'path':invalid})[0],400)
        for key, value, expected in [('name',' ',400),('path',str(self.data/'missing'),404),('requestId','bad',400)]:
            self.assertEqual(self.request('POST', '/api/projects', {**body,key:value})[0], expected)

    def test_directory_navigation(self):
        root = self.data/'picker'; root.mkdir()
        (root/'child').mkdir(); (root/'child'/'nested').mkdir(); (root/'.hidden').mkdir()
        (root/'file.txt').write_text('not a directory')
        def listing(path, more=''):
            return self.request('GET', '/api/directories?path='+urllib.parse.quote(str(path))+more)
        self.assertEqual(self.request('GET', '/api/directories', auth=False)[0], 401)
        first = listing(root)[1]
        self.assertEqual([e['name'] for e in first['entries']], ['child'])
        second = listing(first['entries'][0]['path'])[1]
        self.assertEqual(second['parentPath'], str(root))
        self.assertEqual(second['entries'][0]['name'], 'nested')
        self.assertEqual([e['name'] for e in listing(root,'&hidden=true')[1]['entries']], ['.hidden','child'])
        for i in range(205): (root/f'item-{i:03}').mkdir()
        first = listing(root,'&search=item-')[1]
        self.assertEqual(len(first['entries']), 200)
        self.assertEqual(first['nextOffset'], 200)
        last = listing(root,'&search=item-&offset=200')[1]
        self.assertEqual(len(last['entries']), 5)
        self.assertIsNone(last['nextOffset'])
        self.assertEqual(listing(root/'missing')[0], 404)
        self.assertEqual(listing('relative')[0], 400)
        self.assertEqual(listing(root,'&offset=-1')[0], 400)
        code, created, _ = self.request('POST','/api/directories',{'parentPath':str(root),'name':'created'})
        self.assertEqual(code, 201)
        self.assertTrue((root/'created').is_dir())
        self.assertEqual(created['path'], str(root/'created'))
        self.assertEqual(self.request('POST','/api/directories',{'parentPath':str(root),'name':'created'})[0],409)
        self.assertEqual(self.request('POST','/api/directories',{'parentPath':str(root),'name':'../escape'})[0],400)

    def test_directory_thread(self):
        root = self.data/'direct'; root.mkdir()
        code, result, _ = self.request('POST','/api/threads',{'path':str(root)})
        self.assertEqual(code, 201)
        self.assertEqual(result['thread']['cwd'], str(root))
        self.assertIsNone(result['thread']['projectId'])
        self.assertNotIn('projectId', self.calls('thread/start')[-1]['params'])
        self.assertEqual(self.request('POST','/api/threads',{'path':str(root/'missing')})[0],404)
        self.assertEqual(self.request('POST','/api/threads',{})[0],400)
        config = json.loads((self.data/'config.json').read_text())
        self.assertEqual(config['projects'][0]['name'], 'Test')
        self.assertEqual(len(self.calls('project/create')),0)


class NoConfiguredProjectsTests(GatewayFixture):
    def configure_runtime(self, config):
        config.pop('projects')
    def test_startup_without_gateway_projects(self):
        self.assertEqual(self.request('GET','/api/projects')[1][0]['id'],'codex-project')
        self.assertEqual(self.request('POST','/api/threads',{'path':str(self.data)})[0],201)
