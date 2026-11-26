"""Regenerates integration/patches/ and integration/files/ from this repository.

    python -X utf8 portal_assistant/integration/make_patches.py

For maintainers of this repository (where TownPass already carries the
assistant): every official TownPass file the assistant changes gets one patch
against the official baseline BASELINE (patches/<path>.patch), and every file
TownPass must add is copied to files/<path>. INTEGRATION.md and
docs/HOST_CHANGES.md describe each of them; apply.ps1 / apply.sh put them into
a TownPass checkout. The host App's test test/portal_assistant_integration_test.dart
checks that files/ matches the App.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

BASELINE = 'e65b586771b67334e7a21c2aa9c6e80060e4f827'
HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]

# Official TownPass files the assistant changes (one patch each).
PATCHED = [
    '.gitignore',
    'pubspec.yaml',
    'lib/main.dart',
    'lib/util/tp_route.dart',
    'lib/util/tp_web_view.dart',
    'lib/util/tp_text.dart',
    'lib/util/tp_setting_list.dart',
    'lib/util/tp_bottom_navigation_factory.dart',
    'lib/page/perk/perk_view.dart',
    'lib/page/account/account_view.dart',
    'lib/page/setting/setting_view.dart',
    'lib/page/language/language_view.dart',
    'lib/page/language/language_view_controller.dart',
    'lib/page/basic_info_edit/basic_info_edit_view.dart',
    'lib/page/feedback/feedback_view.dart',
    'lib/page/home/widget/subscription/subscription_widget.dart',
    'android/settings.gradle',
    'android/app/build.gradle',
    'android/app/src/main/AndroidManifest.xml',
    'android/app/src/debug/AndroidManifest.xml',
    'android/app/src/main/kotlin/com/example/townpass/MainActivity.kt',
    'ios/.gitignore',
    'ios/Runner.xcodeproj/project.pbxproj',
    'ios/Runner/AppDelegate.swift',
    'ios/Runner/Info.plist',
]

# Files TownPass adds (copied as they are).
ADDED = [
    'lib/util/town_pass_assistant_host.dart',
    'android/app/src/debug/res/xml/assistant_network_security.xml',
    'ios/Runner/OnDeviceAssistant.swift',
    'ios/Runner/Runner.entitlements',
]

# Only these lines of this repository's .gitignore belong to the assistant
# (the others are the team fork's own); its patch adds just them.
GITIGNORE_BLOCK = (
    '\n\n# Portal assistant: on-device native build output in the App\'s Android project\n'
    '# (portal_assistant/native/android/build_assistant_native.ps1); the rest is in\n'
    '# portal_assistant/.gitignore.\n'
    '**/android/app/assistant-native/\n'
)


GITATTRIBUTES = (
    '# The patches are applied byte for byte with `git apply` (apply.ps1 / apply.sh):\n'
    '# keep their LF line endings on every checkout, and do not flag the leading space\n'
    '# of diff context lines (blank lines, tab-indented Xcode lines) as whitespace errors.\n'
    '# Written by make_patches.py.\n'
    '* -text -whitespace\n'
)


def git(*args, cwd=REPO):
    return subprocess.run(['git', *args], cwd=cwd, capture_output=True, check=True).stdout


def no_index_patch(path, old, new):
    """A patch for [path] from text [old] to text [new]."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / 'a').mkdir()
        (tmp / 'b').mkdir()
        (tmp / 'a' / 'file').write_bytes(old)
        (tmp / 'b' / 'file').write_bytes(new)
        out = subprocess.run(['git', 'diff', '--no-index', '--no-color', 'a/file', 'b/file'],
                             cwd=tmp, capture_output=True).stdout.decode('utf-8')
    lines = out.split('\n')
    head = [f'diff --git a/{path} b/{path}']
    body = []
    for line in lines[1:]:
        if line.startswith('--- '):
            body.append(f'--- a/{path}')
        elif line.startswith('+++ '):
            body.append(f'+++ b/{path}')
        else:
            body.append(line)
    return ('\n'.join(head + body)).encode('utf-8')


def main():
    patches = HERE / 'patches'
    files = HERE / 'files'
    for folder in (patches, files):
        if folder.exists():
            shutil.rmtree(folder)
    for path in PATCHED:
        if path == '.gitignore':
            old = git('show', f'{BASELINE}:{path}')
            patch = no_index_patch(path, old, old + GITIGNORE_BLOCK.encode('utf-8'))
        else:
            patch = git('diff', '--no-color', BASELINE, '--', path)
        if not patch.strip():
            sys.exit(f'{path}: no change against the baseline')
        out = patches / f'{path}.patch'
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(patch.replace(b'\r\n', b'\n'))
    # Keep the patches byte for byte (LF) on every checkout, and do not flag the
    # leading space of diff context lines as whitespace errors (git diff --check).
    (patches / '.gitattributes').write_bytes(GITATTRIBUTES.encode('utf-8'))
    for path in ADDED:
        out = files / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes((REPO / path).read_bytes().replace(b'\r\n', b'\n'))
    print(f'{len(PATCHED)} patches, {len(ADDED)} files')


if __name__ == '__main__':
    main()
