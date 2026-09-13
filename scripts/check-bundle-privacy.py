#!/usr/bin/env python3
"""Check the public app payload without printing potentially private bytes."""

import re
import sys
from pathlib import Path


EXPECTED_FILES = {
    "Contents/Info.plist",
    "Contents/MacOS/Broschy",
    "Contents/MacOS/broschy-cli",
    "Contents/Resources/Broschy.icns",
    "Contents/Resources/AppIcon.png",
    "Contents/Resources/Integrations/agent-integrations.py",
    "Contents/Resources/Integrations/opencode/broschy.js",
    "Contents/Resources/Integrations/Guide.md",
    "Contents/_CodeSignature/CodeResources",
}

# Scan raw bytes: Mach-O string tables can contain source paths that the macOS
# strings utility omits. Match path roots, not the developer's own account name.
PRIVATE_PATH = re.compile(rb"/(?:Users|home|private/var/folders|var/folders|private/tmp|tmp)/[^\x00\s]+")
SECRET_PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})"),
    "provider credential": re.compile(rb"(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{20,})"),
}


def check_bundle(bundle):
    errors = []
    if not bundle.is_dir() or bundle.is_symlink():
        return ["Expected a regular app bundle directory."]
    expected_directories = set()
    for name in EXPECTED_FILES:
        expected_directories.update(str(parent) for parent in Path(name).parents if str(parent) != ".")
    files = set()
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            errors.append("The bundle contains a symbolic link.")
            continue
        if path.is_dir():
            if relative not in expected_directories:
                errors.append("The bundle contains an undeclared directory.")
            continue
        if not path.is_file():
            errors.append("The bundle contains an unsupported file type.")
            continue
        files.add(relative)
        if relative not in EXPECTED_FILES:
            # Unknown names can themselves contain private information.
            errors.append("The bundle contains an undeclared file.")
            continue
        content = path.read_bytes()
        if PRIVATE_PATH.search(content):
            errors.append(f"{relative}: local source, home, or temporary path detected.")
        for category, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                errors.append(f"{relative}: possible {category} detected.")
    if EXPECTED_FILES - files:
        errors.append("The bundle is missing declared files.")
    return errors


def main():
    if len(sys.argv) != 2:
        print("Usage: check-bundle-privacy.py <Broschy.app>", file=sys.stderr)
        return 2
    try:
        errors = check_bundle(Path(sys.argv[1]))
    except OSError:
        print("Bundle privacy check could not read the complete payload.", file=sys.stderr)
        return 1
    if errors:
        for error in sorted(set(errors)):
            print(error, file=sys.stderr)
        return 1
    print("Bundle privacy check passed: declared payload only; no detected local paths or credential patterns.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
