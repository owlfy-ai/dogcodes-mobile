"""Build lib/l10n/<language>.json from translator TSV files.

Usage: merge_tsv.py <language> <file.tsv> [more.tsv ...]

Each line is `<index>\t<text>` (or `one:<index>\t<text>` for the singular of a
counted label), where <index> is the key's position in lib/l10n/en.json and
<text> is JSON-string-escaped (\\n, \\", \\u001b ...).
"""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
language, files = sys.argv[1], sys.argv[2:]
english = json.loads((root / 'lib/l10n/en.json').read_text())
keys = [k for k in english if not k.startswith('@one:')]
out = {}
for file in files:
    for n, line in enumerate(Path(file).read_text().splitlines(), 1):
        if not line.strip():
            continue
        index, _, text = line.partition('\t')
        one = index.startswith('one:')
        i = int(index[4:] if one else index)
        value = json.loads('"' + text + '"')
        key = ('@one:' if one else '') + keys[i]
        if key in out:
            raise SystemExit(f'{file}:{n}: duplicate index {index}')
        out[key] = value
ordered = {k: out[k] for k in keys if k in out}
ordered.update({k: v for k, v in out.items() if k.startswith('@one:')})
missing = [i for i, k in enumerate(keys) if k not in out]
(root / f'lib/l10n/{language}.json').write_text(
    json.dumps(ordered, ensure_ascii=False, indent=2) + '\n'
)
print(f'{language}: {len(ordered)} entries, missing indices: {missing[:20]}')
