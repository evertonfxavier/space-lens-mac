#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release as r


def read(path):
    with open(path) as f:
        return f.read()


def c(subject, body=""):
    return r.Commit("a" * 40, subject, body)


class Bump(unittest.TestCase):
    def test_types(self):
        self.assertEqual(c("feat: x").bump(), "minor")
        self.assertEqual(c("feat(ui): x").bump(), "minor")
        self.assertEqual(c("fix: x").bump(), "patch")
        self.assertEqual(c("perf: x").bump(), "patch")
        self.assertEqual(c("refactor: x").bump(), "patch")
        for quiet in ["docs: x", "chore: x", "ci: x", "test: x", "style: x", "build(deps): Bump y", "random words", "Merge branch main"]:
            self.assertIsNone(c(quiet).bump(), quiet)

    def test_breaking(self):
        self.assertEqual(c("feat!: x").bump(), "major")
        self.assertEqual(c("fix(core)!: x").bump(), "major")
        self.assertEqual(c("fix: x", "details\n\nBREAKING CHANGE: gone").bump(), "major")
        self.assertEqual(c("docs!: x").bump(), "major")

    def test_highest_wins(self):
        self.assertEqual(r.decide_bump([c("fix: a"), c("feat: b"), c("docs: c")]), "minor")
        self.assertEqual(r.decide_bump([c("fix: a"), c("feat!: b")]), "major")
        self.assertIsNone(r.decide_bump([c("docs: a"), c("chore: b")]))
        self.assertEqual(r.decide_bump([c("docs: a")], forced="patch"), "patch")

    def test_merge_commit_uses_the_pull_request_title(self):
        merged = c("Merge pull request #2 from me/branch", "\nfeat: add thing\n\nmore")
        self.assertEqual(merged.type, "feat")
        self.assertEqual(merged.text, "add thing")

    def test_next_version(self):
        self.assertEqual(r.next_version((0, 2, 1), "patch"), (0, 2, 2))
        self.assertEqual(r.next_version((0, 2, 1), "minor"), (0, 3, 0))
        self.assertEqual(r.next_version((0, 2, 1), "major"), (0, 3, 0), "0.x: breaking bumps the minor")
        self.assertEqual(r.next_version((1, 4, 2), "major"), (2, 0, 0))
        self.assertEqual(r.next_version((1, 4, 2), "minor"), (1, 5, 0))

    def test_version_parsing(self):
        self.assertEqual(r.parse_version("1.2.3"), (1, 2, 3))
        for bad in ["", "1.2", "v1.2.3", "1.2.3-beta", "a.b.c"]:
            self.assertIsNone(r.parse_version(bad), bad)


class Changelog(unittest.TestCase):
    def test_section_groups_and_skips_quiet_commits(self):
        section = r.changelog_section(
            "0.3.0", [c("feat: add a"), c("fix: repair b"), c("docs: ignore"), c("perf: faster"), c("feat!: drop")], today="2026-01-01")
        self.assertIn("## [0.3.0] - 2026-01-01", section)
        self.assertIn("### Added", section)
        self.assertIn("- Add a (aaaaaaa)", section)
        self.assertIn("- **Breaking:** Drop (aaaaaaa)", section)
        self.assertIn("### Fixed", section)
        self.assertIn("### Changed", section)
        self.assertNotIn("ignore", section)
        self.assertLess(section.index("### Added"), section.index("### Changed") )
        self.assertLess(section.index("### Changed"), section.index("### Fixed"))

    def test_empty_release_still_says_something(self):
        self.assertIn("Maintenance release", r.changelog_section("1.0.1", [c("docs: x")], today="2026-01-01"))

    def test_insert_and_extract(self):
        base = "# Changelog\n\nIntro.\n\n## [0.1.0] - 2026-01-01\n\n- old\n"
        section = "## [0.2.0] - 2026-02-02\n\n### Added\n\n- new\n"
        merged = r.insert_section(base, "0.2.0", section)
        self.assertLess(merged.index("## [0.2.0]"), merged.index("## [0.1.0]"))
        self.assertTrue(merged.startswith("# Changelog\n\nIntro.\n\n## [0.2.0]"))
        self.assertEqual(r.insert_section(merged, "0.2.0", section), merged, "never inserts twice")
        self.assertEqual(r.extract_section(merged, "0.2.0").strip(), "### Added\n\n- new")
        self.assertEqual(r.extract_section(merged, "0.1.0").strip(), "- old")
        self.assertEqual(r.extract_section(merged, "9.9.9"), "")


class GitFlow(unittest.TestCase):
    """The whole plan against a real throw-away repository."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        r.ROOT = self.dir.name
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")

    def tearDown(self):
        self.dir.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.dir.name, check=True, capture_output=True, text=True).stdout

    def commit(self, message, version=None):
        if version:
            with open(os.path.join(self.dir.name, "VERSION"), "w") as f:
                f.write(version + "\n")
        with open(os.path.join(self.dir.name, "file.txt"), "a") as f:
            f.write(message + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def test_unreleased_version_is_released_as_is(self):
        self.commit("feat: first", version="0.1.0")
        p = r.plan(None)
        self.assertEqual((p["release"], p["version"], p["bump"]), ("true", "0.1.0", "manual"))

    def test_bumps_from_the_last_tag(self):
        self.commit("feat: first", version="0.1.0")
        self.git("tag", "v0.1.0")
        self.commit("docs: readme")
        self.assertEqual(r.plan(None)["release"], "false")
        self.commit("fix: crash")
        p = r.plan(None)
        self.assertEqual((p["release"], p["version"], p["bump"]), ("true", "0.1.1", "patch"))
        self.commit("feat: shiny")
        p = r.plan(None)
        self.assertEqual((p["version"], p["bump"]), ("0.2.0", "minor"))

    def test_forced_bump_releases_even_docs_only(self):
        self.commit("feat: first", version="1.2.3")
        self.git("tag", "v1.2.3")
        self.commit("docs: only")
        p = r.plan("minor")
        self.assertEqual((p["release"], p["version"]), ("true", "1.3.0"))

    def test_hand_bumped_version_wins_over_commits(self):
        self.commit("feat: first", version="0.2.0")
        self.git("tag", "v0.2.0")
        self.commit("feat: more", version="0.2.1")
        p = r.plan(None)
        self.assertEqual((p["version"], p["bump"]), ("0.2.1", "manual"))

    def test_apply_writes_files_and_notes(self):
        self.commit("feat: first", version="0.1.0")
        self.git("tag", "v0.1.0")
        self.commit("feat: shiny thing")
        self.commit("fix: broken thing")
        with open(os.path.join(self.dir.name, "CHANGELOG.md"), "w") as f:
            f.write("# Changelog\n\nIntro.\n\n## [0.1.0] - 2026-01-01\n\n- old\n")
        notes = os.path.join(self.dir.name, "notes.md")
        r.apply("0.2.0", notes)
        self.assertEqual(read(os.path.join(self.dir.name, "VERSION")), "0.2.0\n")
        log = read(os.path.join(self.dir.name, "CHANGELOG.md"))
        self.assertIn("## [0.2.0]", log)
        self.assertIn("Shiny thing", log)
        self.assertNotIn("first", log.split("## [0.1.0]")[0], "commits before the tag are not repeated")
        text = read(notes)
        self.assertIn("Broken thing", text)
        self.assertIn("SpaceLens-0.2.0.dmg", text)

    def test_apply_keeps_a_hand_written_section(self):
        self.commit("feat: first", version="0.1.0")
        with open(os.path.join(self.dir.name, "CHANGELOG.md"), "w") as f:
            f.write("# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- written by hand\n")
        notes = os.path.join(self.dir.name, "notes.md")
        r.apply("0.1.0", notes)
        self.assertIn("written by hand", read(notes))
        self.assertEqual(read(os.path.join(self.dir.name, "CHANGELOG.md")).count("## [0.1.0]"), 1)


if __name__ == "__main__":
    unittest.main()
