#!/usr/bin/env bash
# Package controls run in isolation; they never install into the owner's Codex home.
set -euo pipefail
. "$(dirname "$0")/isolate.sh"   # no test touches the real HOME or registry of homes
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" <<'PY'
import copy, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / '.codex-plugin/plugin.json').read_text())
claude = json.loads((root / '.claude-plugin/plugin.json').read_text())
market = json.loads((root / '.agents/plugins/marketplace.json').read_text())

def validate(m):
    assert m['name'] == claude['name'], 'engine manifests must share identity'
    assert m['version'] == claude['version'], 'engine manifests must share version'
    assert m['skills'] == './skills/'
    assert m['hooks'] == './hooks/codex-hooks.json', 'explicit Codex hooks must replace default Claude discovery'
    for key in ('skills', 'hooks'):
        assert m[key].startswith('./') and '..' not in pathlib.PurePosixPath(m[key]).parts
        assert (root / m[key]).exists(), f'missing {key} resource'
    hooks = json.loads((root / m['hooks']).read_text())['hooks']
    assert 'SessionStart' in hooks and 'PreToolUse' in hooks
    assert not (root / m['skills'] / 'agent-top').exists(), 'agent-top is a Claude Code mod and console, not a skill'
    for skill in ('hub', 'handoff', 'setup', 'delegation', 'status'):
        text = (root / m['skills'] / skill / 'SKILL.md').read_text()
        assert text.startswith('---\n') and re.search(r'^name: ' + skill + r'$', text, re.M)
        assert 'PLUGIN_ROOT' in text, f'{skill} must support native Codex root'

validate(manifest)
print('PASS native manifest identity, resources and five skills')
for label, change in (
    ('implicit Claude hooks', lambda m: m.pop('hooks')),
    ('wrong engine hooks', lambda m: m.update(hooks='./hooks/hooks.json')),
    ('missing skill directory', lambda m: m.update(skills='./missing-skills/')),
    ('version drift', lambda m: m.update(version='0.0.0')),
):
    bad = copy.deepcopy(manifest)
    change(bad)
    try:
        validate(bad)
    except (AssertionError, KeyError):
        print('PASS reject ' + label)
    else:
        raise AssertionError('negative control accepted: ' + label)
assert market['name'] == 'delamain-codex'
entry = next(p for p in market['plugins'] if p['name'] == manifest['name'])
assert entry['source'] == {'source': 'local', 'path': './'}
print('PASS native marketplace resolves repository root')
for effort in ('low', 'medium', 'high', 'xhigh'):
    raw = (root / 'skills/setup/resources/codex-agents' / f'worker-{effort}.toml').read_text()
    try:
        import tomllib
    except ImportError:  # Packaging may be inspected on Claude's Python 3.10; Codex runtime needs 3.11+.
        assert raw.count('"""') == 2
        parsed = dict(re.findall(r'^(\w+) = "([^"\n]*)"$', raw, re.M))
        parsed['developer_instructions'] = raw.split('"""')[1]
    else:
        parsed = tomllib.loads(raw)
    assert parsed['name'] == f'worker-{effort}'
    assert parsed['description'] and parsed['developer_instructions']
    assert parsed['model_reasoning_effort'] == effort
    assert 'model' not in parsed, 'resource must inherit chosen available model'
print('PASS native worker definitions pin effort and inherit model')
PY

if command -v codex >/dev/null 2>&1; then
  export CODEX_HOME="$TASK_TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  codex plugin marketplace add "$ROOT" --json > "$TASK_TMP/marketplace.json"
  codex plugin add delamain@delamain-codex --json > "$TASK_TMP/install.json"
  python3 - "$TASK_TMP/install.json" <<'PY'
import json, pathlib, sys
installed = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert installed['pluginId'] == 'delamain@delamain-codex'
root = pathlib.Path(installed['installedPath'])
manifest = json.loads((root / '.codex-plugin/plugin.json').read_text())
assert (root / manifest['hooks']).is_file()
assert (root / manifest['skills'] / 'hub/SKILL.md').is_file()
assert (root / manifest['skills'] / 'status/SKILL.md').is_file()
assert (root / 'bin/agent').is_file()
print('PASS actual Codex marketplace install includes hooks, skills and launcher')
PY
else
  echo 'SKIP actual install: codex CLI unavailable (package controls passed)'
fi
