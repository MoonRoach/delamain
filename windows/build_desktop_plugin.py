"""Build a native Codex envelope around the unchanged Delamain core."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

VERSION = '1.0.9-wsl.1'
ADAPTERS = ('desktop.ps1', 'agent-top.ps1', 'desktop_hook.ps1', 'desktop_runtime.py',
            'desktop_codex.py', 'desktop_skill_prelude.md', 'process_transport.ps1',
            'worker_proxy.py', 'proxy_tcp.ps1')


def build(source: Path, destination: Path, settings: dict) -> dict:
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('Use a new empty build directory; existing packages are never deleted.')
    destination.mkdir(parents=True, exist_ok=True)
    originals = {}
    for directory in ('bin', 'hooks', 'skills', 'agents', 'templates', 'docs'):
        shutil.copytree(source / directory, destination / directory,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for path in (destination / 'bin').rglob('*'):
        if path.is_file(): originals[str(path.relative_to(destination))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for path in (destination / 'hooks').glob('*.py'):
        originals[str(path.relative_to(destination))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (destination / 'windows').mkdir()
    for name in ADAPTERS:
        shutil.copy2(source / 'windows' / name, destination / 'windows' / name)
        if name in ('desktop_codex.py', 'worker_proxy.py'):
            path = destination / 'windows' / name
            path.chmod(path.stat().st_mode | 0o111)
    (destination / 'windows/desktop-config.json').write_text(json.dumps(settings, indent=2), encoding='utf-8')
    manifest = json.loads((source / '.codex-plugin/plugin.json').read_text(encoding='utf-8'))
    manifest['version'] = VERSION
    (destination / '.codex-plugin').mkdir()
    (destination / '.codex-plugin/plugin.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    hooks_path = destination / 'hooks/codex-hooks.json'
    hook_config = json.loads(hooks_path.read_text(encoding='utf-8'))
    for groups in hook_config['hooks'].values():
        for group in groups:
            for handler in group['hooks']:
                match = re.search(r'/hooks/([a-z_]+)\.py', handler['command'])
                if not match: raise ValueError(f'Unknown original hook: {handler["command"]}')
                suffix = handler['command'].split('.py"', 1)[1].strip()
                command = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'
                           "& (Join-Path $env:PLUGIN_ROOT 'windows/desktop_hook.ps1') -Hook " + match[1])
                if suffix:
                    command += " -HookArgs '" + suffix + "'"
                handler['commandWindows'] = command + '"'
                # Original dispatch and timeouts are retained, with transport time
                # allowed for WSL startup before the unchanged original hook runs.
                handler['timeout'] = max(handler.get('timeout', 10), 20)
    hooks_path.write_text(json.dumps(hook_config, indent=2), encoding='utf-8')
    prelude = (source / 'windows/desktop_skill_prelude.md').read_text(encoding='utf-8')
    skill_proof = {}
    for skill in (destination / 'skills').glob('*/SKILL.md'):
        original = skill.read_text(encoding='utf-8')
        header = re.match(r'\A---\r?\n.*?\r?\n---\r?\n', original, re.S)
        if not header: raise ValueError(f'Missing frontmatter: {skill}')
        skill.write_text(original[:header.end()] + '\n' + prelude + '\n\n' + original[header.end():], encoding='utf-8')
        assert skill.read_text(encoding='utf-8').endswith(original[header.end():])
        skill_proof[str(skill.relative_to(destination))] = hashlib.sha256(original.encode()).hexdigest()
    (destination / '.agents/plugins').mkdir(parents=True)
    marketplace = {'name': 'delamain-windows', 'plugins': [{'name': 'delamain',
        'source': {'source': 'local', 'path': './'},
        'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'}, 'category': 'Productivity'}]}
    (destination / '.agents/plugins/marketplace.json').write_text(json.dumps(marketplace, indent=2), encoding='utf-8')
    for name, digest in originals.items():
        assert hashlib.sha256((source / name).read_bytes()).hexdigest() == digest, name
    receipt = {'version': VERSION, 'core_hashes': originals, 'original_skill_hashes': skill_proof,
               'changes': ['Windows command handlers', 'transport prelude', 'adapter files'],
               'core_unchanged': True}
    (destination / 'windows/build-receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--settings', type=Path, required=True)
    args = parser.parse_args()
    proof = build(args.source, args.output, json.loads(args.settings.read_text(encoding='utf-8-sig')))
    print(json.dumps({'version': proof['version'], 'unchanged_core_files': len(proof['core_hashes']),
                      'skills': len(proof['original_skill_hashes']), 'output': str(args.output)}))
