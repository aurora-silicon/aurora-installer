# Aurora Silicon assistant policy: aurora-installer

**Org rulebook:** https://github.com/aurora-silicon/agent-guidelines/blob/main/AGENTS.md (binding; this file only adds repo specifics).

This is Aurora Silicon's own policy for AI coding assistants working in
this repository. It is the only assistant instruction file this tree
carries. Upstream projects' instruction files are never carried here.

AGENTS.md, CLAUDE.md, GEMINI.md and .github/copilot-instructions.md are
copies of .github/aurora/AGENTS.md. The aurora-agent-policy workflow
puts them back if anything else replaces them, including an upstream
merge. To change the policy, edit .github/aurora/AGENTS.md.

## Repo specifics

### Building and testing this repository

- The installer app and helper (`macOS/`) are Swift only. Never add an interpreter, script engine or engine archive to the app or its execution path. Build- and CI-only Python stays outside the app; format it with four-space indentation and check it with `py_compile` and its focused tests.
- Format Swift with Xcode's bundled `swift-format`; the package must pass strict lint (`xcrun swift-format lint --strict --recursive ...`, as the macOS checks job runs it).
- Shell scripts use two-space indentation, Bash 5 conditionals (`[[ ]]` and `(( ))`) and `#!/bin/bash` shebangs. Build workers come from `AURORA_BUILD_JOBS` (default 10). In an exact `[[ == ]]` or `[[ != ]]` string comparison, quote a variable on the right-hand side so Bash treats metacharacters as literal text.
- Keep Markdown lines unwrapped except at structural boundaries.
- Run the native package checks from `macOS/`. There, `./test/all` runs the portable source, script and packaging-fixture checks. It stays unprivileged and never runs live disk changes, helper registration, signing, publication or deployment. See `macOS/docs/extraction.md` for provenance and `macOS/docs/validation.md` for the test boundary.
- For an installer change, run the focused script tests, the Swift tests in debug and release, and check the packaging structure, code-signing requirements and unsupported-host rejection as they apply. A source build is not proof of a physical install, and Linux checks do not replace the macOS checks.
- The release trust configuration, catalog verification and host restrictions are contracts: a change to them needs its own review and validation.
