---
title: Contributing
subtitle: How to report bugs, submit patches, run the test suite, and the coding conventions.
updated: 2026-03-16
github_url: https://github.com/OpenDigitalCC/ctrl-exec/blob/main/CONTRIBUTING.md
current_page: /contributing
---

# Reporting Bugs

Open an issue in the [project repository](https://github.com/OpenDigitalCC/ctrl-exec/issues) with:

- The installed version (`ced --version`)
- Platform and OS version
- Steps to reproduce
- Expected and actual behaviour

For security issues, contact the maintainers directly rather than opening a public issue.

# Submitting Patches

Fork the repository, create a branch, and submit a pull request. All code changes must include or update tests. Run the unit test suite before submitting.

# Running the Unit Test Suite

```bash
prove -Ilib t/
```

Or via the installer:

```bash
sudo ./install.sh --agent --run-tests
```

`prove` is required — Debian/Ubuntu: `libtest-simple-perl`; Alpine: `perl-test-simple`.

`t/auth.t` and `t/pairing-ctrl-exec.t` require `libjson-perl` / `perl-json` and skip automatically if not available.

# Running the Integration Tests

Integration tests require a working installation with at least one paired agent and test scripts installed on each agent.

Before running, disable rate limiting on each agent — the suite fires more than 10 connections per agent:

```bash
echo "disable_rate_limit = 1" >> /etc/ctrl-exec-agent/agent.conf
sudo systemctl kill --signal=HUP ctrl-exec-agent
```

Install test scripts on each agent:

```bash
sudo bash t/integration/setup-agent-scripts.sh
```

Run the full suite:

```bash
sudo bash t/integration/run-tests.sh
```

Run individual test files:

```bash
sudo bash t/integration/01-security-boundary.sh
```

## Test 15 — agent auth context

`15-agent-auth-context.sh` verifies the agent-side auth hook receives correct context fields. It requires the auth test infrastructure to be installed first:

```bash
sudo bash t/integration/setup-agent-scripts.sh --install-auth-test
sudo bash t/integration/15-agent-auth-context.sh
```

Remove the auth test infrastructure when done:

```bash
sudo bash t/integration/setup-agent-scripts.sh --remove-auth-test
```

Remove `disable_rate_limit` from `agent.conf` and reload when integration testing is complete.

# Coding Conventions

Public module functions
: Use named parameters (`my (%opts) = @_`). Test calls must pass parameter names, not positional arguments.

Private functions
: Prefixed `_`. Not part of the public API. Do not call them from tests.

Test file writes
: Use `File::Temp::tempdir(CLEANUP => 1)`. Never write to system paths in tests.

Assertion counts
: Declare with `use Test::More tests => N` or use `done_testing()`.

Reading before writing tests
: Read the current module source before writing tests for it. Verify parameter names, calling convention, and whether a function is public or private.

Integration test structure
: New integration test files are named `NN-description.sh` and follow the structure in `TESTING.md`: `source lib.sh`, `require_agents`, `assert_agents_reachable` before each describe block, `summary` as the last line.

Destructive tests
: Tests with destructive side-effects or special setup requirements must not be added to the default suite runner. Document them in `MANUAL-CHECKS.md`.
