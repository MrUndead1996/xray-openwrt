# OpenWrt acceptance checklist

**Date:** 2026-08-24

**Scope:** `xray-openwrt-integration` on OpenWrt 25.12.0, target
`mediatek/filogic` (`aarch64_cortex-a53`)

**Overall status:** **UNRUN** — no target router or GitHub Actions run is
available in this workspace.

This is an executable, manual acceptance record. Complete it only with the
APK built from the reviewed revision. The repository host tests are a
precondition, not proof of package, GitHub Actions, or router behaviour.

## Evidence hygiene

Do not put these values in this file, an issue, CI logs, or commits:

- router hostname, public or private IP address, MAC address, serial number,
  SSH username, or local paths;
- Xray UUIDs, private keys, Reality settings, server names, subscription URLs,
  configuration contents, or downloaded asset contents;
- GitHub tokens, workflow URLs containing credentials, or artifact download
  URLs containing signed query parameters.

Use the following sanitized fields instead. Record command exit codes, package
versions, redacted hashes, and pass/fail outcomes only.

| Field | Value |
| --- | --- |
| Revision under test | `<commit-sha>` |
| Tester | `<initials-or-team>` |
| Test date (UTC) | `<YYYY-MM-DD>` |
| Router profile | `OpenWrt 25.12.0 / mediatek-filogic / aarch64_cortex-a53` |
| APK filename | `xray-openwrt-integration-<version>-r<release>.apk` |
| APK SHA-256 | `<first-12-hex>…<last-12-hex>` |
| GitHub Actions run | `<run-number-or-not-run>` |
| Result | `PASS | FAIL | UNRUN` |

## 1. Host-test precondition

- [ ] From the repository root, run:

  ```sh
  sh tests/run.sh
  ```

- [ ] Record a passing suite count and zero failures. Do not treat this as a
  router or GitHub Actions result.

**Evidence:** `host-tests: <PASS/FAIL>; suites: <count>; failures: <count>`

## 2. GitHub Actions build and artifact

**Status: UNRUN — GitHub Actions is unavailable.**

When Actions access is available:

- [ ] Trigger or select the `Build OpenWrt APK` workflow for the revision under
  test.
- [ ] Confirm the SDK download is verified by SHA-256 and package compilation
  succeeds.
- [ ] Download the `xray-openwrt-integration` artifact.
- [ ] Confirm the artifact contains exactly one
  `xray-openwrt-integration-*.apk` and `content-manifest.txt`.
- [ ] Inspect `content-manifest.txt`; it must include the service, UCI config,
  example config, TProxy rules, update/rollback commands, and libexec helpers.
- [ ] Confirm the manifest does **not** contain `usr/bin/xray` or
  `etc/xray/config.json`.
- [ ] Record only the workflow run number, artifact name, APK filename, and a
  redacted APK hash.

**Evidence:** `actions: <PASS/FAIL/UNRUN>; run: <number>; artifact: <name>;
manifest: <PASS/FAIL>; apk-hash: <redacted>`

## 3. Router preparation

**Status: UNRUN — no router is available.**

On an isolated, supported router:

- [ ] Verify platform and release:

  ```sh
  ubus call system board
  uname -m
  ```

- [ ] Copy the reviewed APK to a temporary router directory. Do not record the
  router address or transfer command with credentials.
- [ ] Preserve a sanitized before-state:

  ```sh
  apk info xray-openwrt-integration
  test -e /etc/xray/config.json && echo config-present || echo config-absent
  ```

**Evidence:** `router-preparation: <PASS/FAIL/UNRUN>; platform: <expected/not-expected>`

## 3a. Enroll the trusted repository

**Status: UNRUN — no router is available.**

- [ ] Compare the public-key fingerprint with
  `keys/xray-openwrt-repository.pem.sha256` from the reviewed revision.
- [ ] Download, inspect, and run the enrollment script from
  `docs/repository.md`.
- [ ] Run enrollment twice and confirm there is exactly one project key and
  one exact repository line.
- [ ] Refresh the signed index and install without `--allow-untrusted`:

  ```sh
  apk update
  apk add xray-openwrt-integration
  ```

- [ ] Against an isolated temporary feed copy, perform a wrong-key test and
  alter one byte of `packages.adb`; confirm both are rejected. Restore the
  production feed before continuing.

**Evidence:** `trusted repository: <PASS/FAIL/UNRUN>; fingerprint: <PASS/FAIL>;
idempotent: <PASS/FAIL>; wrong-key: <REJECTED/ACCEPTED>; altered-index:
<REJECTED/ACCEPTED>`

## 4. Clean package installation

**Status: UNRUN — no router is available.**

- [ ] Install from the enrolled signed repository:

  ```sh
  apk add xray-openwrt-integration
  ```

- [ ] Verify installed ownership and payload without exposing configuration
  contents:

  ```sh
  apk info -L xray-openwrt-integration
  id xray
  test -f /etc/config/xray
  test -f /etc/xray/config.example.json
  test -f /etc/xray/tproxy.nft
  test -x /etc/init.d/xray
  test -x /usr/bin/update-xray-core
  test -x /usr/bin/rollback-xray-core
  test -x /usr/bin/update-xray-assets
  test -x /usr/libexec/xray/common
  test -x /usr/libexec/xray/tproxy
  test ! -e /usr/bin/xray
  test ! -e /etc/xray/config.json
  ```

- [ ] Confirm the package does not install an Xray runtime or a user
  configuration.

**Evidence:** `clean-install: <PASS/FAIL/UNRUN>; payload: <PASS/FAIL>; user: <PASS/FAIL>`

## 5. Configuration and service lifecycle

**Status: UNRUN — no router is available.**

- [ ] Install the Xray runtime through the approved operator procedure.
- [ ] Create `/etc/xray/config.json` locally from the example and add only
  tested, non-secret configuration. Do not copy that file into evidence.
- [ ] Validate it and start the service:

  ```sh
  xray run -test -config /etc/xray/config.json -format json
  /etc/init.d/xray enable
  /etc/init.d/xray restart
  pgrep -af xray
  logread -e xray
  ```

- [ ] Reload a valid configuration and verify the service remains healthy:

  ```sh
  /etc/init.d/xray reload
  pgrep -af xray
  ```

- [ ] Stop and start the service once; verify TProxy rules are removed and
  restored with the lifecycle:

  ```sh
  /etc/init.d/xray stop
  nft list table inet xray
  /etc/init.d/xray start
  ```

**Evidence:** `service: <PASS/FAIL/UNRUN>; config-test: <exit-code>; lifecycle: <PASS/FAIL>; log-summary: <redacted>`

## 6. TProxy, policy routing, and hotplug behaviour

**Status: UNRUN — no router is available.**

- [ ] With the service running, verify the TProxy table, rules, and route:

  ```sh
  nft list table inet xray
  ip rule show
  ip route show table 100
  ```

- [ ] Confirm the Xray GID bypass is present in the nftables ruleset.
- [ ] Restart the firewall and verify rules are restored:

  ```sh
  /etc/init.d/firewall restart
  nft list table inet xray
  ip rule show
  ip route show table 100
  ```

- [ ] Renew or reconnect the WAN interface by the normal maintenance method,
  then repeat the three inspection commands above.
- [ ] Confirm only expected traffic is intercepted using a non-sensitive test
  destination; do not record destination names or addresses.

**Evidence:** `tproxy: <PASS/FAIL/UNRUN>; firewall-recovery: <PASS/FAIL>; wan-recovery: <PASS/FAIL>; traffic-check: <PASS/FAIL>`

## 7. Asset updater and cron

**Status: UNRUN — no router is available.**

- [ ] Run the updater once:

  ```sh
  /usr/bin/update-xray-assets
  logread -e xray-assets
  ```

- [ ] Run it again with unchanged sources; verify it does not unnecessarily
  replace assets or restart the runtime.
- [ ] Verify the cron entry and daemon:

  ```sh
  cat /etc/crontabs/root
  ps w | grep '[c]rond'
  ```

- [ ] Confirm updater failures leave the prior assets intact and release their
  lock; perform this only with an approved, reversible failure injection.

**Evidence:** `assets: <PASS/FAIL/UNRUN>; no-change-run: <PASS/FAIL>; cron: <PASS/FAIL>; failure-safety: <PASS/FAIL>`

## 8. Core update and rollback

**Status: UNRUN — no router is available.**

- [ ] Run the approved core update procedure:

  ```sh
  /usr/bin/update-xray-core
  xray --version
  /etc/init.d/xray restart
  pgrep -af xray
  logread -e xray-update
  ```

- [ ] Confirm a valid update atomically installs the runtime and the restarted
  service passes its configuration check.
- [ ] Using an approved, reversible broken update input, confirm the updater
  rejects it, retains or restores the last known-good runtime, and leaves the
  service recoverable.
- [ ] Exercise the manual rollback command and confirm the previously recorded
  version is restored:

  ```sh
  rollback-xray-core
  xray --version
  /etc/init.d/xray restart
  ```

**Evidence:** `core-update: <PASS/FAIL/UNRUN>; rollback-on-failure: <PASS/FAIL>; manual-rollback: <PASS/FAIL>; versions: <redacted>`

## 9. Package upgrade preserves user configuration

**Status: UNRUN — no router is available.**

- [ ] Save a local hash of the user configuration without publishing its
  contents:

  ```sh
  sha256sum /etc/config/xray /etc/xray/config.json
  ```

- [ ] Upgrade with a newer reviewed APK:

  ```sh
  apk upgrade ./xray-openwrt-integration-*.apk
  ```

- [ ] Recalculate both hashes and verify they are unchanged.
- [ ] Verify the service starts, the TProxy table and policy routing are
  present, and the update/rollback commands still execute.

**Evidence:** `package-upgrade: <PASS/FAIL/UNRUN>; uci-hash: <unchanged/changed>; config-hash: <unchanged/changed>; service-after-upgrade: <PASS/FAIL>`

## 10. Retained-package manual downgrade

**Status: UNRUN — no router is available.**

- [ ] Download the immediately previous retained APK and verify it against
  the published `SHA256SUMS`.
- [ ] Follow the manual downgrade procedure in `docs/repository.md`.
- [ ] Confirm the previous package version is installed and the hashes of
  `/etc/config/xray` and `/etc/xray/config.json` remain unchanged.
- [ ] Restore feed tracking with `apk add xray-openwrt-integration`.

**Evidence:** `manual downgrade: <PASS/FAIL/UNRUN>; checksum: <PASS/FAIL>;
uci-hash: <unchanged/changed>; config-hash: <unchanged/changed>`

## Acceptance decision

- [ ] **PASS** — every applicable section has passed and sanitized evidence is
  recorded.
- [ ] **FAIL** — record the failing section and a sanitized symptom, then stop
  promotion.
- [x] **UNRUN** — current state: host tests may be run locally, but GitHub
  Actions and router acceptance have not been run.

**Decision evidence:** `decision: UNRUN; reason: no router or GitHub Actions access`
