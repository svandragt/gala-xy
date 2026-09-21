# Releasing

How to cut a gala-xy release. Follow it in order — the documentation refresh
comes before the tag, so the tag points at docs that match the code.

## Decide the version

gala-xy uses semantic versioning, judged by what a user notices:

- **Minor** (0.2.0 → 0.3.0) for a new feature, a change to how an existing
  feature behaves, or a new gschema key. New keys mean the schema has to be
  recompiled on upgrade, so they always deserve their own release.
- **Patch** (0.3.0 → 0.3.1) for fixes alone, with no new keys and no change to
  how anything behaves when it was already working.

There is no 1.0 yet. Until there is, treat every release as one people upgrade
by rebuilding, not by pinning.

If the only commits since the last tag are housekeeping — lint fixes, comment
rewording, build tidying — don't cut a release.

## Refresh the documentation first

Do this before anything else, and treat it as part of the release rather than a
chore that follows it. Read the commits since the last tag and check each
document against them:

```
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

- **README.md** — what a user needs: every feature, every gschema key with a
  `gsettings` example, the settings paths, installing and removing, known
  limitations.
- **SPEC.md** — the behavioural source of truth, in product terms with no
  reference to code. No class, file, function or gschema key names belong in
  it. New behaviour gets described here even when it needs no README change.
- **AGENTS.md** — the build, the architecture per source file, and the
  Mutter/vapi gotchas. Keep it accurate about what each file does; it is what
  an agent reads before touching the code.

A feature that shipped without reaching these is the usual gap. Check the
gschema against README.md key by key — an undocumented key is invisible.

## Check the tree

```
make build
make lint
```

Both must pass. There is no automated test suite yet, so also install the
plugin, log out and back in, and use it — see [#3](https://github.com/svandragt/gala-xy/issues/3).
Reloading with `gala --replace` or `systemctl --user kill` triggers an
unrelated Mutter crash, so log out instead.

## Tag it

Bump `version:` in `meson.build` to match, then:

```
git commit -am "Release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

## Write the release notes

Never leave the auto-generated commit list as the body. Write for someone who
uses the plugin but did not follow the work, in plain language, to the standard
of a good pull request description. Use these sections in this order:

1. **Highlights** — one line per key point, five or six at most, verbs first.
   No file names, no issue numbers.
2. **Upgrade** — the exact commands, and anything to do afterwards. Always
   mention logging out and back in. Mention recompiling schemas when a gschema
   key was added.
3. **Details** — one short subsection per highlight that needs more than a
   line. Say what the user sees, then why.
4. **How we checked** — the evidence. Name what was verified and how. While
   there is no test suite, say so plainly rather than implying coverage.
5. **Known gaps** — what still does not work, in the same plain language.
6. **Issues closed** — `#N (title)` for each.

Then publish:

```
gh release create vX.Y.Z --title "vX.Y.Z" --notes-file notes.md
```

Use `gh release edit vX.Y.Z --notes-file notes.md` to correct a published body.

British English throughout. No attribution footers and no session links, the
same as commit messages and issues.
