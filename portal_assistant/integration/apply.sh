#!/usr/bin/env bash
# Puts the portal assistant into a TownPass checkout (portal_assistant/INTEGRATION.md).
#
#   portal_assistant/integration/apply.sh               # apply into the repository that holds portal_assistant/
#   portal_assistant/integration/apply.sh --check       # only report what would happen
#   portal_assistant/integration/apply.sh [--check] /path/to/TownPass
#
# The target is a git checkout of TownPass (official baseline e65b586 or a
# version whose files still match the patches) with this portal_assistant/
# folder copied to its root. Every patch in patches/ is applied with
# `git apply` (one per official file) and every file in files/ is copied to the
# same path. A patch that is already applied, or a file that is already
# identical, is reported and skipped. Exits 1 when anything failed; nothing is
# committed. Same behaviour as apply.ps1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) TARGET="$arg" ;;
  esac
done
[ -n "$TARGET" ] || TARGET="$(cd "$HERE/../.." && pwd)"
TARGET="$(cd "$TARGET" && pwd)"
[ -f "$TARGET/portal_assistant/app/pubspec.yaml" ] || {
  echo "$TARGET/portal_assistant is missing: copy the portal_assistant folder to the TownPass root first." >&2; exit 1; }
[ -f "$TARGET/pubspec.yaml" ] || { echo "$TARGET is not a Flutter App (no pubspec.yaml)." >&2; exit 1; }

failed=()
while IFS= read -r patch; do
  name="${patch#"$HERE/patches/"}"; name="${name%.patch}"
  if git -C "$TARGET" apply --check --whitespace=nowarn "$patch" 2>/dev/null; then
    if [ "$CHECK" = 1 ]; then echo "patch   $name : applies"
    elif git -C "$TARGET" apply --whitespace=nowarn "$patch"; then echo "patch   $name : applied"
    else echo "patch   $name : FAILED"; failed+=("$name"); fi
  elif git -C "$TARGET" apply --check --reverse --whitespace=nowarn "$patch" 2>/dev/null; then
    echo "patch   $name : already applied"
  else
    echo "patch   $name : DOES NOT APPLY (the file differs from the baseline; apply INTEGRATION.md by hand)"
    failed+=("$name")
  fi
done < <(find "$HERE/patches" -type f -name '*.patch' | sort)

while IFS= read -r file; do
  name="${file#"$HERE/files/"}"
  dest="$TARGET/$name"
  if [ -e "$dest" ]; then
    if cmp -s <(tr -d '\r' < "$file") <(tr -d '\r' < "$dest"); then echo "file    $name : already there"
    else echo "file    $name : EXISTS AND DIFFERS (not overwritten)"; failed+=("$name"); fi
    continue
  fi
  if [ "$CHECK" = 1 ]; then echo "file    $name : would be added"; continue; fi
  mkdir -p "$(dirname "$dest")"
  cp "$file" "$dest"
  echo "file    $name : added"
done < <(find "$HERE/files" -type f | sort)

if [ "${#failed[@]}" -gt 0 ]; then
  echo
  echo "${#failed[@]} problem(s): ${failed[*]}"
  exit 1
fi
echo
if [ "$CHECK" = 1 ]; then
  echo "All patches apply and all files can be added."
else
  echo "Done. Next (portal_assistant/INTEGRATION.md, steps 3 and 4):"
  echo "  fvm flutter pub get"
  echo "  fvm dart run build_runner build --delete-conflicting-outputs"
  echo "  then build and run the on-device assistant (INTEGRATION.md step 4)"
fi
