# Signed APK repository

The project publishes `xray-openwrt-integration` through a signed APK feed for
OpenWrt 25.12 on `aarch64_cortex-a53`.

Repository index:

```text
https://mrundead1996.github.io/xray-openwrt/packages/25.12/aarch64_cortex-a53/packages.adb
```

## Trust bootstrap

Enrollment adds one public key and one line to OpenWrt's custom APK feeds. It
does not install the package. Before enrollment, compare the published key
fingerprint with `keys/xray-openwrt-repository.pem.sha256` from a reviewed Git
revision or a GitHub Release asset. Do not trust a fingerprint obtained only
from the same Pages download you are trying to verify.

Download and inspect the enrollment script:

```sh
uclient-fetch -O /tmp/xray-openwrt-repository.pem \
  https://mrundead1996.github.io/xray-openwrt/xray-openwrt-repository.pem
sha256sum /tmp/xray-openwrt-repository.pem
# Expected:
# d0bed17e0d38645ddd08010d29cd302ad4a6da40d39fe30f65c2a5114d24506f

uclient-fetch -O /tmp/install-apk-repository \
  https://mrundead1996.github.io/xray-openwrt/install-apk-repository
less /tmp/install-apk-repository
sh /tmp/install-apk-repository
```

The script checks OpenWrt release `25.12.x`, APK architecture
`aarch64_cortex-a53`, the exact public-key SHA-256, and the signature of the
downloaded `packages.adb` before changing `/etc/apk`. It is idempotent.

After enrollment, refresh indexes and install without `--allow-untrusted`:

```sh
apk update
apk add xray-openwrt-integration
```

If any fingerprint or signature check fails, stop. Do not bypass it with
`--allow-untrusted`.

## Upgrade

Refresh the signed index and upgrade the package:

```sh
apk update
apk upgrade xray-openwrt-integration
```

`/etc/config/xray` is an APK conffile. `/etc/xray/config.json` is not shipped
by the package. Both files must remain unchanged across upgrades.

## Downgrade

The feed retains the two previous APK releases. Download the required APK and
verify its SHA-256 against the adjacent `SHA256SUMS`, then explicitly allow the
downgrade:

```sh
apk add --allow-downgrade ./xray-openwrt-integration-<version>-r<release>.apk
```

Installing a local file can record an exact package constraint. Restore normal
feed tracking afterward:

```sh
apk add xray-openwrt-integration
```

GitHub Release assets provide the same APK, public key, fingerprint,
`SHA256SUMS`, installer, and content manifest for manual recovery.

## Unenroll

Removing the integration package does not silently remove repository trust.
To unenroll explicitly, remove the project key and only the exact feed line:

```sh
rm -f /etc/apk/keys/xray-openwrt-repository.pem
feed='https://mrundead1996.github.io/xray-openwrt/packages/25.12/aarch64_cortex-a53/packages.adb'
awk -v feed="$feed" '$0 != feed { print }' \
  /etc/apk/repositories.d/customfeeds.list \
  > /tmp/xray-customfeeds.list
cat /tmp/xray-customfeeds.list > /etc/apk/repositories.d/customfeeds.list
rm -f /tmp/xray-customfeeds.list
apk update
```

Review the generated file before replacing `customfeeds.list` when operating
on a customized router.

## Signing-key policy

The repository index is signed by a dedicated EC P-256 key. The public key is
committed as `keys/xray-openwrt-repository.pem`; the matching private key is
stored only in the protected GitHub `github-pages` environment as
`XRAY_APK_SIGNING_KEY` and in maintainer-controlled backup storage.

Key rotation is not automatic. A changed fingerprint requires a separately
reviewed rotation procedure and explicit operator enrollment.
