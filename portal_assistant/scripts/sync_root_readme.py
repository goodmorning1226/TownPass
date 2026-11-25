"""Writes the repository's README.md from portal_assistant/README.md.

    python -X utf8 portal_assistant/scripts/sync_root_readme.py           # write
    python -X utf8 portal_assistant/scripts/sync_root_readme.py --check   # exit 1 if out of date

portal_assistant/README.md is the one README to edit (the hackathon template:
overview, architecture, install, features, AI usage declaration). The
repository's front page shows the root README.md, so it is the same text with
every relative link rewritten to start from the repository root:
`docs/x.md` -> `portal_assistant/docs/x.md`, `../AGENTS.md` -> `AGENTS.md`.
Links inside fenced code blocks, web links and anchors are left alone.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'portal_assistant' / 'README.md'
TARGET = ROOT / 'README.md'
LINK = re.compile(r'(\]\()([^)\s]+)((?:\s+"[^"]*")?\))|((?:src|href)=")([^"]+)(")')
FENCE = re.compile(r'^\s*(```|~~~)')
HEADER = ('<!-- Generated from portal_assistant/README.md by portal_assistant/scripts/sync_root_readme.py.\n'
          '     Edit that file, then run the script. -->\n')


def rebase(target):
    if re.match(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|//)', target):
        return target
    if target.startswith('../'):
        return target[3:]
    return 'portal_assistant/' + target


def render():
    out = []
    fenced = False
    for line in SOURCE.read_text(encoding='utf-8').splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced:
            line = LINK.sub(lambda m: (m.group(1) + rebase(m.group(2)) + m.group(3)) if m.group(1)
                            else (m.group(4) + rebase(m.group(5)) + m.group(6)), line)
        out.append(line)
    return HEADER + '\n'.join(out) + '\n'


def main():
    text = render()
    if '--check' in sys.argv[1:]:
        current = TARGET.read_text(encoding='utf-8') if TARGET.exists() else ''
        if current.replace('\r\n', '\n') != text:
            print('README.md is out of date: run portal_assistant/scripts/sync_root_readme.py')
            sys.exit(1)
        print('README.md is up to date')
        return
    TARGET.write_bytes(text.encode('utf-8'))
    print(f'wrote {TARGET.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
