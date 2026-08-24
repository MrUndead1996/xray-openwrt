# Xray OpenWrt Integration

Минимальная OpenWrt-обвязка для запуска актуального upstream Xray-core с TProxy, nftables, policy routing, procd jail и автоматическим обновлением Xray/geo assets.

Проект предназначен для случаев, когда пакет `xray-core` в OpenWrt заметно отстаёт от upstream, но при этом хочется сохранить нативную интеграцию с OpenWrt:

- `procd`;
- отдельный пользователь `xray`;
- jail/capabilities;
- nftables TProxy;
- policy routing;
- UCI;
- автоматическое обновление Xray напрямую из GitHub Releases;
- обновление `geosite.dat` и Re-filter assets;
- rollback при неудачном обновлении Xray;
- минимальное количество записей во flash.

Проект не является аналогом PassWall, PassWall2 или v2rayA и не пытается генерировать конфигурацию Xray через GUI. Конфигурация Xray остаётся полностью под контролем пользователя.

## Цели проекта

Основная идея — разделить Xray и OpenWrt integration layer.

```text
                    GitHub XTLS/Xray-core
                            │
                            │ updater
                            ▼
                     /usr/bin/xray
                            │
                    upstream binary
                            │
             ┌──────────────┴──────────────┐
             │                             │
        procd / jail                  Xray config
             │                     /etc/xray/config.jsonc
             │
             ▼
          Xray-core
             │
             ▼
       TProxy inbound
             │
             ▼
        nftables + PBR
             │
             ▼
           WAN
```

Сам бинарник Xray **не поставляется внутри APK**.

APK содержит только интеграционный слой OpenWrt.

Это позволяет обновлять:

- integration package — через `apk`;
- Xray-core — напрямую из официальных GitHub Releases;
- geo assets — отдельно по расписанию.

## Поддерживаемая среда

Текущая целевая конфигурация:

```text
OpenWrt: 25.12.x
Architecture: aarch64_cortex-a53
Target: mediatek/filogic
Firewall: firewall4 / nftables
Xray: upstream XTLS/Xray-core
Network mode: IPv4 TProxy
```

Проект изначально создавался для OpenWrt 25.12.2 на `mediatek/filogic`.

Другие платформы могут работать, но должны быть проверены отдельно.

## Возможности

### Xray runtime

- Xray запускается под отдельным пользователем `xray`;
- используется `procd`;
- используется jail;
- задаются необходимые Linux capabilities;
- поддерживается JSONC-конфигурация;
- Xray binary обновляется независимо от OpenWrt package repository.

### Transparent proxy

- TCP и UDP через TProxy;
- nftables;
- отдельный fwmark для TProxy;
- policy routing через отдельную routing table;
- bypass локальных адресов;
- bypass private networks;
- bypass собственных соединений Xray по GID;
- дополнительный bypass через outbound `SO_MARK`;
- исключения Docker, veth, WireGuard и PPP-интерфейсов;
- динамический список IP-адресов интерфейсов OpenWrt.

### Xray updater

Updater Xray:

1. скачивает только `.dgst` текущего upstream release;
2. извлекает SHA256;
3. сравнивает его с установленной версией;
4. не скачивает архив, если обновления нет;
5. при наличии новой версии скачивает ZIP;
6. проверяет SHA256;
7. извлекает новый бинарник во временную директорию;
8. проверяет бинарник;
9. проверяет текущий Xray config новым бинарником;
10. сохраняет текущую рабочую версию как `previous`;
11. атомарно устанавливает новую версию;
12. запускает Xray;
13. проверяет успешность запуска;
14. автоматически выполняет rollback при ошибке.

Хранятся две версии:

```text
/usr/bin/xray
/usr/bin/xray.previous
```

Также сохраняются SHA256:

```text
/etc/xray/.xray-current-sha256
/etc/xray/.xray-previous-sha256
```

### Geo assets updater

Раз в неделю проверяются:

```text
geosite.dat
refilter_ip.dat
refilter_site.dat
```

Файлы сначала скачиваются в `/tmp`.

Рабочий файл во flash заменяется только если новое содержимое отличается от текущего:

```text
download → /tmp
        ↓
       cmp
        ↓
changed? ── no ──> ничего не записывать
   │
  yes
   ↓
atomic replace
```

Это уменьшает количество лишних записей во flash.

После реального изменения assets Xray перезапускается.

Все действия логируются через системный `logger`.

## Структура проекта

Предполагаемая структура репозитория:

```text
.
├── Makefile
├── README.md
├── LICENSE
│
├── files
│   ├── etc
│   │   ├── config
│   │   │   └── xray
│   │   │
│   │   ├── init.d
│   │   │   ├── xray
│   │   │   └── xray-tproxy
│   │   │
│   │   └── xray
│   │       ├── config.example.jsonc
│   │       └── tproxy.nft
│   │
│   └── usr
│       └── bin
│           ├── update-xray-core
│           ├── rollback-xray-core
│           └── update-xray-assets
│
└── .github
    └── workflows
        └── build.yml
```

Рабочий пользовательский конфиг:

```text
/etc/xray/config.jsonc
```

не должен содержаться в публичном Git-репозитории.

В репозиторий помещается только:

```text
/etc/xray/config.example.jsonc
```

## TProxy architecture

Используются два отдельных mark.

### `0x40`

TProxy mark:

```text
0x40
```

Используется nftables для отправки пакетов в policy routing table.

Проверка выполняется с mask:

```text
0x40/0xc0
```

Policy routing:

```sh
ip rule add fwmark 0x40/0xc0 table 100
ip route add local default dev lo table 100
```

### `0x80`

Outbound bypass mark:

```text
0x80
```

Некоторые Xray outbounds устанавливают:

```jsonc
"streamSettings": {
  "sockopt": {
    "mark": 128
  }
}
```

В nftables такие пакеты исключаются из повторного TProxy:

```nft
meta mark & 0x80 == 0x80 return
```

### GID bypass

Xray работает под:

```text
uid=998(xray)
gid=998(xray)
```

Поэтому собственные соединения процесса дополнительно исключаются:

```nft
skgid 998 return
```

Это защищает от proxy loop независимо от destination address.

## Policy routing

Используется отдельная IPv4 routing table:

```text
table 100
```

Пример:

```sh
ip route replace local default dev lo table 100
ip rule add fwmark 0x40/0xc0 table 100
```

Проверка:

```sh
ip rule show
ip route show table 100
```

Ожидаемый результат:

```text
from all fwmark 0x40/0xc0 lookup 100
```

и:

```text
local default dev lo scope host
```

IPv6 TProxy в текущей конфигурации проекта не используется.

## nftables

Основной ruleset хранится в:

```text
/etc/xray/tproxy.nft
```

Он отвечает за:

- OUTPUT traffic;
- PREROUTING traffic;
- TCP/UDP detection;
- restoration `ct mark`;
- local-address bypass;
- private-network bypass;
- interface bypass;
- Xray GID bypass;
- outbound mark bypass;
- TProxy forwarding на:

```text
127.0.0.1:52345
```

Пример логики:

```text
packet
  │
  ├─ local/private? ───────────> return
  │
  ├─ Xray process? ────────────> return
  │
  ├─ mark 0x80? ───────────────> return
  │
  ├─ excluded interface? ──────> return
  │
  └─ internet traffic
          │
          ▼
      mark 0x40
          │
          ▼
     routing table 100
          │
          ▼
     TProxy :52345
```

## Xray configuration

Проект не генерирует Xray config автоматически.

Ожидается конфигурация вида:

```jsonc
{
  "inbounds": [
    {
      "tag": "all-in",
      "port": 52345,
      "protocol": "tunnel",
      "settings": {
        "allowedNetwork": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ]
}
```

Для TProxy + `routeOnly` может использоваться:

```jsonc
"routing": {
  "domainStrategy": "AsIs"
}
```

Полный конфиг следует хранить в:

```text
/etc/xray/config.jsonc
```

## JSONC

Xray запускается с:

```text
-format json
```

даже если файл имеет расширение:

```text
.jsonc
```

Например:

```sh
xray run \
  -config /etc/xray/config.jsonc \
  -format json
```

Перед обновлением или рестартом конфиг должен проверяться:

```sh
xray run \
  -test \
  -config /etc/xray/config.jsonc \
  -format json
```

## Jail

Xray запускается через OpenWrt `procd` jail.

Пример используемой схемы:

```sh
procd_add_jail xray procfs log
procd_add_jail_mount "$confdir"
procd_add_jail_mount "$datadir"
procd_add_jail_mount "/usr/share/v2ray/"
procd_add_jail_mount "/etc/ssl/certs/ca-certificates.crt"

procd_set_param user xray
procd_set_param capabilities /etc/capabilities/xray.json
```

Конкретный список mount/capabilities зависит от используемой конфигурации Xray.

## Upstream Xray updater

Updater не использует GitHub API.

Используются stable `latest/download` URL.

Для ARM64:

```text
https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip
```

Сначала скачивается:

```text
Xray-linux-arm64-v8a.zip.dgst
```

Из него извлекается SHA256.

Если SHA256 совпадает с:

```text
/etc/xray/.xray-current-sha256
```

обновление прекращается без скачивания ZIP.

### Update flow

```text
download .dgst
      │
      ▼
extract SHA256
      │
      ▼
same as current?
   │        │
  yes       no
   │        │
 exit       ▼
         download ZIP
              │
              ▼
         verify SHA256
              │
              ▼
         extract xray
              │
              ▼
        xray --version
              │
              ▼
        validate config
              │
              ▼
       backup current
              │
              ▼
        install new
              │
              ▼
          start Xray
              │
        ┌─────┴─────┐
       OK           FAIL
        │             │
        ▼             ▼
 save state       rollback
```

## Rollback

Перед установкой нового бинарника текущая рабочая версия сохраняется как:

```text
/usr/bin/xray.previous
```

При неудачном старте:

```text
new Xray
   │
   ├─ failed
   │
   ▼
stop
   │
   ▼
restore previous
   │
   ▼
start previous
```

Ручной rollback:

```sh
rollback-xray-core
```

Предыдущая рабочая версия сохраняется даже после успешного обновления, чтобы можно было откатиться при обнаружении регрессии позже.

## Asset updates

Используются:

### V2Fly domain list

```text
https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
```

Устанавливается как:

```text
/usr/share/xray/geosite.dat
```

### Re-filter IP

```text
https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geoip.dat
```

Устанавливается как:

```text
/usr/share/xray/refilter_ip.dat
```

### Re-filter domains

```text
https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat
```

Устанавливается как:

```text
/usr/share/xray/refilter_site.dat
```

## Cron

Assets проверяются раз в неделю.

Пример:

```cron
17 4 * * 0 /usr/bin/update-xray-assets
```

Xray-core также можно проверять раз в неделю, например:

```cron
47 4 * * 0 /usr/bin/update-xray-core
```

Проверка обновления Xray почти не создаёт трафика, если новой версии нет, поскольку сначала скачивается только `.dgst`.

## Flash wear

Проект старается минимизировать лишние записи во flash.

### Xray

Если SHA256 upstream release не изменился:

```text
ZIP не скачивается
/usr/bin/xray не перезаписывается
state не изменяется
```

### Geo assets

Assets сначала скачиваются в:

```text
/tmp
```

После скачивания выполняется:

```sh
cmp
```

Рабочий файл заменяется только при реальном изменении содержимого.

### Logging

Для служебных сообщений используется:

```sh
logger
```

Пример:

```sh
logger -t xray-update "Xray is already up to date"
```

Посмотреть сообщения:

```sh
logread -e xray
```

При стандартной конфигурации OpenWrt системный лог хранится в RAM.

## APK package

Пакет не должен устанавливать `/usr/bin/xray`.

Предполагаемый пакет:

```text
xray-openwrt-integration
```

Он устанавливает только OpenWrt integration layer.

Пример содержимого:

```text
/etc/init.d/xray
/etc/init.d/xray-tproxy
/etc/config/xray
/etc/xray/tproxy.nft
/usr/bin/update-xray-core
/usr/bin/rollback-xray-core
/usr/bin/update-xray-assets
```

## Configuration persistence

Следующие файлы должны считаться пользовательскими:

```text
/etc/config/xray
/etc/xray/config.jsonc
```

Они не должны безусловно перезаписываться при обновлении APK.

Реальный Xray config с:

- UUID;
- REALITY keys;
- server addresses;
- custom routing;

не должен храниться в публичном Git.

## Build

Проект предполагается собирать OpenWrt SDK для соответствующего target.

Для текущей платформы:

```text
OpenWrt 25.12.x
mediatek/filogic
aarch64_cortex-a53
```

Результатом сборки должен быть:

```text
xray-openwrt-integration-<version>.apk
```

Установка локального пакета:

```sh
apk add --allow-untrusted ./xray-openwrt-integration-*.apk
```

## Проверка после установки

### Xray

```sh
xray --version
```

### Xray config

```sh
xray run \
  -test \
  -config /etc/xray/config.jsonc \
  -format json
```

### Service

```sh
/etc/init.d/xray restart
pgrep -af xray
logread -e xray
```

### Policy routing

```sh
ip rule show
ip route show table 100
```

### nftables

```sh
nft list table inet xray
```

### Xray user

```sh
id xray
```

Ожидается отдельный пользователь и группа Xray.

## Troubleshooting

### TProxy loop

Проверить:

```sh
id xray
nft list table inet xray
```

В ruleset должно присутствовать исключение GID Xray.

Также можно использовать outbound mark:

```jsonc
"sockopt": {
  "mark": 128
}
```

и соответствующий nftables bypass.

### Xray не стартует после update

Updater должен автоматически выполнить rollback.

Проверить:

```sh
logread -e xray-update
```

Ручной откат:

```sh
rollback-xray-core
```

### Policy routing отсутствует

Проверить:

```sh
ip rule show
ip route show table 100
```

При необходимости:

```sh
/etc/init.d/xray-tproxy restart
```

### Assets не обновляются

Запустить вручную:

```sh
/usr/bin/update-xray-assets
```

И посмотреть:

```sh
logread -e xray-assets
```

### Проверка cron

```sh
cat /etc/crontabs/root
ps w | grep '[c]rond'
```

## Security notes

`.dgst` используется для проверки целостности скачанного Xray archive.

Следует учитывать, что checksum-файл не является отдельной криптографической подписью release. Если источник одновременно способен подменить архив и соответствующий `.dgst`, SHA256-проверка этого не обнаружит.

Все файлы должны скачиваться только по HTTPS с официальных upstream URL.

Секреты Xray не должны попадать в Git.

## Design principles

Проект следует нескольким принципам:

**Минимум магии.** Все nftables и policy-routing rules должны быть доступны пользователю в читаемом виде.

**Xray config принадлежит пользователю.** Integration layer не генерирует сложную конфигурацию автоматически.

**Upstream first.** Xray-core обновляется напрямую из XTLS/Xray-core, независимо от скорости обновления OpenWrt package feed.

**Safe updates.** Любое обновление runtime должно иметь проверку и автоматический rollback.

**Flash-friendly.** Не перезаписывать persistent storage без необходимости.

**OpenWrt-native.** Использовать `procd`, UCI, nftables, `logger`, отдельного пользователя и стандартные механизмы OpenWrt.

## Status

Проект находится на стадии выделения рабочей конфигурации OpenWrt/Xray в воспроизводимый APK package.

Текущая рабочая схема уже использует:

- Xray upstream binary;
- OpenWrt 25.12;
- procd jail;
- Xray user/GID;
- IPv4 TProxy;
- nftables;
- policy routing;
- VLESS + REALITY;
- custom geosite/IP lists;
- периодическое обновление assets.

Следующие задачи:

- [ ] оформить OpenWrt package `Makefile`;
- [ ] вынести TProxy lifecycle в отдельный `xray-tproxy` service;
- [ ] реализовать `update-xray-core`;
- [ ] реализовать автоматический rollback;
- [ ] реализовать `rollback-xray-core`;
- [ ] добавить безопасный asset updater;
- [ ] добавить cron installation;
- [ ] добавить GitHub Actions для сборки `.apk`;
- [ ] протестировать clean install на OpenWrt 25.12;
- [ ] протестировать package upgrade без перезаписи пользовательского config;
- [ ] протестировать rollback после намеренно сломанного Xray update.

## License

Выберите подходящую лицензию для integration layer, например MIT.

Xray-core и используемые geo assets распространяются независимо и под собственными лицензиями.
