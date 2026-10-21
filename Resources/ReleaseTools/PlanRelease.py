#!/usr/bin/env python3
"""Plan a stable release from committed product changes; never tag or modify files."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


PRODUCT_FILES = {
    "Package.swift", "Package.resolved", "Makefile",
    "scripts/swiftw", "scripts/bundle-app.sh", "scripts/make-dmg.sh",
    "scripts/make-appcast.sh", "scripts/release.sh", "scripts/sparkle-release-signing.sh",
}
VERSION = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


def version(tag):
    match = VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"Expected a stable vMAJOR.MINOR.PATCH tag, got {tag!r}")
    return tuple(int(component) for component in match.groups())


def is_product(path):
    if path in PRODUCT_FILES or path.startswith("Sources/"):
        return True
    if path.startswith("Resources/"):
        return not path.startswith("Resources/ReleaseTools/") or Path(path).name in {
            "Icon.swift", "appcast.py", "bundle.py", "validate-key.py", "VerifySignature.swift",
        }
    return (path.startswith("engine/") and
            not path.startswith(("engine/tests/", "engine/fixtures/", "engine/smoke/", "engine/.cache/", "engine/cef/")) and
            path != "engine/smoke.py" and not path.endswith(".md"))


def next_version(previous, messages):
    major, minor, patch = version(previous)
    messages = [message.strip() for message in messages]
    if any(re.search(r"(?m)^BREAKING[ -]CHANGE:\s|^[a-z]+(?:\([^)]+\))?!:", text) for text in messages):
        return f"v{major + 1}.0.0"
    if any(re.match(r"feat(?:\([^)]+\))?:", text) for text in messages):
        return f"v{major}.{minor + 1}.0"
    return f"v{major}.{minor}.{patch + 1}"


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def plan(repo, previous, explicit_tag=None):
    version(previous)
    head = git(repo, "rev-parse", "HEAD")
    subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor",
                    f"refs/tags/{previous}", head], check=True)
    changed = git(repo, "diff", "--name-only", "--no-renames", "-z", f"refs/tags/{previous}", head)
    paths = sorted(path for path in changed.split("\0") if is_product(path))
    if explicit_tag:
        if version(explicit_tag) <= version(previous):
            raise ValueError("An explicit release must be newer than the latest published release")
        if git(repo, "rev-parse", f"refs/tags/{explicit_tag}^{{commit}}") != head:
            raise ValueError("The explicit tag does not identify the checked-out commit")
        tag, reason = explicit_tag, "explicit stable tag"
    elif paths:
        messages = git(repo, "log", "--format=%B%x00", f"refs/tags/{previous}..{head}", "--", *paths).split("\0")
        tag, reason = next_version(previous, messages), "product changes since latest published release"
    else:
        tag, reason = "", "no product changes since latest published release"
    if tag and not explicit_tag:
        existing = subprocess.run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"])
        if existing.returncode == 0:
            raise ValueError(f"Planned tag {tag} already exists; investigate the unpublished release")
        if existing.returncode != 1:
            raise RuntimeError(f"Could not check planned tag {tag}")
    return {"release": bool(tag), "tag": tag, "previous": previous, "head": head,
            "reason": reason, "product_paths": paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", required=True, help="Latest published stable release tag")
    parser.add_argument("--tag", help="Explicit pushed tag; otherwise derive the version")
    args = parser.parse_args()
    result = plan(Path.cwd(), args.previous, args.tag)
    print(json.dumps(result, indent=2))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key in ("release", "tag", "previous", "head"):
                value = str(result[key]).lower() if isinstance(result[key], bool) else result[key]
                stream.write(f"{key}={value}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(f"## Release plan\n\n{result['reason']}.\n\n")
            stream.write(f"Baseline: `{result['previous']}`. Target: `{result['tag'] or 'none'}`.\n")


if __name__ == "__main__":
    main()
