# Signed APK Repository Delivery Design

## Purpose

Publish `xray-openwrt-integration` as a persistent, signed third-party APK
repository for OpenWrt 25.12. Users connect the repository once, then install
and update the integration package with the standard `apk` workflow.

The Xray runtime remains outside this package and continues to be managed by
`update-xray-core`.

## Scope

This design covers:

- release-triggered package builds with the pinned OpenWrt SDK;
- creation and signing of the OpenWrt 25.12 `package.adb` repository index;
- publication of the repository through GitHub Pages;
- one-time trust and repository bootstrap on a router;
- package installation, upgrade, rollback availability, and CI verification;
- documentation of supported OpenWrt release and architecture.

It does not cover:

- inclusion of `/usr/bin/xray` in the APK;
- generation or distribution of `/etc/xray/config.json`;
- support for targets other than OpenWrt 25.12 on
  `aarch64_cortex-a53`;
- automatic firmware upgrades or unattended package upgrades;
- a general-purpose multi-package repository service.

## User Experience

Repository enrollment is a deliberate one-time operation. After enrollment,
normal package operations do not use `--allow-untrusted`:

```sh
apk update
apk add xray-openwrt-integration
apk upgrade xray-openwrt-integration
```

Enrollment installs the repository public key and adds the HTTPS repository
URL to APK configuration. The documentation publishes the key fingerprint via
a separate, stable page so an operator can verify it before trusting the key.

The bootstrap procedure must be inspectable and must fail closed. It must not
modify APK configuration if the public-key download, expected fingerprint, or
target compatibility check fails.

## Repository Layout

GitHub Pages serves a target-specific repository rooted at:

```text
https://mrundead1996.github.io/xray-openwrt/packages/25.12/aarch64_cortex-a53/
```

The published tree contains:

```text
packages/
└── 25.12/
    └── aarch64_cortex-a53/
        ├── package.adb
        ├── xray-openwrt-integration-<version>-r<release>.apk
        └── SHA256SUMS
```

The repository retains the current package and at least two prior released
package files. The signed index selects the highest APK version as the upgrade
candidate. Old files provide an operator-controlled downgrade path; automatic
downgrade is not supported.

Only immutable release outputs are published. A version-release pair must
never be replaced with different bytes.

## Build and Publication

Pull requests continue to use the existing build workflow as a verification
gate. Publishing uses a separate workflow triggered by a release tag matching
`v<PKG_VERSION>`, such as `v1.1.0`.

The release workflow:

1. Checks out the tagged revision.
2. Runs all host tests.
3. Verifies that the tag version equals `PKG_VERSION` in `Makefile`.
4. Downloads and verifies the pinned OpenWrt 25.12 SDK.
5. Builds exactly one APK for `aarch64_cortex-a53`.
6. Extracts and validates the APK payload with the SDK host APK tool.
7. Rejects `/usr/bin/xray` and `/etc/xray/config.json` in the payload.
8. Retrieves existing retained package files from the Pages deployment.
9. Generates `package.adb` using the APK tooling from the pinned SDK.
10. Signs the index with the repository private key.
11. Verifies the completed repository using the corresponding public key.
12. Produces `SHA256SUMS` for operator diagnostics.
13. Publishes the complete versioned directory atomically through GitHub
    Pages.
14. Attaches the APK, checksum file, public key, and content manifest to the
    matching GitHub Release for inspection and manual recovery.

Publishing permissions are available only to the release job. Pull-request
jobs, including jobs from forks, cannot access the signing key or deploy
Pages.

If retention introduces excessive repository growth, a later maintenance
change may cap it more aggressively. The first implementation stays with one
current and two previous package versions.

## Signing and Trust

A dedicated APK repository EC P-256 key pair is created for this project.

- The private key is stored as an environment-scoped GitHub Actions secret.
- The release environment requires explicit approval when repository settings
  support it.
- The public key is committed under `keys/` and published with each release.
- The public key fingerprint is documented in `docs/repository.md` and in the
  GitHub Release notes.
- The workflow derives the public key from the supplied private key and
  verifies that it matches the committed key before signing.

The private key is backed up outside GitHub by the maintainer. Losing it
requires key rotation and fresh enrollment; publishing a replacement key at
the same URL does not establish trust.

Key rotation is outside the first implementation. Until a separately reviewed
rotation design is implemented, rotating or losing the private key requires
operators to verify and enroll the replacement public key explicitly.

## Router Enrollment

The supported bootstrap path is an operator-run script stored in the
repository and copied or downloaded explicitly. It performs these checks
before making changes:

1. OpenWrt release belongs to the supported `25.12` series.
2. APK architecture is `aarch64_cortex-a53`.
3. HTTPS download of the public key succeeds.
4. The key fingerprint equals the fingerprint embedded in the reviewed
   bootstrap script.
5. The repository is reachable and its signed index verifies with that key.

Only after all checks pass does it install the key and add the repository URL.
Writes use temporary files and atomic replacement. Re-running enrollment is
idempotent: it neither duplicates repository lines nor rewrites an identical
key unnecessarily.

The script does not install the integration package implicitly. Enrollment
and installation remain separate actions so the operator can inspect
`apk update` output first.

The implementation must determine the authoritative OpenWrt 25.12 APK key
directory and repository configuration file from the pinned SDK/runtime,
rather than assuming Alpine paths.

## Package Upgrade Semantics

Every publication increments either `PKG_VERSION` or `PKG_RELEASE`:

- use `PKG_VERSION` for a new project release;
- increment `PKG_RELEASE` when package metadata or build packaging changes
  without a project-version change.

`/etc/config/xray` remains an APK conffile. `/etc/xray/config.json` remains
absent from the package. Upgrade acceptance must prove that both files retain
their contents.

Repository enrollment configuration and the repository public key are not
owned by `xray-openwrt-integration` in the initial implementation. Removing
the package therefore does not silently remove repository trust. Unenrollment
is an explicit documented operator procedure.

## Failure Handling

- A failed build, payload check, index generation, signing check, or repository
  verification prevents publication.
- Pages is deployed from a complete staged tree, avoiding a state where a new
  index references an unavailable APK.
- Existing published repository contents remain available when a release job
  fails.
- APK rejects an altered index or package through normal signature and index
  verification.
- Bootstrap failures leave the prior key and repository configuration intact.
- A broken integration release is corrected with a higher version-release;
  the published artifact is never overwritten.

## Verification

Automated tests cover:

- release tag and `PKG_VERSION` agreement;
- PR jobs having no publication path or signing credentials;
- repository creation from one and multiple APK versions;
- signed-index verification with the public key;
- rejection with the wrong key and after index or APK alteration;
- required and forbidden APK contents;
- Pages tree layout and retention of two prior releases;
- idempotent repository enrollment;
- bootstrap failure before mutation for wrong release, architecture,
  fingerprint, or signature;
- upgrade from the previous package version while preserving
  `/etc/config/xray` and `/etc/xray/config.json`.

Host mocks may verify control flow, but final acceptance requires an APK built
by the pinned SDK and a clean OpenWrt 25.12 router. The router acceptance
record must include enrollment, trusted installation without
`--allow-untrusted`, upgrade, configuration preservation, and an intentionally
failed signature verification.

## Documentation Changes

`docs/repository.md` becomes the operator guide and contains:

- supported target and architecture;
- public key fingerprint and independent verification instructions;
- enrollment and unenrollment procedures;
- `apk update`, installation, upgrade, and explicit downgrade commands;
- recovery through GitHub Release assets;
- key-rotation policy and warning signs for signature failures.

`README.md` links to that guide and replaces the temporary Actions-artifact
installation instructions with the signed repository workflow. The hardware
acceptance checklist gains repository trust and upgrade checks.

## Acceptance Criteria

Delivery is complete when:

- a tagged release publishes a signed repository to the documented HTTPS URL;
- a clean supported router can enroll the key and repository idempotently;
- `apk update` verifies the index without `--allow-untrusted`;
- `apk add xray-openwrt-integration` installs the expected APK;
- a later release is selected by `apk upgrade xray-openwrt-integration`;
- both user configuration files survive the upgrade unchanged;
- altered or incorrectly signed repository data is rejected;
- failed publication cannot replace the last working repository;
- the documented manual downgrade path works with a retained APK.
