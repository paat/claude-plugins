#!/usr/bin/env python3
"""Exercise the arbiter's documented pinned lookup and its existing verdict validator."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
skill = (plugin / 'skills/tribunal-loop/SKILL.md').read_text()
collector = (plugin / 'scripts/collect-review-evidence.sh').read_text()
contract = (plugin / 'skills/tribunal-loop/references/output-contract.md').read_text()
marked = skill.split('### Marked Positions (`line_check`)\n', 1)[1].split('\n### ', 1)[0]
validator = re.search(r'^validate_arbitration\(\) \{\n.*?^\}', collector, re.M | re.S).group()
passed = failed = 0


def check(label, assertion):
    global passed, failed
    try:
        assertion()
    except (AssertionError, subprocess.CalledProcessError, ValueError) as error:
        failed += 1
        print(f'FAIL {label}: {error}')
    else:
        passed += 1
        print(f'PASS {label}')


def require(value, message):
    assert value, message


check('arbiter zero-findings shortcut requires produced legs', lambda: require(
    'every non-disabled provider' in skill and 'status == "ok"' in skill,
    'shortcut does not require every non-disabled provider status == "ok"'))
check('human per-leg results distinguish failure from zero findings', lambda: require(
    all(text in contract for text in ('ok, findings=0', 'ok, findings=N', 'failed, findings=unavailable', 'disabled'))
    and all(text in skill for text in ('tribunal_verdict.rationale', 'summary', 'references/output-contract.md')),
    'missing explicit failed-provider reporting and per-leg display contract'))
check('marked position policy reports unavailable pinned evidence', lambda: require(
    all(text in marked for text in ('diff_stat.head_oid', 'git show <head_oid>:<path>',
                                   'never the ambient worktree', 'unavailable', 'report')),
    'marked stanza lacks pinned lookup, reportable missing object, or no-ambient rule'))

with tempfile.TemporaryDirectory(prefix='tribunal-arbiter-') as temporary:
    work = Path(temporary)
    repo = work / 'repo'
    repo.mkdir()

    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    git('init', '-q')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Test User')
    (repo / 'growing.txt').write_text('line\n' * 5)
    (repo / 'deleted.txt').write_text('still present at reviewed head\n')
    git('add', 'growing.txt', 'deleted.txt')
    git('commit', '-qm', 'reviewed tree')
    leg = {'diff_stat': {'head_oid': git('rev-parse', 'HEAD')}}
    (repo / 'growing.txt').write_text('line\n' * 40)
    git('rm', '-q', 'deleted.txt')
    git('commit', '-qam', 'branch advances before arbitration')

    def pinned_lookup():
        require('`git show <head_oid>:<path>`' in marked,
                'no executable pinned lookup in marked-position instruction')
        template = re.search(r'`(git show <head_oid>:<path>)`', marked).group(1)
        blobs = {}
        for path in ('growing.txt', 'deleted.txt'):
            command = template.replace('<head_oid>', leg['diff_stat']['head_oid']).replace('<path>', path)
            blobs[path] = subprocess.check_output(command.split(), cwd=repo, text=True)
        require(len(blobs['growing.txt'].splitlines()) == 5 and
                len((repo / 'growing.txt').read_text().splitlines()) == 40 and
                blobs['deleted.txt'] == 'still present at reviewed head\n' and
                not (repo / 'deleted.txt').exists(), 'documented lookup consulted the wrong tree')

    check('documented lookup reaches pinned blobs after branch grows and deletes files', pinned_lookup)

    def missing_pinned_object():
        require('`git show <head_oid>:<path>`' in marked,
                'no executable pinned lookup in marked-position instruction')
        template = re.search(r'`(git show <head_oid>:<path>)`', marked).group(1)
        unavailable_leg = {'diff_stat': {'head_oid': git(
            'commit-tree', 'HEAD^{tree}', '-m', 'unreferenced reviewed commit')}}
        git('reflog', 'expire', '--expire=now', '--all')
        git('gc', '--prune=now')
        command = template.replace('<head_oid>', unavailable_leg['diff_stat']['head_oid']).replace(
            '<path>', 'growing.txt')
        result = subprocess.run(command.split(), cwd=repo, capture_output=True, text=True)
        require(result.returncode != 0 and not result.stdout and (repo / 'growing.txt').exists(),
                'missing pinned object was replaced by ambient content')

    check('documented lookup fails visibly when pinned object is pruned', missing_pinned_object)

    providers = ('codex', 'gemini', 'glm', 'deepseek', 'qwen', 'grok', 'claude')
    (work / 'providers').mkdir()

    def verdict_case(statuses, decision, confidence, accepts=True, findings=[]):
        manifest = {'repository': {'root': str(repo)}, 'providers': [
            {'provider': name, 'status': statuses.get(name, 'disabled')} for name in providers]}
        (work / 'manifest.json').write_text(json.dumps(manifest))
        for row in manifest['providers']:
            artifact = {'provider': row['provider']}
            if row['status'] == 'failed':
                artifact['error'] = 'fixture transport failure'
            elif row['status'] == 'disabled':
                artifact['status'] = 'disabled'
            else:
                artifact['findings'] = findings if row['provider'] == 'codex' else []
            (work / 'providers' / (row['provider'] + '.json')).write_text(json.dumps(artifact))
        arbitration = {'tribunal_verdict': {'decision': decision, 'confidence': confidence,
                        'rationale': 'GLM failed to produce a review; remaining evidence assessed.'},
                       'findings': [], 'scope_findings': [], 'provider_assessment': {
                           row['provider']: {'findings_accepted': 0, 'findings_rejected': 0,
                                             'false_positives': [], 'status': row['status']}
                           for row in manifest['providers']},
                       'conflicts_resolved': [], 'summary': 'Fixture panel assessment.'}
        (work / 'arbitration.json').write_text(json.dumps(arbitration))
        result = subprocess.run(['bash', '-c', validator + '\nvalidate_arbitration "$1" "$2"',
                                 'fixture', str(work / 'arbitration.json'), str(work / 'manifest.json')],
                                capture_output=True, text=True)
        print(f'validator statuses={statuses} {decision}/{confidence}: exit={result.returncode}')
        require((result.returncode == 0) == accepts,
                f'validator {decision} confidence={confidence}: exit={result.returncode}, accepts={accepts}')

    check('mixed ok and failed panel can retain NEEDS_WORK',
          lambda: verdict_case({'codex': 'ok', 'glm': 'failed'}, 'NEEDS_WORK', 0.7))
    check('healthy empty panel with disabled legs keeps APPROVE shortcut',
          lambda: verdict_case({'codex': 'ok'}, 'APPROVE', 0.95))
    check('all failed panel keeps NEEDS_WORK confidence zero',
          lambda: verdict_case({'codex': 'failed', 'glm': 'failed'}, 'NEEDS_WORK', 0))
    check('failed leg forbids APPROVE confidence 0.95',
          lambda: verdict_case({'codex': 'ok', 'glm': 'failed'}, 'APPROVE', 0.95, accepts=False))
    check('failed leg permits APPROVE confidence 0.90',
          lambda: verdict_case({'codex': 'ok', 'glm': 'failed'}, 'APPROVE', 0.90))
    check('full healthy empty panel rejects APPROVE confidence 0.90',
          lambda: verdict_case(dict.fromkeys(providers, 'ok'), 'APPROVE', 0.90, accepts=False))
    check('healthy panel with findings rejects APPROVE confidence 0.90',
          lambda: verdict_case({'codex': 'ok'}, 'APPROVE', 0.90, accepts=False,
                               findings=[{'file': 'f.txt'}]))

print(f'{passed} PASS / {failed} FAIL')
sys.exit(bool(failed))
