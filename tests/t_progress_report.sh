#!/bin/bash
# The progress-report skill is discoverable by both hosts and its template's data contract matches the skill text.
. "$(dirname "$0")/lib.sh"
python3 - "$T/.." <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ('.claude-plugin/plugin.json', '.codex-plugin/plugin.json'):
    manifest = json.loads((root / name).read_text())
    skill = root / manifest.get('skills', './skills/') / 'progress-report/SKILL.md'
    text = skill.read_text()
    assert re.search(r'^name: progress-report$', text, re.M), name
    assert re.search(r'^description: .*статус с инфографикой', text, re.M), name
print('PASS both hosts discover the progress-report skill')

template = (root / 'skills/progress-report/resources/template.html').read_text()
block = re.search(r'<script type="application/json" id="report">\n(.*?)\n</script>', template, re.S)
assert block, 'template has no report data block'
data = json.loads(block.group(1))
statuses = {'done', 'review', 'active', 'planned', 'decision', 'dropped'}
assert set(data['statuses']) == statuses, data['statuses']
for track in data['tracks']:
    for item in track['items']:
        assert item['status'] in statuses, item
for key in ('eyebrow', 'headline', 'count_format', 'lede', 'tracks', 'road', 'notes', 'foot', 'track_count_format'):
    assert key in data and re.search(rf'`{key}(\[\])?`', text), key
for kind in ('now', 'soon', 'next', 'decision'):
    assert f'.step.{kind} ' in template and f'`{kind}`' in text, kind
for status in statuses:
    assert f'`{status}`' in text, status
print('PASS the template data block parses and every key, status and step kind is documented')

# Data is rendered as text: the renderer never assigns HTML from the report.
script = template.split('id="report">', 1)[1]
assert 'innerHTML' not in script and 'insertAdjacentHTML' not in script and 'document.write' not in script
print('PASS the renderer builds the page from text nodes only')
PY
