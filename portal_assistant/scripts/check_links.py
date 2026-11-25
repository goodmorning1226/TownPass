"""Checks the relative links of every Markdown file in the repository.

    python -X utf8 portal_assistant/scripts/check_links.py

Markdown links `[text](path)` and HTML `src="..."`/`href="..."` that point
inside the repository must name an existing file or folder (the part after
`#` is not checked). Web links, mail links and pure anchors are skipped, and
so is anything inside fenced code blocks. Exits 1 and lists the broken links
when there are any.
"""
import pathlib
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = pathlib.Path(__file__).resolve().parents[2]
LINK = re.compile(r'\]\(([^)\s]+)(?:\s+"[^"]*")?\)|(?:src|href)="([^"]+)"')
FENCE = re.compile(r'^\s*(```|~~~)')


def markdown_files():
    out = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard', '*.md'],
                         cwd=ROOT, capture_output=True, check=True).stdout.decode('utf-8')
    return [ROOT / line for line in out.splitlines() if line]


def broken_links(path):
    problems = []
    fenced = False
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        for match in LINK.finditer(line):
            target = match.group(1) or match.group(2)
            if re.match(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|//)', target):
                continue
            file_part = unquote(target.split('#', 1)[0])
            if not file_part:
                continue
            resolved = (ROOT / file_part.lstrip('/')) if file_part.startswith('/') else (path.parent / file_part)
            if not resolved.exists():
                problems.append((number, target))
    return problems


def main():
    total = 0
    for path in markdown_files():
        if not path.exists():
            continue
        for number, target in broken_links(path):
            total += 1
            print(f'{path.relative_to(ROOT).as_posix()}:{number}: {target}')
    print(f'{total} broken link(s)')
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
