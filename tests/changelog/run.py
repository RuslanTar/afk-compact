#!/usr/bin/python3
"""tests/changelog/run.py: the probe files of tools/changelog-lint.

Usage: tests/changelog/run.py
  CHANGELOG.md and every good-*.md here must pass with no hit. Every bad/<rule>.md must fail with
  hits of <rule> and of no other rule, and every rule of the lint must have its bad file.
  Prints `ok` or `not ok` per file, then `CHANGELOG-TESTS: PASS|FAIL (...)`. Exit 0 or 1.
"""
import importlib.machinery, importlib.util, os, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def load_lint():
    path = os.path.join(REPO, "tools", "changelog-lint")
    loader = importlib.machinery.SourceFileLoader("changelog_lint", path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("changelog_lint", loader))
    loader.exec_module(mod)
    return mod


def main():
    lint = load_lint()
    good = ["CHANGELOG.md"] + sorted(f for f in os.listdir(HERE) if f.startswith("good-") and f.endswith(".md"))
    bad_dir = os.path.join(HERE, "bad")
    bad = sorted(f for f in os.listdir(bad_dir) if f.endswith(".md"))
    fails = []
    for f in good:
        hits = lint.lint_file(os.path.join(HERE, f))
        if hits:
            fails.append(f)
            print("not ok {}: {} hits, first: {} line {}: {}".format(f, len(hits), hits[0][1], hits[0][0], hits[0][2]))
        else:
            print("ok {}: no hit".format(f))
    for f in bad:
        rule = f[:-3]
        hits = lint.lint_file(os.path.join(bad_dir, f))
        fired = sorted({h[1] for h in hits})
        if rule not in lint.RULES:
            fails.append("bad/" + f)
            print("not ok bad/{}: {} is no rule of the lint".format(f, rule))
        elif fired != [rule]:
            fails.append("bad/" + f)
            print("not ok bad/{}: fired {}, want only {}".format(f, fired or "nothing", rule))
        else:
            print("ok bad/{}: {} {} hit(s)".format(f, rule, len(hits)))
    for rule in lint.RULES:
        if rule + ".md" not in bad:
            fails.append("bad/" + rule + ".md")
            print("not ok bad/{}.md: missing (every rule needs a red case)".format(rule))
    print("CHANGELOG-TESTS: {} ({} good, {} bad, {} rules{})".format(
        "FAIL" if fails else "PASS", len(good), len(bad), len(lint.RULES),
        "; failing: " + ", ".join(fails) if fails else ""))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
