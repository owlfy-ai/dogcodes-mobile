"""Validate and compile the app-owned message catalogs.

Source strings are Simplified Chinese (the keys). Each `lib/l10n/<id>.json`
maps every key to that language; `@one:<key>` entries hold the singular form
of a counted label. English is the fallback for anything missing at runtime,
but every catalog is expected to be complete (checked here and in tests).
"""
import json
import subprocess
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
LANGUAGES = ['en', 'zh-Hant', 'ja', 'ko', 'fr', 'de', 'es', 'pt-BR', 'ru', 'it']
placeholder = re.compile(r'\{\d+\}')
han = re.compile(r'[㐀-鿿]')

english = json.loads((root / 'lib/l10n/en.json').read_text())
keys = [k for k in english if not k.startswith('@one:')]
catalogs = {}
problems = []
for language in LANGUAGES:
    path = root / f'lib/l10n/{language}.json'
    if not path.exists():
        problems.append(f'{language}: missing {path.name}')
        continue
    catalog = json.loads(path.read_text())
    for source, target in catalog.items():
        base = source[len('@one:'):] if source.startswith('@one:') else source
        if base not in english:
            problems.append(f'{language}: unknown key {source!r}')
        if set(placeholder.findall(base)) != set(placeholder.findall(target)):
            problems.append(f'{language}: placeholders differ in {source!r}')
        # Traditional Chinese and Japanese legitimately use Han characters.
        if language not in ('zh-Hant', 'ja') and han.search(target):
            problems.append(f'{language}: Chinese left in {source!r}')
    missing = [k for k in keys if k not in catalog]
    if missing:
        problems.append(f'{language}: {len(missing)} untranslated, e.g. {missing[0]!r}')
    catalogs[language] = catalog

if problems:
    raise SystemExit('\n'.join(problems))


def quote(value):
    return json.dumps(value, ensure_ascii=False).replace('$', r'\$')


lines = ['// Generated from lib/l10n/*.json by tool/l10n/generate.py.\n',
         'const messageCatalogs = <String, Map<String, String>>{\n']
for language, catalog in catalogs.items():
    lines.append(f'  {quote(language)}: {{\n')
    lines.extend(f'    {quote(s)}: {quote(t)},\n' for s, t in catalog.items())
    lines.append('  },\n')
lines.append('};\n\n')
lines.append("final Map<String, String> englishMessages = messageCatalogs['en']!;\n")
catalog_path = root / 'lib/l10n/catalog.dart'
catalog_path.write_text(''.join(lines))
# CI checks formatting, and long messages would otherwise break it on every regeneration.
subprocess.run(['dart', 'format', str(catalog_path)], check=True, capture_output=True)
print(f'Validated {len(keys)} messages in {len(catalogs)} languages.')
