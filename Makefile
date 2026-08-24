include $(TOPDIR)/rules.mk

PKG_NAME:=xray-openwrt-integration
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Xray OpenWrt Integration Contributors

include $(INCLUDE_DIR)/package.mk

define Package/xray-openwrt-integration
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Xray OpenWrt integration layer
  DEPENDS:=+ca-bundle +wget-ssl +unzip +ip-full +kmod-nft-tproxy +kmod-nft-socket +kmod-nft-fib +kmod-nf-conntrack +firewall4 +procd-ujail
  USERID:=xray:xray
endef

define Package/xray-openwrt-integration/description
 OpenWrt service, TProxy, and update integration for an externally installed
 Xray runtime.
endef

define Package/xray-openwrt-integration/conffiles
/etc/config/xray
endef

define Build/Compile
endef

define Package/xray-openwrt-integration/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/xray $(1)/etc/config/xray
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/xray $(1)/etc/init.d/xray
	$(INSTALL_DIR) $(1)/etc/capabilities
	$(INSTALL_DATA) ./files/etc/capabilities/xray.json $(1)/etc/capabilities/xray.json
	$(INSTALL_DIR) $(1)/etc/xray
	$(INSTALL_DATA) ./files/etc/xray/config.example.json $(1)/etc/xray/config.example.json
	$(INSTALL_DATA) ./files/etc/xray/tproxy.nft $(1)/etc/xray/tproxy.nft
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-xray $(1)/etc/hotplug.d/iface/99-xray
	$(INSTALL_DIR) $(1)/etc/hotplug.d/firewall
	$(INSTALL_BIN) ./files/etc/hotplug.d/firewall/99-xray $(1)/etc/hotplug.d/firewall/99-xray
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-xray-cron $(1)/etc/uci-defaults/99-xray-cron
	$(INSTALL_DIR) $(1)/usr/libexec/xray
	$(INSTALL_BIN) ./files/usr/libexec/xray/common $(1)/usr/libexec/xray/common
	$(INSTALL_BIN) ./files/usr/libexec/xray/tproxy $(1)/usr/libexec/xray/tproxy
	$(INSTALL_DIR) $(1)/usr/share/xray
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/update-xray-assets $(1)/usr/bin/update-xray-assets
	$(INSTALL_BIN) ./files/usr/bin/update-xray-core $(1)/usr/bin/update-xray-core
	$(INSTALL_BIN) ./files/usr/bin/rollback-xray-core $(1)/usr/bin/rollback-xray-core
endef

$(eval $(call BuildPackage,xray-openwrt-integration))
