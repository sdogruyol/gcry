# Contributing to gcry

## Bug fixes must include a test

Every bug fix **must** include a reproducing test. This is the single most
important rule in this project — a GC whose bugs re-appear silently erodes
all confidence.

### Where to put the test

- **New regression:** `spec/regression/<issue-number>_<description>.cr`
- **Existing spec area:** Add to the relevant file in `spec/`

### CI enforcement

CI checks that `spec/regression/` contains at least one file, and that
the PR diff includes changes to spec files. A PR template checkbox
reminds you.

## Code style

- Run `crystal tool format` before committing (enforced by pre-commit hook).
- Run `make lint` (Ameba) before opening a PR.
- Keep line length reasonable (~100 chars preferred, 120 hard limit).
- Use `snake_case` for methods and variables, `CamelCase` for types.

## Testing before submitting

```bash
make spec              # unit specs
make spec-process      # process GC specs (-Dgc_none)
make invariants        # debug invariant checker
make fuzz-short        # fuzz test (5s)
make property-test     # property-based test
```

See `make help` for the full list of targets.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — new feature
- `fix:` — bug fix (must include test reference)
- `chore:` — tooling, CI, docs
- `perf:` — performance improvement

Reference the github issue if applicable: `fix: #123 - ...`

## PR checklist

- [ ] Bug fix includes a reproducing test in `spec/regression/`
- [ ] `crystal tool format` passes
- [ ] `make lint` passes
- [ ] All CI jobs pass