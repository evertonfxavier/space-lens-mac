#!/usr/bin/env python3
"""Decides the next version from Conventional Commits and prepares a release. Standard library only.

  release.py plan [--bump patch|minor|major]   print key=value lines for $GITHUB_OUTPUT
  release.py apply --version X.Y.Z --notes F   write VERSION and CHANGELOG.md, write the release notes to F

Rules (commits since the latest v* tag):
  feat                     -> minor
  fix, perf, refactor      -> patch
  type! or BREAKING CHANGE -> major (minor while the major version is still 0)
  docs, chore, ci, test, style, build, anything else -> no release on their own

A VERSION that has no tag yet is released as it is: bumping the file by hand still works.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
SUBJECT = re.compile(r"^(?P<type>[a-zA-Z]+)(\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<text>.+)$")
RANK = {"patch": 1, "minor": 2, "major": 3}
TYPE_BUMP = {"feat": "minor", "fix": "patch", "perf": "patch", "refactor": "patch"}
SECTION = {"feat": "Added", "fix": "Fixed", "perf": "Changed", "refactor": "Changed"}
SECTION_ORDER = ["Added", "Changed", "Fixed"]


class Commit:
    def __init__(self, sha, subject, body):
        self.sha = sha
        # "Merge pull request #2 from x/y" carries the real title in the body.
        if subject.startswith("Merge pull request"):
            lines = [l for l in body.splitlines() if l.strip()]
            subject, body = (lines[0], "\n".join(lines[1:])) if lines else (subject, body)
        self.subject = subject.strip()
        self.body = body
        m = SUBJECT.match(self.subject)
        self.type = m.group("type").lower() if m else None
        self.text = m.group("text").strip() if m else self.subject
        self.breaking = bool(m and m.group("bang")) or bool(re.search(r"^BREAKING[ -]CHANGE", body, re.M))

    def bump(self):
        if self.type is None:
            return None
        if self.breaking:
            return "major"
        return TYPE_BUMP.get(self.type)


def parse_version(text):
    m = SEMVER.match(text.strip())
    return tuple(int(x) for x in m.groups()) if m else None


def decide_bump(commits, forced=None):
    if forced:
        return forced
    best = None
    for commit in commits:
        bump = commit.bump()
        if bump and (best is None or RANK[bump] > RANK[best]):
            best = bump
    return best


def next_version(current, bump):
    major, minor, patch = current
    if bump == "major":
        return (0, minor + 1, 0) if major == 0 else (major + 1, 0, 0)
    if bump == "minor":
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def fmt(version):
    return ".".join(str(x) for x in version)


def changelog_section(version, commits, today=None):
    today = today or datetime.date.today().isoformat()
    groups = {}
    for commit in commits:
        heading = SECTION.get(commit.type or "")
        if not heading:
            continue
        text = commit.text[:1].upper() + commit.text[1:]
        if commit.breaking:
            text = "**Breaking:** " + text
        groups.setdefault(heading, []).append(f"- {text} ({commit.sha[:7]})")
    lines = [f"## [{version}] - {today}", ""]
    for heading in SECTION_ORDER:
        if heading in groups:
            lines += [f"### {heading}", ""] + groups[heading] + [""]
    if len(lines) == 2:
        lines += ["- Maintenance release.", ""]
    return "\n".join(lines).rstrip() + "\n"


def insert_section(changelog, version, section):
    """Puts the section right after the intro; leaves the file alone if the version is already there."""
    if re.search(rf"^## \[{re.escape(version)}\]", changelog, re.M):
        return changelog
    first = re.search(r"^## \[", changelog, re.M)
    if not first:
        return changelog.rstrip() + "\n\n" + section
    return changelog[: first.start()] + section + "\n" + changelog[first.start() :]


def extract_section(changelog, version):
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog, re.M | re.S)
    return m.group(1).strip() + "\n" if m else ""


def install_notes(version):
    return f"""
## Install

1. Download `SpaceLens-{version}.dmg` (or the zip) and drag **SpaceLens** to Applications.
2. The app is not notarized. On first launch macOS may say it cannot be opened: go to
   **System Settings → Privacy & Security → Open Anyway**, or run
   `xattr -dr com.apple.quarantine /Applications/SpaceLens.app`.
3. Grant **Full Disk Access** (System Settings → Privacy & Security) to see Mail, Messages, Safari and the Trash.

Universal binary (Apple silicon + Intel), macOS 14 or later. Verify downloads with `SHA256SUMS.txt`.
"""


# --- git -------------------------------------------------------------------------------------------------------

def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def latest_tag():
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*").strip() or None
    except subprocess.CalledProcessError:
        return None


def tag_exists(tag):
    return subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], cwd=ROOT, capture_output=True
    ).returncode == 0


def commits_since(tag):
    rng = f"{tag}..HEAD" if tag else "HEAD"
    raw = git("log", rng, "--format=%H%x1f%s%x1f%b%x1e")
    out = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        sha, subject, body = (record.split("\x1f") + ["", ""])[:3]
        out.append(Commit(sha.strip(), subject, body))
    return out


def read_version():
    with open(os.path.join(ROOT, "VERSION")) as f:
        return f.read().strip()


def plan(forced):
    file_version = read_version()
    current = parse_version(file_version)
    if current is None:
        sys.exit(f"VERSION '{file_version}' is not x.y.z")
    tag = latest_tag()
    commits = commits_since(tag)
    if not tag_exists(f"v{file_version}"):
        return {"release": "true", "version": file_version, "previous": tag or "", "bump": "manual",
                "reason": f"VERSION {file_version} has no release yet"}
    last = parse_version(tag[1:]) if tag else None
    base = max(current, last) if last else current
    bump = decide_bump(commits, forced)
    if not bump:
        kinds = sorted({c.type or "other" for c in commits}) or ["none"]
        return {"release": "false", "version": fmt(base), "previous": tag or "", "bump": "none",
                "reason": f"no feat/fix/perf/refactor commit since {tag} (found: {', '.join(kinds)})"}
    version = fmt(next_version(base, bump))
    return {"release": "true", "version": version, "previous": tag or "", "bump": bump,
            "reason": f"{bump} bump from {fmt(base)}"}


def apply(version, notes_path):
    tag = latest_tag()
    changelog_path = os.path.join(ROOT, "CHANGELOG.md")
    with open(changelog_path) as f:
        changelog = f.read()
    section_present = bool(re.search(rf"^## \[{re.escape(version)}\]", changelog, re.M))
    if not section_present:
        section = changelog_section(version, commits_since(tag))
        changelog = insert_section(changelog, version, section)
        with open(changelog_path, "w") as f:
            f.write(changelog)
    with open(os.path.join(ROOT, "VERSION"), "w") as f:
        f.write(version + "\n")
    with open(notes_path, "w") as f:
        f.write(extract_section(changelog, version) + install_notes(version))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--bump", choices=["patch", "minor", "major"])
    a = sub.add_parser("apply")
    a.add_argument("--version", required=True)
    a.add_argument("--notes", required=True)
    args = parser.parse_args()
    if args.command == "plan":
        for key, value in plan(args.bump).items():
            print(f"{key}={value}")
    else:
        if parse_version(args.version) is None:
            sys.exit("--version must be x.y.z")
        apply(args.version, args.notes)


if __name__ == "__main__":
    main()
