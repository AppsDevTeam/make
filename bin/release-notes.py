#!/usr/bin/env python3
"""Dopíše záznam nové verze do release notes (docs/release-notes.md) přes Claude API.

    release-notes.py <verze> <soubor release notes> [<model>]

Totéž, co lokálně dělá skill /release-notes přes claude CLI (`make release`), jen bez CLI
a bez přihlášení - pro CI (adt/ci: publish stage vydá tag a GitLab Release). Potřebuje
ANTHROPIC_API_KEY v prostředí.

Zadání bere ze skillu projektu `.claude/commands/release-notes.md` (bez YAML hlavičky, `$1`
= verze, `$2` = soubor release notes), když ho projekt nemá, z vestavěného zadání níže (stejný formát jako sandbox).
Model dostane commity od posledního tagu (zprávy, těla, změněné soubory) a začátek
dosavadních release notes kvůli stylu; vrátí jen nový záznam, skript ho vloží za oddělovač
`---` pod blok „Schéma verzování" (nad nejnovější záznam). Soubor bez oddělovače dostane
záznam na konec, chybějící soubor se založí s hlavičkou.
"""

import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_MODEL = 'claude-opus-5-5'
API_URL = 'https://api.anthropic.com/v1/messages'

DEFAULT_PROMPT = """Připrav release notes pro verzi **$1** do `$2`.

## Formát záznamu

```
## $1 (D.M.RRRR)

**Oblast:**
- popis změny…
```

- Datum = dnešní den ve formátu `D.M.RRRR` (bez úvodních nul)
- Změny seskupuj podle funkčních oblastí, které už soubor používá — novou oblast zaveď,
  jen když žádná existující nesedí

## Pravidla

- Piš česky, věcně a konkrétně — uživatelsky viditelné změny popiš tak, aby jim rozuměl
  i ne-programátor; u technických změn uveď dotčené třídy/komponenty v backtickách
- Interní drobnosti (CI, refactoring, úpravy testů) shrň do jedné–dvou odrážek
  v sekci **Infrastruktura**
- Vynech commity typu „fix", „wip" bez obsahu — informaci dohledej z diffu,
  nebo je sluč do souhrnné odrážky
- Drž se přesně stylu dosavadních záznamů
"""

FILE_HEADER = """# Release Notes

Historie releasů projektu. Nový záznam dopisuje `make release`.

## Schéma verzování

Projekt používá kalendářní verzování (CalVer) **vRRRR.M.N** — nejde o sémantické verzování,
číslo verze nevypovídá o povaze změny:

- **RRRR** je rok
- **M** je měsíc (1 = leden … 12 = prosinec, bez úvodní nuly)
- **N** je pořadí releasu v rámci měsíce (od 1)

Příklad: `v2026.10.2` = druhý release v říjnu 2026.

---
"""

SYSTEM = (
    'Jsi technický redaktor projektu. Dostaneš zadání (skill release-notes), commity od '
    'posledního releasu a začátek dosavadního souboru release notes. Odpověz POUZE textem '
    'nového záznamu v Markdownu přesně ve formátu ze zadání (začíná řádkem `## <verze> (<datum>)`), '
    'bez úvodu, komentářů, ohraničení kódem ani čehokoli dalšího. Do záznamu nepiš commit, '
    'který jen přidává release notes.'
)


def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout


def die(message):
    print(f'release-notes: {message}', file=sys.stderr)
    sys.exit(1)


def load_prompt(version, path_notes):
    path = '.claude/commands/release-notes.md'
    text = DEFAULT_PROMPT
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        text = re.sub(r'\A---\n.*?\n---\n', '', text, count=1, flags=re.S)
    return text.replace('$1', version).replace('$2', path_notes)


def git_context():
    last = sh('git', 'describe', '--tags', '--abbrev=0', '--match', 'v*', check=False).strip()
    # první release bez tagu: celá historie by byla na stovky commitů, bere se posledních 50
    rng = [f'{last}..HEAD'] if last else ['HEAD', '-n', '50']
    log = sh('git', 'log', *rng, '--no-merges', '--date=short',
             '--pretty=format:commit %h (%ad, %an)%n%s%n%n%b%n--')
    stat = sh('git', 'log', *rng, '--no-merges', '--stat=120', '--pretty=format:commit %h')
    if not log.strip():
        die(f'žádné commity od {last or "začátku"} - není co zapsat')
    return last, log[:80000], stat[:40000]


def call_api(model, system, user):
    key = os.environ.get('ANTHROPIC_API_KEY')
    if not key:
        die('ANTHROPIC_API_KEY chybí v prostředí')
    body = {
        'model': model,
        'max_tokens': 8000,
        'system': system,
        'messages': [{'role': 'user', 'content': user}],
        # při odmítnutí bezpečnostním klasifikátorem zkusí API jiný model samo
        'fallbacks': 'default',
    }
    req = urllib.request.Request(API_URL, data=json.dumps(body).encode(), headers={
        'content-type': 'application/json',
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'server-side-fallback-2026-07-01',
    })
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        die(f'Claude API {e.code}: {e.read().decode(errors="replace")[:2000]}')
    except urllib.error.URLError as e:
        die(f'Claude API nedostupné: {e.reason}')
    if data.get('stop_reason') == 'refusal':
        die(f'Claude API odmítlo požadavek: {data.get("stop_details")}')
    if data.get('stop_reason') == 'max_tokens':
        die('odpověď Claude API je useknutá (max_tokens)')
    text = ''.join(b.get('text', '') for b in data.get('content', []) if b.get('type') == 'text')
    text = text.strip()
    text = re.sub(r'\A```(?:markdown|md)?\n(.*)\n```\Z', r'\1', text, flags=re.S).strip()
    if not text.startswith('## '):
        die(f'odpověď nezačíná záznamem `## <verze>`:\n{text[:500]}')
    usage = data.get('usage', {})
    print(f'release-notes: {model}, tokeny in {usage.get("input_tokens")} / out {usage.get("output_tokens")}',
          file=sys.stderr)
    return text


def insert_entry(path, entry):
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            content = f.read()
    else:
        os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
        content = FILE_HEADER
    m = re.search(r'^---\n', content, flags=re.M)
    if m:
        content = content[:m.end()] + '\n' + entry + '\n\n' + content[m.end():].lstrip('\n')
    else:
        content = content.rstrip('\n') + '\n\n' + entry + '\n'
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)


def main():
    if len(sys.argv) < 3:
        die('použití: release-notes.py <verze> <soubor> [<model>]')
    version, path = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else DEFAULT_MODEL
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            existing = f.read()
        if re.search(rf'^## {re.escape(version)}\b', existing, flags=re.M):
            die(f'{path} už záznam {version} má')
        head = '\n'.join(existing.splitlines()[:160])
    else:
        head = '(soubor zatím neexistuje, založí se s hlavičkou)'
    last, log, stat = git_context()
    today = datetime.date.today()
    user = (
        f'{load_prompt(version, path)}\n\n'
        f'Dnešní datum: {today.day}.{today.month}.{today.year}\n'
        f'Poslední tag: {last or "žádný (první release - níže je jen posledních 50 commitů, popiš je jako první verzi)"}\n\n'
        f'## Commity od posledního tagu\n\n{log}\n\n'
        f'## Změněné soubory po commitech\n\n{stat}\n\n'
        f'## Začátek dosavadního souboru {path} (drž se stylu záznamů)\n\n{head}\n'
    )
    entry = call_api(model, SYSTEM, user)
    insert_entry(path, entry)
    print(entry)


if __name__ == '__main__':
    main()
