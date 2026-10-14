#!/bin/bash
# The hub skill is a core plus on-demand references (skills/hub/references/): every hub pays for the core on every call, so the
# core stays under a size budget, every reference is named in it, every section of the former single file is still reachable
# from it, and every link into the skill — inside it and from the other Markdown of the repository — resolves, anchors included.
. "$(dirname "$0")/lib.sh"
python3 -I - "$T/.." <<'PY'
import pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
skill_dir = root / 'skills/hub'
core = skill_dir / 'SKILL.md'
refs = sorted((skill_dir / 'references').glob('*.md'))
failed = []
def check(ok, label):
    print(('PASS ' if ok else 'FAIL ') + label)
    if not ok:
        failed.append(label)

def slug(heading):
    s = re.sub(r'[`*]', '', heading).strip().lower()
    return re.sub(r'[^\w\- ]', '', s).replace(' ', '-')
def anchors(path):
    return {slug(m.group(1)) for m in re.finditer(r'(?m)^#{1,6} (.+)$', path.read_text(encoding='utf-8'))}
def broken_links(path):
    """Local Markdown links of one file whose target file or heading anchor does not exist."""
    bad = []
    for m in re.finditer(r'\]\(([^)\s]+)\)', path.read_text(encoding='utf-8')):
        target = m.group(1)
        if re.match(r'[a-z]+:', target):
            continue
        name, _, frag = target.partition('#')
        dest = (path.parent / name).resolve() if name else path
        if not dest.is_file() or (frag and frag not in anchors(dest)):
            bad.append(target)
    return bad

# size budget: the former single file was 47008 bytes; the core carries a margin for what is still to be added to it
size = core.stat().st_size
check(size <= 20000, f'core SKILL.md is {size} bytes, within the 20000-byte budget')
check(size > 4000, 'control: the budget check reads a real file, not an empty one')

# every reference is named in the core, with its path
for ref in refs:
    check(f'references/{ref.name}' in core.read_text(encoding='utf-8'), f'the core names references/{ref.name}')
check(len(refs) >= 5, f'control: {len(refs)} reference files found')

# every heading of the former single file is a heading of the core, or of a reference the core names
former = ['Host and engine', 'First commands', 'Starting a stage', 'Taking over a shift', 'Terminal follow-through', 'Waiting',
          'Talking', 'Planning a stage', 'Choosing how to launch work', 'Reviews', 'Executors', 'Locks', 'Project configuration',
          'Recommended hub rules', 'Optional modules', 'Watching agents']
def heading_in(path, name):
    return any(h.lower().startswith(name.lower()) for h in re.findall(r'(?m)^#{1,6} (.+)$', path.read_text(encoding='utf-8')))
for name in former:
    in_core = heading_in(core, name)
    holder = [r for r in refs if heading_in(r, name)]
    named = all(f'references/{r.name}' in core.read_text(encoding='utf-8') for r in holder)
    check((in_core or holder) and named, f'"{name}" is reachable from the core ({"core" if in_core else ", ".join(r.name for r in holder)})')
check(not heading_in(core, 'No Such Section') and not any(heading_in(r, 'No Such Section') for r in refs), 'control: a section that never existed is not found')
check('**Autopilot**' in (skill_dir / 'references/autopilot.md').read_text(encoding='utf-8'), 'the Autopilot paragraphs live in references/autopilot.md')

# links inside the skill resolve; the checker flags a bad file and a bad anchor
for path in [core] + refs:
    check(not broken_links(path), f'links of {path.relative_to(root)} resolve' + (f' (broken: {broken_links(path)})' if broken_links(path) else ''))
probe = skill_dir / 'references/_probe.md'
probe.write_text('[a](nope.md) [b](codex-hub.md#no-such-heading) [c](codex-hub.md#terminal-follow-through)\n', encoding='utf-8')
try:
    check(broken_links(probe) == ['nope.md', 'codex-hub.md#no-such-heading'], 'control: a missing file and a missing anchor are flagged, a good anchor is not')
finally:
    probe.unlink()

# links from the rest of the repository into the skill resolve
tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '*.md'], capture_output=True, text=True).stdout.split()
inbound = []
for rel in tracked:
    path = root / rel
    if not path.is_file() or skill_dir in path.parents:
        continue
    for m in re.finditer(r'\]\(([^)\s]*skills/hub/[^)\s]*|[^)\s]*\.\./hub/[^)\s]*)\)', path.read_text(encoding='utf-8')):
        inbound.append((path, m.group(1)))
check(len(inbound) >= 3, f'control: {len(inbound)} inbound links to the skill found')
for path, target in inbound:
    name, _, frag = target.partition('#')
    dest = (path.parent / name).resolve()
    check(dest.is_file() and (not frag or frag in anchors(dest)), f'{path.relative_to(root)} -> {target} resolves')
sys.exit(1 if failed else 0)
PY
fail=$?
exit $fail
