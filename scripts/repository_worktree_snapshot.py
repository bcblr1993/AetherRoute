#!/usr/bin/env python3
"""Fingerprint tracked, staged, untracked and initialized submodule state.

Only digests are retained. Generated Xcode project changes are expected during
bootstrap, and ignored build caches or private signing inputs are excluded.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(root, seen):
    root = root.resolve()
    if root in seen:
        raise ValueError("recursive submodule path")
    seen.add(root)
    paths = ["--", ".", ":!AetherRoute.xcodeproj"]
    result = {
        "head": git(root, "rev-parse", "HEAD").decode().strip(),
        "worktree": digest(git(root, "diff", "--binary", *paths)),
        "index": digest(git(root, "diff", "--cached", "--binary", *paths)),
        "status": digest(git(root, "status", "--porcelain=v1", "-z",
                             "--untracked-files=all", *paths)),
        "untracked": {},
        "submodules": {},
    }
    for raw in git(root, "ls-files", "--others", "--exclude-standard", "-z",
                   *paths).split(b"\0"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = root / name
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            content = os.fsencode(os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            content = path.read_bytes()
        else:
            raise ValueError("non-file untracked entry in repository")
        result["untracked"][name] = [info.st_mode, digest(content)]
    for row in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not row.startswith(b"160000 "):
            continue
        name = os.fsdecode(row.split(b"\t", 1)[1])
        child = root / name
        if (child / ".git").exists():
            result["submodules"][name] = snapshot(child, seen)
    seen.remove(root)
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: repository_worktree_snapshot.py /repository")
    print(json.dumps(snapshot(Path(sys.argv[1]), set()), sort_keys=True))
