#!/usr/bin/env python3
"""Synthetic, model-free transport checks; optional raw artifacts directory."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
ARTIFACTS = Path(os.environ.get('TRIBUNAL_TEST_ARTIFACTS', tempfile.mkdtemp()))
ARTIFACTS.mkdir(parents=True, exist_ok=True)

MOCK = '''#!/usr/bin/env python3
import hashlib, json, os, pathlib, re, subprocess, sys
if sys.argv[1:3] == ['auth', 'status']:
    print('{"loggedIn":true}'); sys.exit(0)
p = sys.stdin.read()
d = pathlib.Path(os.environ['CASE_DIR'])
(d/'stdin').write_text(p)
(d/'argv.json').write_text(json.dumps(sys.argv[1:]))
(d/'cwd').write_text(os.getcwd())
m = re.search(r'^Diff file: (.+)$', p, re.M)
if m:
    diff = pathlib.Path(m[1]).read_bytes()
    (d/'diff.json').write_text(json.dumps({'bytes':len(diff), 'sha256':hashlib.sha256(diff).hexdigest()}))
    if pathlib.Path('file.txt').exists(): (d/'tree.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(), 'file':pathlib.Path('file.txt').read_text(), 'env':pathlib.Path('.env').exists(), 'ignored_env':pathlib.Path('ignored/.env').exists()}))
review = {'provider':'forged','model':'forged','files_examined':['file.txt'], 'findings':[], 'summary':{'total_findings':0,'critical':0,'high':0,'medium':0,'low':0,'quality_score':10,'verdict':'APPROVE'}}
mode = os.environ.get('CASE_MODE','ok')
if mode == 'line':
    review['findings'] = [{'severity':'medium','category':'logic','file':'file.txt','line':3,'title':'synthetic','description':'synthetic','suggestion':'synthetic','confidence':0.9}]
    review['summary'].update(total_findings=1, medium=1)
result = {'structured_output':review}
if mode in ('failure','envelope-error'):
    result.update(is_error=True, result='Prompt is too long')
if mode == 'malformed': result = {'result':'not a review'}
out = json.dumps(result)
err = 'synthetic CLI error' if mode == 'failure' else ''
rc = 1 if mode == 'failure' else 0
(d/'cli.stdout').write_text(out+'\\n'); (d/'cli.stderr').write_text(err)
(d/'cli.exit').write_text(str(rc))
print(out); sys.stderr.write(err); sys.exit(rc)
'''


class Transport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.repo = cls.root/'repo'
        cls.repo.mkdir()
        cls.bin = cls.root/'bin'
        cls.bin.mkdir()
        (cls.bin/'claude').write_text(MOCK)
        (cls.bin/'claude').chmod(0o755)
        cls.env = dict(os.environ, PATH=str(cls.bin)+':'+os.environ['PATH'],
                       TRIBUNAL_CLAUDE='on', TRIBUNAL_BASE_BRANCH='main',
                       TRIBUNAL_BASE_REF='main', TRIBUNAL_DIFF_LIMIT_BYTES='7340032',
                       TRIBUNAL_CLAUDE_MODEL='fixture-model', TRIBUNAL_CLAUDE_EFFORT='xhigh')
        cls.git('init', '-q', '-b', 'main')
        cls.git('config', 'user.name', 'Synthetic Test')
        cls.git('config', 'user.email', 'test@example.invalid')
        (cls.repo/'file.txt').write_text('base\n')
        (cls.repo/'.gitignore').write_text('ignored/\n')
        cls.git('add', '.')
        cls.git('commit', '-qm', 'base')
        cls.base = cls.git('rev-parse', 'HEAD').strip()
        cls.git('checkout', '-qb', 'review')
        (cls.repo/'file.txt').write_text('one\ntwo\n')
        (cls.repo/'large.txt').write_text('synthetic payload '+ 'x'*80 + '\n')
        (cls.repo/'large.txt').write_text((cls.repo/'large.txt').read_text()*68000)
        cls.git('add', '.')
        cls.git('commit', '-qm', 'review')
        cls.head = cls.git('rev-parse', 'HEAD').strip()
        cls.diff = cls.git('diff', cls.base+'...'+cls.head, '--no-ext-diff', '--no-textconv').encode()
        (cls.repo/'file.txt').write_text('dirty\n'*10)
        (cls.repo/'.env').write_text('SYNTHETIC_SECRET=not-real\n')
        (cls.repo/'ignored').mkdir()
        (cls.repo/'ignored/.env').write_text('SYNTHETIC_SECRET=also-not-real\n')

    @classmethod
    def git(cls, *args):
        return subprocess.check_output(['git', '-C', str(cls.repo), *args], text=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_leg(self, mode='ok', smoke=False, **overrides):
        case = ARTIFACTS/self.id().split('.')[-1]
        case.mkdir(exist_ok=True)
        env = dict(self.env, CASE_DIR=str(case), CASE_MODE=mode, **overrides)
        argv = ['bash', str(PLUGIN/'scripts/run-claude-review.sh')]+(['--smoke'] if smoke else [])
        result = subprocess.run(argv, cwd=self.repo, env=env, capture_output=True, timeout=30)
        (case/'runner.json').write_text(json.dumps({'argv':argv,'cwd':str(self.repo),'exit':result.returncode}))
        (case/'stdout').write_bytes(result.stdout)
        (case/'stderr').write_bytes(result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.repo.is_dir(), 'cleanup deleted user checkout')
        return json.loads(result.stdout), case

    def test_large_complete_pinned_readonly(self):
        result, case = self.run_leg()
        self.assertNotIn('error', result)
        prompt = (case/'stdin').read_bytes()
        self.assertLess(len(prompt), 24000)
        diff = json.loads((case/'diff.json').read_text())
        self.assertGreater(diff['bytes'], 6000000)
        self.assertEqual(diff['sha256'], hashlib.sha256(self.diff).hexdigest())
        tree = json.loads((case/'tree.json').read_text())
        self.assertEqual(tree, {'head':self.head,'file':'one\ntwo\n','env':False,'ignored_env':False})
        args = json.loads((case/'argv.json').read_text())
        for flag in ('--safe-mode','--restricted','--strict-mcp-config','--disable-slash-commands','--no-session-persistence','--no-chrome'):
            self.assertIn(flag, args)
        for flag, value in {'--tools':'Read,Glob,Grep','--allowedTools':'Read,Glob,Grep', '--permission-mode':'dontAsk','--setting-sources':'','--mcp-config':'{"mcpServers":{}}','--model':'fixture-model','--effort':'xhigh'}.items():
            self.assertEqual(args[args.index(flag)+1], value)
        self.assertIn('untrusted', args[args.index('--append-system-prompt')+1])
        self.assertEqual(result['provider'], 'claude')
        self.assertEqual(result['diff_stat']['base_oid'], self.base)
        self.assertEqual(result['diff_stat']['head_oid'], self.head)
        self.assertFalse(result['diff_stat']['truncated'])
        self.assertFalse(Path((case/'cwd').read_text()).exists())

    def test_smoke_tiny_no_tools(self):
        result, case = self.run_leg(smoke=True)
        self.assertNotIn('error', result)
        args = json.loads((case/'argv.json').read_text())
        self.assertEqual(args[args.index('--tools')+1], '')
        self.assertLess((case/'stdin').stat().st_size, 1000)
        self.assertNotIn('diff_stat', result)
        self.assertFalse((case/'diff.json').exists())

    def test_execution_failure(self):
        result, _ = self.run_leg(mode='failure')
        self.assertIn('error', result)
        self.assertNotIn('summary', result)

    def test_error_envelope_is_not_approval(self):
        result, _ = self.run_leg(mode='envelope-error')
        self.assertIn('error', result)

    def test_malformed_is_not_approval(self):
        result, _ = self.run_leg(mode='malformed')
        self.assertIn('error', result)

    def test_truncation_refused(self):
        result, case = self.run_leg(TRIBUNAL_DIFF_LIMIT_BYTES='1000')
        self.assertIn('error', result)
        self.assertFalse((case/'argv.json').exists())

    def test_linecheck_uses_pinned_tree(self):
        result, _ = self.run_leg(mode='line')
        self.assertIn('out of bounds', result['findings'][0]['line_check'])

    def test_haiku_omits_effort(self):
        result, case = self.run_leg(smoke=True, TRIBUNAL_CLAUDE_MODEL='fixture-haiku')
        self.assertNotIn('--effort', json.loads((case/'argv.json').read_text()))
        self.assertNotIn('error', result)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
