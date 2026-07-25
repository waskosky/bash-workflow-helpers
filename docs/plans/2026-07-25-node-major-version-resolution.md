# Latest Node.js Release Within a Major Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the recommended workflow installer resolve and install the newest available Node.js release within a configurable major version.

**Architecture:** Keep nvm as the source of Node.js version information and installation. Read a numeric `NODE_MAJOR_VERSION` environment variable with a default of `24`, ask nvm for the latest remote release matching that major, install the exact resolved version, and make it the nvm default.

**Tech Stack:** Bash, nvm, shell regression tests

### Task 1: Test latest-release resolution

**Files:**
- Modify: `tests/recommended_workflow_setup_test.sh`

**Step 1: Write the failing test**

Add a test that installs a fake nvm implementation, configures `NODE_MAJOR_VERSION=22`, makes `nvm version-remote 22` return `v22.14.1`, and asserts these calls:

```text
version-remote 22
install v22.14.1
alias default v22.14.1
```

The fake `node` command must report `v22.14.1`, proving that the installer verifies the exact version it resolved.

**Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: FAIL because the current implementation calls `nvm install 24` directly and never resolves the configured major.

**Step 3: Write the minimal implementation**

Update `ensure_nvm_and_node` to:

```bash
local node_major_version="${NODE_MAJOR_VERSION:-24}"
local latest_node_version
latest_node_version="$(nvm version-remote "$node_major_version")"
nvm install "$latest_node_version"
nvm alias default "$latest_node_version"
```

Compare `node -v` to the exact resolved version.

**Step 4: Run the test to verify it passes**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: PASS.

### Task 2: Validate configuration and resolution failures

**Files:**
- Modify: `tests/recommended_workflow_setup_test.sh`
- Modify: `recommended_workflow_setup.sh`

**Step 1: Write a failing invalid-major test**

Add a test that sets `NODE_MAJOR_VERSION=22.x`, runs `ensure_nvm_and_node`, and expects a nonzero status with an error explaining that the value must be a positive integer.

**Step 2: Run the test to verify it fails**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: FAIL because the installer does not validate the configuration.

**Step 3: Add minimal major validation**

Require `NODE_MAJOR_VERSION` to match `^[1-9][0-9]*$` before querying nvm.

**Step 4: Run the test to verify it passes**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: PASS.

**Step 5: Write a failing remote-resolution test**

Add a test that makes `nvm version-remote 22` return `N/A` and asserts the installer exits before invoking `nvm install`.

**Step 6: Run the test to verify it fails**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: FAIL because the unresolved value is passed to `nvm install`.

**Step 7: Add minimal remote-version validation**

Require the result to match `v<configured-major>.<minor>.<patch>` and provide a clear error if nvm cannot resolve a release.

**Step 8: Run the test to verify it passes**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
```

Expected: PASS.

### Task 3: Document and verify the complete repository state

**Files:**
- Modify: `README.md`

**Step 1: Document configuration**

Describe `NODE_MAJOR_VERSION`, its default of `24`, and the guarantee that setup resolves the newest available release within that major.

**Step 2: Run all verification**

Run:

```bash
bash tests/recommended_workflow_setup_test.sh
bash tests/static_regression_test.sh
bash -n recommended_workflow_setup.sh tests/recommended_workflow_setup_test.sh
git diff --check
```

Expected: all commands exit successfully with no syntax or whitespace errors.

### Task 4: Publish and merge

**Step 1: Inspect and stage the complete requested scope**

Review `git status`, the full diff, and staged file list. Include the existing Claude settings installer work because the user explicitly requested everything in the worktree.

**Step 2: Commit and push**

Create one cohesive commit on `agent/update-node-installer-and-settings`, push it to `origin`, and open a pull request against `main`.

**Step 3: Merge and synchronize**

Merge the pull request after checks pass, update local `main` from `origin/main`, and verify that local `main`, `origin/main`, and the published commit agree.
