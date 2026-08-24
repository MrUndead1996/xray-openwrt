# Signed APK Repository Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `xray-openwrt-integration` through a persistent, signed OpenWrt 25.12 APK repository on GitHub Pages, with safe one-time enrollment and normal `apk add`/`apk upgrade` operation.

**Architecture:** The pinned OpenWrt SDK remains the single source of the package and APK host tooling. Focused POSIX-shell helpers build a signed `packages.adb` repository and render an enrollment script; a tag-only GitHub Actions workflow validates, stages, and deploys the complete Pages tree. Router enrollment installs one public key and one custom feed file only after compatibility, fingerprint, and repository-verification checks pass.

**Tech Stack:** POSIX shell, OpenWrt 25.12 SDK, apk-tools v3 (`mkndx`, `adbdump`), OpenSSL P-256, GitHub Actions, GitHub Pages, existing shell test harness.

**Spec:** `docs/superpowers/specs/2026-08-24-apk-repository-delivery-design.md`

## Global Constraints

- Support only OpenWrt 25.12 on APK architecture `aarch64_cortex-a53`.
- Serve the feed at `https://mrundead1996.github.io/xray-openwrt/packages/25.12/aarch64_cortex-a53/packages.adb`.
- Never publish `/usr/bin/xray` or `/etc/xray/config.json` in the integration APK.
- Keep `/etc/config/xray` as an APK conffile and preserve both user configuration files across upgrades.
- Use the APK host tool from the SHA-256-pinned OpenWrt 25.12 SDK for index generation and verification.
- Sign `packages.adb` with a dedicated EC P-256 private key; never commit that private key.
- Do not use `--allow-untrusted` for router installation or upgrades after enrollment.
- Retain the current APK and the two immediately preceding version-release APKs.
- Never replace different bytes under an already published version-release filename.
- Pull-request jobs must not receive signing secrets or Pages deployment permissions.

## File Structure

- Create `scripts/build-apk-repository`: validate repository inputs and generate a signed `packages.adb` with the SDK APK tool.
- Create `scripts/render-repository-installer`: render the public-key fingerprint and feed URL into the enrollment template.
- Create `scripts/install-apk-repository.in`: fail-closed POSIX-shell enrollment template for OpenWrt routers.
- Create `tests/repository_build_test.sh`: mock-driven contract tests for repository generation and rendering.
- Create `tests/repository_install_test.sh`: mock-driven compatibility, fingerprint, verification, atomicity, and idempotency tests.
- Create `keys/xray-openwrt-repository.pem`: committed EC P-256 public key only.
- Create `keys/xray-openwrt-repository.pem.sha256`: committed SHA-256 fingerprint of the exact public-key bytes.
- Create `.github/workflows/release.yml`: tag validation, SDK build, repository assembly, signing, verification, retention, Release assets, and Pages deployment.
- Modify `tests/workflow_test.sh`: keep PR workflow assertions and add release-workflow security/publication assertions.
- Create `docs/repository.md`: operator enrollment, install, update, downgrade, recovery, and unenrollment guide.
- Modify `docs/openwrt-acceptance.md`: add trusted-feed and package-upgrade evidence.
- Modify `README.md`: replace temporary artifact delivery with the signed feed and correct the stale status list.

---

### Task 1: Signed Repository Builder

**Files:**
- Create: `scripts/build-apk-repository`
- Create: `scripts/render-repository-installer`
- Create: `tests/repository_build_test.sh`

**Interfaces:**
- Consumes: `build-apk-repository APK_TOOL SIGNING_KEY REPOSITORY_DIR`; `REPOSITORY_DIR` already contains one or more canonical `xray-openwrt-integration-<version>-r<release>.apk` files.
- Produces: signed `REPOSITORY_DIR/packages.adb`; successful `apk adbdump --format json` validation.
- Consumes: `render-repository-installer TEMPLATE PUBLIC_KEY FEED_URL OUTPUT`.
- Produces: executable enrollment script with `@KEY_SHA256@` and `@FEED_URL@` replaced exactly once.

- [ ] **Step 1: Write failing repository-builder tests**

Add cases that create a mock APK tool and assert the exact OpenWrt command contract:

```sh
cat > "$TEST_ROOT/bin/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$1" in
    mkndx)
        while [ "$#" -gt 0 ]; do
            [ "$1" = --output ] && { shift; : > "$1"; exit 0; }
            shift
        done
        exit 1
        ;;
    adbdump)
        [ "$2" = --format ] && [ "$3" = json ] && [ -s "$4" ]
        ;;
esac
EOF
```

Assert failure for no APKs, a missing signing key, a non-executable APK tool,
and a noncanonical APK filename. Assert success invokes:

```text
mkndx --root <repository> --keys-dir <repository> --allow-untrusted --sign <key> --output <repository>/packages.adb <apk...>
adbdump --format json <repository>/packages.adb
```

Test the renderer with a fixed public key and assert that the SHA-256 emitted
by `sha256sum` replaces `@KEY_SHA256@`, the URL replaces `@FEED_URL@`, no `@...@`
token remains, and mode `0755` is set.

- [ ] **Step 2: Run the tests and confirm the missing scripts fail**

Run: `rtk sh tests/repository_build_test.sh`

Expected: FAIL because `scripts/build-apk-repository` and
`scripts/render-repository-installer` do not exist.

- [ ] **Step 3: Implement the minimal repository builder**

Use `set -eu`, normalize all four input paths before changing directory, reject
symlinks and filenames outside this pattern:

```sh
case "$name" in
    xray-openwrt-integration-[0-9]*-r[0-9]*.apk) ;;
    *) fail "unexpected APK filename: $name" ;;
esac
```

Generate and validate the index with the pinned tool interface used by
OpenWrt's own package Makefile:

```sh
"$apk_tool" mkndx \
    --root "$repository_dir" \
    --keys-dir "$repository_dir" \
    --allow-untrusted \
    --sign "$signing_key" \
    --output "$repository_dir/packages.adb.tmp" \
    "$@"
"$apk_tool" adbdump --format json "$repository_dir/packages.adb.tmp" >/dev/null
mv "$repository_dir/packages.adb.tmp" "$repository_dir/packages.adb"
```

Trap removal of `packages.adb.tmp`; never overwrite the prior index before
validation succeeds.

- [ ] **Step 4: Implement the renderer**

Require an HTTPS feed URL ending in `/packages.adb`, compute:

```sh
key_sha256=$(sha256sum "$public_key" | awk '{print $1}')
```

Escape replacement data for `sed`, render to `OUTPUT.tmp`, reject remaining
`@[A-Z_][A-Z_]*@` tokens, set mode `0755`, then atomically rename to `OUTPUT`.

- [ ] **Step 5: Run focused and full host tests**

Run: `rtk sh tests/repository_build_test.sh && rtk sh tests/run.sh`

Expected: repository tests PASS; all suites report zero failures.

- [ ] **Step 6: Commit the builder**

```sh
git add scripts/build-apk-repository scripts/render-repository-installer tests/repository_build_test.sh
git commit -m "feat: build signed APK repository index"
```

---

### Task 2: Fail-Closed Router Enrollment

**Files:**
- Create: `scripts/install-apk-repository.in`
- Create: `tests/repository_install_test.sh`

**Interfaces:**
- Consumes: rendered constants `@KEY_SHA256@` and `@FEED_URL@`.
- Consumes runtime files `/etc/openwrt_release`, `/etc/apk/arch`, `/etc/apk/keys/`, and `/etc/apk/repositories.d/customfeeds.list`.
- Produces `/etc/apk/keys/xray-openwrt-repository.pem` and exactly one feed line in `customfeeds.list` only after all preflight checks succeed.
- Test overrides: `XRAY_ETC_ROOT`, `XRAY_FETCH`, and `XRAY_APK` default to `/etc`, `uclient-fetch`, and `apk` respectively.

- [ ] **Step 1: Write failing enrollment tests**

Build a rendered fixture with the renderer from Task 1. Mock `uclient-fetch` to
copy a fixture key and mock APK verification as:

```sh
cat > "$TEST_ROOT/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$MOCK_LOG"
[ "$*" = "--keys-dir $EXPECTED_KEYS_DIR verify $DOWNLOADED_INDEX" ] || exit 1
exit "${APK_VERIFY_STATUS:-0}"
EOF
```

Cover these cases independently:

- `DISTRIB_RELEASE='25.12.2'` and arch `aarch64_cortex-a53` succeed;
- another release or architecture fails before any file under the target
  `/etc/apk` changes;
- a downloaded key with the wrong SHA-256 fails before mutation;
- failed index download or `apk --keys-dir <temporary> verify <index>` leaves
  the prior key/feed bytes unchanged;
- a successful run installs mode `0644` key and feed files;
- two successful runs leave one exact feed URL line and unchanged hashes.

- [ ] **Step 2: Run the test and confirm the template is missing**

Run: `rtk sh tests/repository_install_test.sh`

Expected: FAIL because `scripts/install-apk-repository.in` does not exist.

- [ ] **Step 3: Implement compatibility and download preflight**

Source the overridden `${XRAY_ETC_ROOT}/openwrt_release`, require:

```sh
case "$DISTRIB_RELEASE" in 25.12|25.12.*) ;; *) fail 'unsupported OpenWrt release' ;; esac
[ "$(cat "${XRAY_ETC_ROOT}/apk/arch")" = aarch64_cortex-a53 ] || fail 'unsupported APK architecture'
```

Download the public key and `@FEED_URL@` index into a `mktemp -d` directory,
trap cleanup, and compare the exact key bytes to the rendered SHA-256:

```sh
[ "$(sha256sum "$tmp/key.pem" | awk '{print $1}')" = '@KEY_SHA256@' ] || fail 'repository key fingerprint mismatch'
```

- [ ] **Step 4: Verify trust before persistent writes**

Copy only the downloaded key into `$tmp/keys`, then require:

```sh
"$apk_cmd" --keys-dir "$tmp/keys" verify "$tmp/packages.adb"
```

Do not pass `--allow-untrusted`. Only after success, construct complete key and
feed candidates, use mode `0644`, and `mv` them into place. Preserve comments
and unrelated lines from `customfeeds.list`, remove duplicate exact feed URLs,
then append one URL.

- [ ] **Step 5: Run focused and full host tests**

Run: `rtk sh tests/repository_install_test.sh && rtk sh tests/run.sh`

Expected: all enrollment cases PASS and the complete suite has zero failures.

- [ ] **Step 6: Commit enrollment**

```sh
git add scripts/install-apk-repository.in tests/repository_install_test.sh
git commit -m "feat: add trusted APK repository enrollment"
```

---

### Task 3: Provision the Repository Public Key Contract

**Files:**
- Create: `keys/xray-openwrt-repository.pem`
- Create: `keys/xray-openwrt-repository.pem.sha256`
- Modify: `.gitignore`
- Modify: `tests/repository_build_test.sh`

**Interfaces:**
- Produces committed public key and fingerprint used by the release workflow.
- Produces GitHub environment secret `XRAY_APK_SIGNING_KEY` containing the matching private PEM; secret creation remains a maintainer operation.

- [ ] **Step 1: Add a failing secret-safety test**

Assert the committed key starts with `-----BEGIN PUBLIC KEY-----`, does not
contain `PRIVATE`, has curve `prime256v1` when inspected with OpenSSL, and its
SHA-256 equals the sidecar file. Assert `.gitignore` rejects `*.key` and
`*private*.pem` under `keys/`.

- [ ] **Step 2: Run the test and confirm the key is absent**

Run: `rtk sh tests/repository_build_test.sh`

Expected: FAIL on missing `keys/xray-openwrt-repository.pem`.

- [ ] **Step 3: Generate the production key pair without placing the private key in the repository**

Run from a secured maintainer workstation:

```sh
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/xray-openwrt-repository-private.pem
openssl ec -in /tmp/xray-openwrt-repository-private.pem -pubout -out keys/xray-openwrt-repository.pem
sha256sum keys/xray-openwrt-repository.pem | awk '{print $1}' > keys/xray-openwrt-repository.pem.sha256
```

Store the full private PEM as the protected GitHub environment secret
`XRAY_APK_SIGNING_KEY`, keep an encrypted offline backup, and remove the
temporary workstation copy only after both stores are verified.

- [ ] **Step 4: Add private-key ignore rules and run the safety tests**

Append narrowly scoped rules:

```gitignore
keys/*.key
keys/*private*.pem
```

Run: `rtk sh tests/repository_build_test.sh && rtk git grep -n 'BEGIN.*PRIVATE KEY' -- . ':!docs/superpowers/**'`

Expected: tests PASS and `git grep` produces no matches.

- [ ] **Step 5: Commit only public material**

```sh
git add .gitignore keys/xray-openwrt-repository.pem keys/xray-openwrt-repository.pem.sha256 tests/repository_build_test.sh
git diff --cached --check
git commit -m "chore: add APK repository public key"
```

---

### Task 4: Tag-Only Release and Pages Workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `tests/workflow_test.sh`

**Interfaces:**
- Consumes: tag `v<PKG_VERSION>`, protected secret `XRAY_APK_SIGNING_KEY`, committed public key, APK assets from the two preceding GitHub Releases, and pinned SDK.
- Produces: Pages artifact rooted at `packages/25.12/aarch64_cortex-a53/`, GitHub Release assets, and deploys through `actions/deploy-pages`.

- [ ] **Step 1: Extend workflow contract tests first**

Assert the new workflow contains:

```text
on: push: tags: - 'v*'
permissions: contents: write, pages: write, id-token: write
environment: github-pages
XRAY_APK_SIGNING_KEY
scripts/build-apk-repository
scripts/render-repository-installer
actions/configure-pages@
actions/upload-pages-artifact@
actions/deploy-pages@
```

Assert `pull_request:` is absent from `release.yml`, the PR workflow still has
only `contents: read`, and the release workflow contains no literal private
key. Assert exact version comparison strips `refs/tags/v` and compares it to
`PKG_VERSION`.

- [ ] **Step 2: Run workflow tests and confirm release workflow is missing**

Run: `rtk sh tests/workflow_test.sh`

Expected: FAIL because `.github/workflows/release.yml` is absent.

- [ ] **Step 3: Add build and tag validation jobs**

Reuse the exact SDK URL and SHA-256 from `build.yml`. Run `sh tests/run.sh`,
extract `PKG_VERSION` with:

```sh
package_version=$(sed -n 's/^PKG_VERSION:=//p' Makefile)
tag_version=${GITHUB_REF_NAME#v}
[ "$tag_version" = "$package_version" ]
```

Build exactly one APK and run the same required/forbidden content checks as
the PR workflow. Keep signing and Pages permissions on the publication job,
not on untrusted test/build jobs.

- [ ] **Step 4: Add immutable repository staging and retention**

Query GitHub Releases through `gh api`, excluding the release currently being
published, and download the integration APK asset from the two newest releases
that contain one. Initialize an empty target directory when no prior release
exists. Reject duplicate version-release filenames with different bytes.
Combine those zero-to-two immutable APKs with the newly built APK, then sort
them with the SDK APK tool's version comparison and assert that no more than
three remain. A GitHub Release asset is the durable source for retained APKs;
the ephemeral Pages deployment artifact is not used as history.

Write the secret to a runner-temporary file with `umask 077`, derive its public
key with the SDK OpenSSL tool, and byte-compare it with the committed public
key before invoking `scripts/build-apk-repository`. Trap deletion of the
private-key file.

- [ ] **Step 5: Render enrollment, checksums, and release assets**

Render `install-apk-repository` with the final Pages URL. Generate sorted
checksums from the target directory:

```sh
(cd "$repo_dir" && sha256sum ./*.apk packages.adb | LC_ALL=C sort) > "$repo_dir/SHA256SUMS"
```

Use the SDK APK tool with the committed public key to verify the staged
`packages.adb`; perform a repository query against the staged `file://` URL
and assert it selects `xray-openwrt-integration`.

- [ ] **Step 6: Deploy Pages and attach release recovery assets**

Upload the full `_site` directory with `actions/upload-pages-artifact`, deploy
it with `actions/deploy-pages`, then attach the new APK, `SHA256SUMS`, public
key, installer, and content manifest to the matching GitHub Release. Set
`concurrency` so only one Pages release publishes at a time and do not cancel
an in-progress deployment.

- [ ] **Step 7: Run workflow and full host tests**

Run: `rtk sh tests/workflow_test.sh && rtk sh tests/run.sh`

Expected: workflow contracts PASS and all suites have zero failures.

- [ ] **Step 8: Commit the release workflow**

```sh
git add .github/workflows/release.yml tests/workflow_test.sh
git commit -m "ci: publish signed OpenWrt APK repository"
```

---

### Task 5: Repository Documentation and Acceptance

**Files:**
- Create: `docs/repository.md`
- Modify: `README.md`
- Modify: `docs/openwrt-acceptance.md`
- Modify: `tests/package_test.sh`

**Interfaces:**
- Consumes: published installer, public-key sidecar fingerprint, feed URL, and retained release assets.
- Produces: complete operator and acceptance procedures with no secret values.

- [ ] **Step 1: Add failing documentation contract tests**

In `tests/package_test.sh`, require `docs/repository.md` to contain the exact
feed URL, supported release/arch, fingerprint sidecar path, trusted install
commands, explicit downgrade, and unenrollment. Require README to link it and
reject the old primary instruction:

```text
apk add --allow-untrusted ./xray-openwrt-integration-*.apk
```

Require acceptance to cover `apk update`, trusted `apk add`, two-version
upgrade, unchanged hashes for both config files, wrong-key/index rejection,
and manual downgrade.

- [ ] **Step 2: Run package tests and confirm documentation is absent**

Run: `rtk sh tests/package_test.sh`

Expected: FAIL because `docs/repository.md` does not exist.

- [ ] **Step 3: Write the operator guide**

Document:

```sh
uclient-fetch -O /tmp/install-apk-repository \
  https://mrundead1996.github.io/xray-openwrt/install-apk-repository
less /tmp/install-apk-repository
sh /tmp/install-apk-repository
apk update
apk add xray-openwrt-integration
```

Also document `apk upgrade xray-openwrt-integration`, a retained-APK explicit
downgrade using the exact downloaded filename, recovery from GitHub Release
assets, signature-failure stop conditions, and explicit removal of the one
key file and exact feed line. State that the fingerprint must be checked
against `keys/xray-openwrt-repository.pem.sha256` from a reviewed revision or
Release asset before enrollment.

- [ ] **Step 4: Update README and acceptance checklist**

Replace temporary artifact delivery with the signed feed. Mark implementation
items already covered by host tests as complete, while leaving Actions and
router acceptance UNRUN until evidence exists. Extend the acceptance template
without inserting router identifiers, secrets, or signed artifact URLs.

- [ ] **Step 5: Run documentation and full tests**

Run: `rtk sh tests/package_test.sh && rtk sh tests/run.sh`

Expected: documentation contracts PASS and all suites have zero failures.

- [ ] **Step 6: Commit documentation**

```sh
git add docs/repository.md README.md docs/openwrt-acceptance.md tests/package_test.sh
git commit -m "docs: document signed APK repository delivery"
```

---

### Task 6: End-to-End Release and Router Acceptance

**Files:**
- Modify: `docs/openwrt-acceptance.md`

**Interfaces:**
- Consumes: a reviewed release tag, deployed Pages feed, two sequential package versions, and an isolated supported router.
- Produces: sanitized PASS/FAIL evidence in the existing acceptance record.

- [ ] **Step 1: Verify the repository locally with the pinned SDK**

Run the release workflow's staging commands against a temporary Pages tree,
then use the SDK APK tool to verify `packages.adb`, query the package, and
install into an isolated temporary root. Expected: signature verification and
package selection succeed without `--allow-untrusted`.

- [ ] **Step 2: Publish a protected test release**

Create a version tag matching `PKG_VERSION`, approve the protected
`github-pages` environment, and confirm the release job publishes exactly one
new immutable APK plus a signed index. Record only run number, artifact names,
and redacted hashes in acceptance evidence.

- [ ] **Step 3: Exercise clean trusted enrollment and installation**

On an isolated OpenWrt 25.12 router with arch `aarch64_cortex-a53`, run the
documented enrollment twice, then:

```sh
apk update
apk add xray-openwrt-integration
apk info -L xray-openwrt-integration
```

Expected: one feed line, one trusted key, successful install without
`--allow-untrusted`, required integration files present, and forbidden runtime
and user config absent.

- [ ] **Step 4: Exercise rejection and upgrade preservation**

Against a temporary local copy of the feed, alter one byte of `packages.adb`
and confirm `apk update` rejects it. Restore the valid feed, record hashes of
`/etc/config/xray` and `/etc/xray/config.json`, publish/install the next
version-release, run `apk upgrade xray-openwrt-integration`, and confirm both
hashes remain identical.

- [ ] **Step 5: Exercise retained-package downgrade**

Download the immediately previous retained APK from Pages and run the exact
downgrade command documented in `docs/repository.md`. Expected: APK reports
the previous version, both user configuration hashes remain unchanged, and
the service remains startable.

- [ ] **Step 6: Record sanitized acceptance evidence**

Mark only executed sections PASS, record no network addresses, credentials,
Xray configuration, private keys, or signed download URLs, and commit:

```sh
git add docs/openwrt-acceptance.md
git commit -m "test: record APK repository acceptance"
```

---

## Final Verification

- [ ] Run `rtk sh tests/run.sh`; expect every suite PASS and zero failures.
- [ ] Run `rtk git diff --check`; expect no output.
- [ ] Run `rtk git grep -n 'BEGIN.*PRIVATE KEY' -- . ':!docs/superpowers/**'`; expect no output.
- [ ] Confirm PR workflow permissions remain `contents: read` only.
- [ ] Confirm release workflow is tag-only and the signing secret is scoped to the protected publication environment.
- [ ] Confirm a trusted router install and upgrade work without `--allow-untrusted`.
- [ ] Confirm acceptance evidence remains sanitized.
