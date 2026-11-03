#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Static checks for every patch in this repository.

  patch-check.py --repo <dir> --tarball <linux-VERSION.tar.xz|.tar.gz> [--workdir <dir>]

Checks a patch series locally against the pristine kernel.org tarball,
without building anything. From the top of the repository:

  ./build.sh fetch verify
  ./build.sh shell sh -c 'python3 scripts/patch-check.py --repo . \
      --tarball /work/dl/linux-$(scripts/build.sh version).tar.xz'

(a release candidate: .tar.gz instead of .tar.xz)

Needs python3 (standard library only), git, perl, and tar with xz or gzip. The
canonical form below is what git 2.47 exports, as in build-env/; run the
check in that environment when another git version reports differences.

Checks, all findings collected (no fail-fast):
  a) the series file patches/series -- every entry exists, no duplicates,
     every *.patch listed exactly once; every entry is <series>/<file>.patch,
     one directory per upstream series, and the patches of a series follow
     each other
  b) every listed patch: a git format-patch file; tag rules of CONTRIBUTING.md
     for our own patches and for patches from other authors (their own
     Assisted-by in any upstream form; ours, after the "[ adapted" note,
     as 'LLM [tool...]')
  c) kernel series: applies with git am to the pristine tarball, in order, and
     every stored file is byte for byte what the canonical format-patch
     command exports from the applied commit
  d) checkpatch --strict on our own kernel patches: ERROR fails, WARNING fails
     unless its type is in scripts/checkpatch-allowed-warnings, CHECK is a
     notice. Each patch is checked against the tree with the patches before
     it applied, as upstream checks a patch against its base: it sees the
     bindings an earlier series adds. checkpatch.pl and its data files are
     the pristine tarball's, copied before any patch is applied; it does not
     run while the series has changed a script it would run from the tree.

--workdir keeps the pristine git tree between runs (worth it when the check
runs many times); it is reset to the pristine commit before every use.
Without it a temporary tree is built and removed.

A patch whose subject starts with "TEST ONLY" is a finding: test
instruments are never part of the series.

Exit: 0 clean, 1 findings, 2 the check itself could not run.
"""

import argparse
import difflib
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

OWN_FROM = "Norman Herms <dockseed@proton.me>"
SERIES = "patches/series"
ALLOWED_WARNINGS = "scripts/checkpatch-allowed-warnings"
# The canonical form: stored patches are exactly what this exports.
FORMAT_PATCH = ["format-patch", "-1", "--stdout", "--zero-commit",
                "--no-signature", "--abbrev=12"]
CHECKPATCH_ARGS = ["--strict", "--show-types", "--terse", "--no-signoff",
                   "--ignore", "FILE_PATH_CHANGES"]
# checkpatch.pl and the files it reads from its own directory, copied from the
# pristine tree before any patch is applied: nothing a patch changes runs.
CHECKPATCH_FILES = ["scripts/checkpatch.pl", "scripts/spelling.txt",
                    "scripts/const_structs.checkpatch"]
# Scripts checkpatch runs from the tree it checks against (--root):
# get_maintainer.pl for the MAINTAINERS status, spdxcheck.py (only with a git
# directory, which it never gets here). They must be the pristine ones.
CHECKPATCH_RUNS = ["scripts/get_maintainer.pl", "scripts/spdxcheck.py"]

# Tags that count as trailers (compared case-insensitively). The kernel's
# signature tags, the link tags, and Co-Authored-By for the AI rule.
KNOWN_TAGS = {t.lower(): t for t in [
    "Signed-off-by", "Co-developed-by", "Acked-by", "Tested-by",
    "Reviewed-by", "Reported-by", "Suggested-by", "Assisted-by", "Cc", "To",
    "Link", "Closes", "Fixes", "Co-Authored-By",
]}
OWN_FORBIDDEN = ["Signed-off-by", "Co-developed-by", "Tested-by"]
NO_AI_TAGS = ["Signed-off-by", "Co-developed-by", "Reviewed-by", "Tested-by",
              "Co-Authored-By"]
AI_NAME = re.compile(r"claude|anthropic", re.I)
# Ours: "LLM [tool...]", as mainline writes it. Patches by other authors keep
# whatever form upstream used (e.g. "Assisted-by: LLM coccinelle"); ours on
# such a patch is the last Assisted-by, after the "[ adapted" note.
ASSISTED_RE = re.compile(r"^Assisted-by: LLM( \S+)*$")
UPSTREAM_ASSISTED_RE = re.compile(r"^Assisted-by: \S+( \S+)*$")
# The earlier form, "Claude:MODEL [tool...]", is a finding.
OLD_ASSISTED_RE = re.compile(r"^Assisted-by: Claude:\S+( \S+)*$", re.I)
TESTED_ON = "Tested on Radxa Cubie A7S: "
# A test instrument: "[PATCH] TEST ONLY: ..." (never in the series).
TEST_SUBJECT_RE = re.compile(r"^(\[PATCH[^\]]*\]\s*)?TEST[ -]ONLY\b", re.I)
FROM_LINE_RE = re.compile(r"^From [0-9a-f]{40} Mon Sep 17 00:00:00 2001$")
DIFF_GIT_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
# patches/series: <series>/<file>.patch, one directory per upstream series.
ENTRY_RE = re.compile(r"^([a-z0-9][a-z0-9._-]*)/[^/]+\.patch$")
CHECKPATCH_LINE = re.compile(
    r"^(?:.*?:(\d+): )?(ERROR|WARNING|CHECK):([A-Za-z0-9_]+): (.*)$")

# Deterministic git: no user or system configuration, fixed identity.
# gc.auto=0: the pristine commit leaves ~90,000 loose objects, so git would
# start a gc in the background that still writes into .git while the caller
# removes the tree ("rm: ... .git: Directory not empty").
GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "gc.auto",
    "GIT_CONFIG_VALUE_0": "0",
    "GIT_AUTHOR_NAME": "pristine",
    "GIT_AUTHOR_EMAIL": "pristine@example.org",
    "GIT_COMMITTER_NAME": "pristine",
    "GIT_COMMITTER_EMAIL": "pristine@example.org",
    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
    "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
    "LC_ALL": "C",
    "TZ": "UTC",
}
MARKER = "patch-check-tarball"   # in .git of a --workdir tree

findings = []


class Broken(Exception):
    """The check itself could not run (exit 2)."""


def finding(path, msg, detail=None):
    findings.append((path, msg, detail or []))


def notice(path, msg):
    print(f"::notice::{path}: {msg}")


def git(tree, *args, check=True, stdin=None):
    env = dict(os.environ)
    env.update(GIT_ENV)
    r = subprocess.run(["git", "-C", tree, *args], env=env, input=stdin,
                       capture_output=True)
    if check and r.returncode != 0:
        raise Broken(f"git {' '.join(args)} failed ({r.returncode}): "
                     + r.stderr.decode(errors="replace").strip())
    return r


# --- a) series ---------------------------------------------------------------

def read_series(repo, series=SERIES, base=None, optional=False):
    """Entries of a series file in order, with findings for its structure.

    The entries are paths below <base> (default: the directory of the series
    file). With <optional> a missing file is a finding only while <base>
    holds a *.patch."""
    base = base if base is not None else os.path.dirname(series)
    path = os.path.join(repo, series)
    if not os.path.isfile(path):
        unlisted = []
        for dirpath, _, files in os.walk(os.path.join(repo, base)):
            unlisted += [os.path.relpath(os.path.join(dirpath, fn), repo)
                         for fn in files if fn.endswith(".patch")]
        if not optional or unlisted:
            finding(series, "series file is missing"
                    + (f" (but {', '.join(sorted(unlisted))} exist)"
                       if unlisted else ""))
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")

    entries, seen = [], {}
    done, current = {}, None   # series directory -> its first line; the one in progress
    for n, raw in enumerate(lines, 1):
        e = re.sub(r"\s*#.*", "", raw).strip()   # as build.sh reads it
        if not e:
            continue
        where = f"line {n}: {e}"
        if re.search(r"\s", e):
            finding(series, f"{where}: white space in a patch path")
            continue
        if os.path.normpath(e) != e or e.startswith(("/", "../")):
            finding(series, f"{where}: not a plain relative path")
            continue
        if not e.endswith(".patch"):
            finding(series, f"{where}: entries must be *.patch files")
        if e in seen:
            finding(series, f"{where}: duplicate entry (first on line {seen[e]})")
            continue
        seen[e] = n
        if not os.path.isfile(os.path.join(repo, base, e)):
            finding(series, f"{where}: no such file")
            continue
        m = ENTRY_RE.match(e)
        if m is None:
            finding(series, f"{where}: not <series>/<file>.patch (one "
                    "directory per upstream series, lower case)")
        elif m.group(1) != current:
            if m.group(1) in done:
                finding(series, f"{where}: series {m.group(1)} began on line "
                        f"{done[m.group(1)]} -- the patches of a series "
                        "follow each other")
            else:
                done[m.group(1)] = n
            current = m.group(1)
        entries.append(os.path.join(base, e))

    listed = {os.path.join(base, e) for e in seen}
    for dirpath, _, files in os.walk(os.path.join(repo, base)):
        for fn in files:
            rel = os.path.relpath(os.path.join(dirpath, fn), repo)
            if fn.endswith(".patch") and rel not in listed:
                finding(rel, f"not listed in {series}")
    return entries


# --- b) one patch file -------------------------------------------------------

def parse_patch(path, rel):
    """Returns (own?, [(a, b) paths]) or None when not a format-patch file."""
    with open(path, "rb") as f:
        data = f.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        finding(rel, "not valid UTF-8")
        return None
    lines = text.split("\n")
    ok = True
    if not FROM_LINE_RE.match(lines[0]):
        finding(rel, "first line is not 'From <40 hex> Mon Sep 17 00:00:00 "
                "2001' -- not a git format-patch file")
        ok = False

    headers, i = {}, 1
    while i < len(lines) and lines[i] != "":
        m = re.match(r"^([A-Za-z-]+): ?(.*)$", lines[i])
        if m:
            headers[m.group(1).lower()] = m.group(2)
        i += 1
    for h in ("From", "Date", "Subject"):
        if h.lower() not in headers:
            finding(rel, f"no {h}: header")
            ok = False

    try:
        sep = lines.index("---", i)
    except ValueError:
        finding(rel, "no '---' line between the message and the diff")
        return None
    first_diff = next((k for k, l in enumerate(lines)
                       if l.startswith("diff --git ")), None)
    if first_diff is None:
        finding(rel, "no 'diff --git' line")
        return None
    if first_diff < sep:
        finding(rel, "'diff --git' before the '---' separator")
        return None
    if not ok:
        return None

    message = lines[i + 1:sep]
    own = headers.get("from") == OWN_FROM
    if TEST_SUBJECT_RE.match(headers.get("subject", "")):
        finding(rel, "a TEST ONLY patch in the series")

    tags = []   # (canonical tag, whole line)
    pos = {}    # index in tags -> line number in the message
    for n, l in enumerate(message):
        m = re.match(r"^([A-Za-z-]+): ", l)
        if m and m.group(1).lower() in KNOWN_TAGS:
            tags.append((KNOWN_TAGS[m.group(1).lower()], l))
            pos[len(tags) - 1] = n
    note = next((n for n, l in enumerate(message)
                 if l.startswith("[ adapted")), None)

    def count(tag):
        return sum(1 for t, _ in tags if t == tag)

    for t, l in tags:
        if t in NO_AI_TAGS and AI_NAME.search(l):
            finding(rel, f"an AI must not be named in {t}: {l}")
    assisted = [l for t, l in tags if t == "Assisted-by"]
    assisted_at = [pos[k] for k, (t, _) in enumerate(tags)
                   if t == "Assisted-by"]

    if own:
        for l in assisted:
            if not ASSISTED_RE.match(l):
                finding(rel, f"Assisted-by is not 'LLM [tool...]': {l}")
        for t in OWN_FORBIDDEN:
            if count(t):
                finding(rel, f"our own patch carries {t} (see CONTRIBUTING.md)")
        if count("Assisted-by") != 1:
            finding(rel, "our own patch needs exactly one Assisted-by "
                    f"(has {count('Assisted-by')})")
        if not any(l.startswith(TESTED_ON) and l[len(TESTED_ON):].strip()
                   for l in message):
            finding(rel, f"our own patch has no '{TESTED_ON}<what was run "
                    "and observed>' line")
    else:
        if not count("Signed-off-by"):
            finding(rel, "patch by another author without Signed-off-by")
        for l in assisted:
            if not UPSTREAM_ASSISTED_RE.match(l):
                finding(rel, f"Assisted-by is not 'NAME [tool...]': {l}")
        # Ours is the Assisted-by after the note (upstream's come before it
        # or are indistinguishable, and any form is fine for them). An old
        # Claude:MODEL one can only be ours.
        for l in assisted:
            if OLD_ASSISTED_RE.match(l):
                finding(rel, f"old form, use 'Assisted-by: LLM [tool...]': {l}")
        if note is not None:
            after = [l for l, at in zip(assisted, assisted_at) if at > note]
            if after and not ASSISTED_RE.match(after[-1]):
                finding(rel, "our Assisted-by after the '[ adapted ... ]' "
                        f"note is not 'LLM [tool...]': {after[-1]}")

    paths = []
    for l in lines[first_diff:]:
        if l.startswith("diff --git "):
            m = DIFF_GIT_RE.match(l)
            if not m:
                finding(rel, f"cannot read the paths of: {l}")
                continue
            paths.append((m.group(1), m.group(2)))
    return own, paths


# --- c) and d) pristine tree -------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pristine_tree(tarball, workdir):
    """A git tree of the unpacked tarball at tag 'pristine', clean."""
    tsum = sha256(tarball)
    marker = os.path.join(workdir, ".git", MARKER)
    if os.path.isfile(marker):
        with open(marker) as f:
            if f.read().strip() == tsum:
                shutil.rmtree(os.path.join(workdir, ".git", "rebase-apply"),
                              ignore_errors=True)
                git(workdir, "reset", "-q", "--hard", "pristine")
                git(workdir, "clean", "-q", "-f", "-f", "-d", "-x")
                return workdir
    if os.path.exists(workdir) and os.listdir(workdir) \
            and not os.path.isfile(marker):
        raise Broken(f"{workdir} is not empty and not a patch-check tree")
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)
    # A release's .tar.xz, or a release candidate's .tar.gz (kernel.org's
    # snapshot of the tag).
    z = "-xzf" if tarball.endswith(".tar.gz") else "-xJf"
    r = subprocess.run(["tar", "-C", workdir, "--strip-components=1",
                        z, tarball], capture_output=True)
    if r.returncode != 0:
        raise Broken(f"cannot unpack {tarball}: "
                     + r.stderr.decode(errors="replace").strip())
    # The repository is ours, never the tarball's: its config and hooks
    # would run in every git command below.
    if os.path.lexists(os.path.join(workdir, ".git")):
        raise Broken(f"{tarball} holds a .git -- not a pristine kernel")
    git(workdir, "init", "-q")
    git(workdir, "-c", "core.looseCompression=0", "add", "-A", "-f")
    git(workdir, "commit", "-q", "--no-verify", "-m", "pristine")
    git(workdir, "tag", "pristine")
    with open(marker, "w") as f:
        f.write(tsum + "\n")
    return workdir


def load_allowed(repo, path=None):
    # --allowlist takes a copy from elsewhere, for example from the target
    # branch. Without it, the repository's own copy is used, so a change to
    # the list is reviewed like any other change.
    path = path or os.path.join(repo, ALLOWED_WARNINGS)
    allowed = {}
    if not os.path.isfile(path):
        finding(ALLOWED_WARNINGS, "file is missing")
        return allowed
    with open(path, encoding="utf-8") as f:
        for n, l in enumerate(f, 1):
            l = l.strip()
            if not l or l.startswith("#"):
                continue
            m = re.match(r"^([A-Z0-9_]+)\s+(\S.*)$", l)
            if not m:
                finding(ALLOWED_WARNINGS, f"line {n}: expected 'TYPE  reason'")
                continue
            allowed[m.group(1)] = m.group(2)
    return allowed


def checkpatch_copy(tree, scratch):
    """The pristine checkpatch.pl and its data files, outside the tree."""
    d = os.path.join(scratch, "checkpatch", "scripts")
    os.makedirs(d)
    for f in CHECKPATCH_FILES:
        if not os.path.isfile(os.path.join(tree, f)):
            raise Broken(f"the pristine tree has no {f}")
        shutil.copyfile(os.path.join(tree, f),
                        os.path.join(d, os.path.basename(f)))
    return os.path.join(d, "checkpatch.pl")


def checkpatch(script, tree, repo, rel, allowed, scratch):
    """checkpatch on one patch, against the tree as it stands."""
    changed = git(tree, "diff", "--name-only", "pristine", "HEAD", "--",
                  *CHECKPATCH_RUNS).stdout.decode().split()
    if changed:
        finding(rel, "checkpatch not run: the patches before it change "
                + ", ".join(changed) + ", which checkpatch runs from the tree")
        return
    # Run outside any git directory: checkpatch would otherwise ask git for
    # upstream commits the pristine tree does not have. Its CamelCase cache
    # lands in the cwd.
    env = dict(os.environ)
    env["GIT_DIR"] = os.path.join(scratch, "no-git")
    r = subprocess.run(["perl", script,
                        f"--root={tree}", *CHECKPATCH_ARGS,
                        os.path.join(repo, rel)],
                       cwd=scratch, env=env, capture_output=True)
    out = r.stdout.decode(errors="replace")
    err = r.stderr.decode(errors="replace").strip()
    if r.returncode not in (0, 1):
        raise Broken(f"checkpatch exited {r.returncode} on {rel}: {err}")
    if err:
        print(f"checkpatch stderr on {rel}:\n{err}")
    reported = 0
    for l in out.splitlines():
        m = CHECKPATCH_LINE.match(l)
        if not m:
            continue
        line, level, typ, msg = m.groups()
        reported += 1
        where = f"checkpatch {level} {typ}" + (f" (line {line})" if line else "")
        if level == "ERROR":
            finding(rel, f"{where}: {msg}")
        elif level == "WARNING" and typ not in allowed:
            finding(rel, f"{where}: {msg}")
        elif level == "WARNING":
            notice(rel, f"{where}: {msg} [allowed: {allowed[typ]}]")
        else:
            notice(rel, f"{where}: {msg}")
    if r.returncode == 1 and not reported:
        raise Broken(f"checkpatch failed on {rel} without a readable report:\n"
                     + out + err)


def mark_trailing(line):
    """Trailing white space made visible in a diff line (after its prefix)."""
    head, text = line[:1], line[1:]
    body = text.rstrip()
    return head + body + "~" * (len(text) - len(body))


def apply_and_compare(tree, repo, kernel, own, allowed, scratch, script):
    """git am every kernel patch in order, checkpatch each of ours against the
    tree before it; compare the canonical export."""
    applied = []   # (rel, commit)
    unchecked = [rel for rel in kernel if rel in own]   # in series order
    head = git(tree, "rev-parse", "HEAD").stdout.decode().strip()
    for rel in kernel:
        if rel in unchecked:
            checkpatch(script, tree, repo, rel, allowed, scratch)
            unchecked.remove(rel)
        r = git(tree, "am", "--no-3way", "--committer-date-is-author-date",
                os.path.join(repo, rel), check=False)
        if r.returncode != 0:
            msg = (r.stdout + r.stderr).decode(errors="replace")
            detail = [l for l in msg.splitlines()
                      if l.startswith(("error:", "Patch failed", "fatal:"))][:10]
            finding(rel, "does not apply with git am to the pristine tree "
                    "plus the patches before it; later patches not tried",
                    detail)
            git(tree, "am", "--abort", check=False)
            break
        commits = git(tree, "rev-list", "--reverse", f"{head}..HEAD") \
            .stdout.decode().split()
        if len(commits) != 1:
            finding(rel, f"holds {len(commits)} patches, expected one")
        if commits:
            applied.append((rel, commits[-1]))
            head = commits[-1]
    # Ours after a patch that does not apply: against the tree as far as the
    # series applies, so that none of them goes unchecked.
    for rel in unchecked:
        checkpatch(script, tree, repo, rel, allowed, scratch)

    for rel, commit in applied:
        want = git(tree, *FORMAT_PATCH, commit).stdout
        with open(os.path.join(repo, rel), "rb") as f:
            have = f.read()
        if have != want:
            diff = list(difflib.unified_diff(
                have.decode(errors="replace").splitlines(),
                want.decode(errors="replace").splitlines(),
                "stored", "canonical", n=1, lineterm=""))
            finding(rel, "not in canonical form (git "
                    + " ".join(FORMAT_PATCH) + ")",
                    [mark_trailing(d) for d in diff[:20]])


# -----------------------------------------------------------------------------

def run(args):
    repo = os.path.abspath(args.repo)
    if not os.path.isdir(repo):
        raise Broken(f"no repository at {args.repo}")
    tarball = os.path.abspath(args.tarball)
    if not os.path.isfile(tarball):
        raise Broken(f"no tarball at {args.tarball}")

    kernel, own_kernel = [], []
    for rel in read_series(repo):
        parsed = parse_patch(os.path.join(repo, rel), rel)
        kernel.append(rel)
        if parsed is not None and parsed[0]:
            own_kernel.append(rel)
    allowed = load_allowed(repo, args.allowlist and os.path.abspath(args.allowlist))

    if not kernel:
        print("kernel series is empty -- nothing to apply or checkpatch")
        return
    scratch = tempfile.mkdtemp(prefix="patch-check.")
    try:
        tree = pristine_tree(tarball, args.workdir
                             or os.path.join(scratch, "tree"))
        script = checkpatch_copy(tree, scratch)
        apply_and_compare(tree, repo, kernel, set(own_kernel),
                          allowed, scratch, script)
        print(f"kernel series: {len(kernel)} patch(es), "
              f"{len(own_kernel)} of them ours (checkpatch)")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tarball", required=True)
    ap.add_argument("--workdir", help="keep the pristine tree here between runs")
    ap.add_argument("--allowlist", help="checkpatch allow list to use instead of the "
                    "repository's own scripts/checkpatch-allowed-warnings")
    args = ap.parse_args()
    if args.workdir:
        args.workdir = os.path.abspath(args.workdir)
    try:
        run(args)
    except Broken as e:
        print(f"::error::patch-check could not run: {e}")
        return 2
    except OSError as e:
        print(f"::error::patch-check could not run: {e}")
        return 2
    for path, msg, detail in findings:
        print(f"::error::{path}: {msg}")
        for d in detail:
            print(f"    {d}")
    if findings:
        print(f"patch-check: {len(findings)} finding(s)")
        return 1
    print("patch-check: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
