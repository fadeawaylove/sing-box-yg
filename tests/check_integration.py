"""Read-only checks for the single-repository integration; never execute installers."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://raw.githubusercontent.com/fadeawaylove/sing-box-yg/main/'
tracked = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
paths = [ROOT / p for p in tracked if Path(p).suffix in {'.sh', '.md', '.yml', '.html', '.js'} and not p.startswith('tests/')]
paths.append(ROOT / 'scripts/acme.sh')
checked = set()
for path in paths:
    text = path.read_text(encoding='utf-8')
    # Attribution links are allowed; executable download links must use this fork.
    assert 'raw.githubusercontent.com/yonggekkk/sing-box-yg/' not in text, path
    assert 'raw.githubusercontent.com/yonggekkk/acme-yg/' not in text, path
    for resource in re.findall(re.escape(BASE) + r'([A-Za-z0-9_./$-]+)', text):
        for expanded in ([resource.replace('$cpu', cpu) for cpu in ('amd64', 'arm64')] if '$cpu' in resource else [resource]):
            assert '$' not in expanded, f'Unresolved resource: {expanded}'
            assert (ROOT / expanded).is_file(), f'Missing fork resource: {expanded}'
            checked.add(expanded)

sb = (ROOT / 'sb.sh').read_text(encoding='utf-8')
for function, following in [('inscertificate', 'insport'), ('acme', 'cfwarp')]:
    section = sb.split(function + '(){', 1)[1].split(following + '(){', 1)[0]
    assert BASE + 'scripts/acme.sh' in section, f'{function} does not use bundled certificate manager'
assert BASE + 'sb.sh' in sb.split('lnsb(){', 1)[1].split('\n}', 1)[0]
assert 'https://github.com/SagerNet/sing-box/releases' in sb
acme = ROOT / 'scripts/acme.sh'
assert 'https://get.acme.sh' in acme.read_text(encoding='utf-8')
provenance = json.loads((ROOT / 'UPSTREAM.json').read_text(encoding='utf-8'))
assert hashlib.sha256(acme.read_bytes()).hexdigest() == provenance['acme_yg']['sha256']
assert 'GNU GENERAL PUBLIC LICENSE' in (ROOT / 'LICENSE').read_text(encoding='utf-8')
print(f'PASS: installation, certificate menu, self-update, {len(checked)} fork resources, upstream clients and imported source integrity')
