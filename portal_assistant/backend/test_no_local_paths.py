"""No machine-specific paths or device serials anywhere in the repository (portal_assistant/docs/TEAM_LOCAL_SETUP.md
section 3.1, 2026-11-25): the whole app tree is handed over (portal_assistant/ and the TownPass app around
it, owner 2026-11-25), so other people must be able to use its scripts and docs.

Instead of one computer's folders: TOWNPASS_PORTAL_ASSISTANT_WORK (code) or <工作資料夾> (docs) for the work
folder, TOWNPASS_PORTAL_ASSISTANT_MSYS_BIN for MSYS2, ANDROID_HOME / ANDROID_SDK_ROOT for the Android SDK,
ANDROID_SERIAL (scripts) or <裝置序號> (docs) for a phone. Every git-tracked text file of the repository is
scanned except portal_assistant/integration/patches/ (generated from the official files by make_patches.py).
The patterns are joined from pieces so this file does not match itself.
"""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]  # the repository root (this file is in portal_assistant/backend/)
SKIP = ("portal_assistant/integration/patches/",)
SEP = r"[\\/]+"  # D:\x, D:/x and D:\\x (inside a non-raw Python string)
FORBIDDEN = {
    "work folder (use TOWNPASS_PORTAL_ASSISTANT_WORK or <工作資料夾>)": "D:" + SEP + "Town" + "Pass" + "Assistant",
    "user folder": "C:" + SEP + "Us" + "ers",
    "MSYS2 folder (use TOWNPASS_PORTAL_ASSISTANT_MSYS_BIN)": "C:" + SEP + "msys" + "64",
    "Android SDK folder (use ANDROID_HOME)": "D:" + SEP + "And" + "roid",
    "repository folder": "D:" + SEP + "git" + "hub",
    "Android phone serial (use ANDROID_SERIAL or <裝置序號>)": "10AF" + "8403" + "R5001SP",
    "iPhone id (use <裝置序號>)": "00008150" + "-001C" + "54582621401C",
}
PATTERNS = [(label, re.compile(pattern, re.IGNORECASE)) for label, pattern in FORBIDDEN.items()]


def tracked_files():
    result = subprocess.run(["git", "ls-files", "-z", "--", "."], cwd=ROOT, capture_output=True)
    if result.returncode:
        return None
    return [name for name in result.stdout.decode("utf-8").split("\0") if name and not name.startswith(SKIP)]


def text_of(path):
    """The file's text, or None for a binary file (a NUL byte or not UTF-8)."""
    data = path.read_bytes()
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def findings(name, text):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for label, pattern in PATTERNS:
            if pattern.search(line):
                found.append(f"{name}:{number}: {label}: {line.strip()[:160]}")
    return found


class NoLocalPathsTest(unittest.TestCase):
    def test_tracked_text_files_name_no_local_path(self):
        names = tracked_files()
        if names is None:
            self.skipTest("not a git checkout: git ls-files failed")
        problems, scanned = [], 0
        for name in names:
            path = ROOT / name
            if not path.is_file():  # deleted in the working tree
                continue
            text = text_of(path)
            if text is None:
                continue
            scanned += 1
            problems += findings(name, text)
        self.assertGreater(scanned, 100, "too few files scanned: is ROOT the repository root?")
        self.assertEqual(problems, [], "machine-specific paths (portal_assistant/docs/TEAM_LOCAL_SETUP.md "
                                       "section 3.1):\n  " + "\n  ".join(problems))

    def test_patterns_catch_local_paths_and_allow_the_replacements(self):
        bs = "\\"
        caught = ["D:" + bs + "TownPass" + "Assistant" + bs + "models", "d:/TownPass" + "Assistant/convert-venv",
                  "D:" + bs + bs + "TownPass" + "Assistant" + bs + bs + "need-impl", "C:" + bs + "Users" + bs + "someone",
                  "C:" + bs + "msys64" + bs + "ucrt64" + bs + "bin", "D:" + bs + "Android" + bs + "Sdk",
                  "D:" + bs + "github" + bs + "TownPass-x", "adb -s 10AF8403" + "R5001SP install",
                  "00008150-001C5458" + "2621401C"]
        for sample in caught:
            self.assertTrue(findings("x", sample), sample)
        allowed = ["%TOWNPASS_PORTAL_ASSISTANT_WORK%" + bs + "models", "<工作資料夾>" + bs + "models" + bs + "device",
                   "$env:TOWNPASS_PORTAL_ASSISTANT_WORK" + bs + "native-src", "%LOCALAPPDATA%" + bs + "TownPassAssistant",
                   "~/Library/Application Support/TownPassAssistant/models", "adb -s <裝置序號> install",
                   '"superseded": ["C:' + bs + bs + 'x.bin"]']
        for sample in allowed:
            self.assertEqual(findings("x", sample), [], sample)


if __name__ == "__main__":
    unittest.main()
