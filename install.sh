#!/bin/sh

#set -x

# ==================== ПЕРВАЯ ЧАСТЬ: УСТАНОВКА AWG 2.0 ====================

PKG_MANAGER=""
PKG_EXT=""

detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    else
        printf "\033[32;1mNo supported package manager found (apk/opkg).\033[0m\n"
        exit 1
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
        opkg update
    fi
}

is_pkg_installed() {
    pkg_name="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -q "^${pkg_name} "
    fi
}

install_local_pkg() {
    pkg_file="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

get_pkgarch() {
    PKGARCH_UBUS=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch' 2>/dev/null)
    if [ -n "$PKGARCH_UBUS" ]; then
        echo "$PKGARCH_UBUS"
        return
    fi

    if command -v opkg >/dev/null 2>&1; then
        opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'
        return
    fi

    if [ -f /etc/openwrt_release ]; then
        PKGARCH_RELEASE=$(grep "^DISTRIB_ARCH='" /etc/openwrt_release | cut -d"'" -f2)
        if [ -n "$PKGARCH_RELEASE" ]; then
            echo "$PKGARCH_RELEASE"
            return
        fi
    fi

    if command -v apk >/dev/null 2>&1; then
        apk --print-arch
        return
    fi

    uname -m
}

download_package() {
    pkg_base_name="$1"
    pkg_postfix_base="$2"
    awg_dir="$3"
    base_url="$4"

    preferred_file="${pkg_base_name}${pkg_postfix_base}.${PKG_EXT}"
    preferred_url="${base_url}${preferred_file}"
    if wget -q -O "$awg_dir/$preferred_file" "$preferred_url" && [ -s "$awg_dir/$preferred_file" ]; then
        echo "$preferred_file"
        return 0
    fi
    rm -f "$awg_dir/$preferred_file"

    if [ "$PKG_EXT" = "apk" ]; then
        fallback_ext="ipk"
    else
        fallback_ext="apk"
    fi

    fallback_file="${pkg_base_name}${pkg_postfix_base}.${fallback_ext}"
    fallback_url="${base_url}${fallback_file}"
    if wget -q -O "$awg_dir/$fallback_file" "$fallback_url" && [ -s "$awg_dir/$fallback_file" ]; then
        echo "$fallback_file"
        return 0
    fi
    rm -f "$awg_dir/$fallback_file"

    return 1
}

#Репозиторий OpenWRT должен быть доступен для установки зависимостей пакета kmod-amneziawg
check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    if [ "$PKG_MANAGER" = "apk" ]; then
        pkg_update >/dev/null 2>&1 || \
            { printf "\033[32;1mapk failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n"; exit 1; }
    else
        pkg_update | grep -q "Failed to download" && \
            printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
    fi
}

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(get_pkgarch)

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX_BASE="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    # Определяем версию AWG протокола (2.0 для OpenWRT >= 23.05.6 и >= 24.10.3)
    AWG_VERSION="1.0"
    MAJOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 1)
    MINOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 2)
    PATCH_VERSION=$(echo "$VERSION" | cut -d '.' -f 3)

    if [ "$MAJOR_VERSION" -gt 24 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -gt 10 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -eq 10 -a "$PATCH_VERSION" -ge 3 ] || \
       [ "$MAJOR_VERSION" -eq 23 -a "$MINOR_VERSION" -eq 5 -a "$PATCH_VERSION" -ge 6 ]; then
        AWG_VERSION="2.0"
        LUCI_PACKAGE_NAME="luci-proto-amneziawg"
    else
        LUCI_PACKAGE_NAME="luci-app-amneziawg"
    fi

    printf "\033[32;1mDetected AWG version: $AWG_VERSION\033[0m\n"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    if is_pkg_installed "kmod-amneziawg"; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME=$(download_package "kmod-amneziawg" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error downloading kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg installed successfully"
        else
            echo "Error installing kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    if is_pkg_installed "amneziawg-tools"; then
        echo "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME=$(download_package "amneziawg-tools" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error downloading amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools installed successfully"
        else
            echo "Error installing amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi
    fi

    # Проверяем оба возможных названия пакета
    if is_pkg_installed "luci-proto-amneziawg" || is_pkg_installed "luci-app-amneziawg"; then
        echo "$LUCI_PACKAGE_NAME already installed"
    else
        LUCI_AMNEZIAWG_FILENAME=$(download_package "$LUCI_PACKAGE_NAME" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "$LUCI_PACKAGE_NAME file downloaded successfully"
        else
            echo "Error downloading $LUCI_PACKAGE_NAME. Please, install $LUCI_PACKAGE_NAME manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$LUCI_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "$LUCI_PACKAGE_NAME installed successfully"
        else
            echo "Error installing $LUCI_PACKAGE_NAME. Please, install $LUCI_PACKAGE_NAME manually and run the script again"
            exit 1
        fi
    fi

    # Устанавливаем русскую локализацию (всегда)
    if [ "$AWG_VERSION" = "2.0" ]; then
        printf "\033[32;1mInstalling Russian language pack...\033[0m\n"
        if is_pkg_installed "luci-i18n-amneziawg-ru"; then
            echo "luci-i18n-amneziawg-ru already installed"
        else
            LUCI_I18N_AMNEZIAWG_RU_FILENAME=$(download_package "luci-i18n-amneziawg-ru" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
            if [ $? -eq 0 ]; then
                echo "luci-i18n-amneziawg-ru file downloaded successfully"
                install_local_pkg "$AWG_DIR/$LUCI_I18N_AMNEZIAWG_RU_FILENAME"
                if [ $? -eq 0 ]; then
                    echo "luci-i18n-amneziawg-ru installed successfully"
                else
                    echo "Warning: Error installing luci-i18n-amneziawg-ru (non-critical)"
                fi
            else
                echo "Warning: Russian localization not available for this version/platform (non-critical)"
            fi
        fi
    fi

    rm -rf "$AWG_DIR"
}

configure_amneziawg_interface() {
    INTERFACE_NAME="awg1"
    CONFIG_NAME="amneziawg_awg1"
    PROTO="amneziawg"
    ZONE_NAME="awg1"

    printf "\033[32;1mConfiguring AmneziaWG interface...\033[0m\n"

    read -r -p "Enter the private key (from [Interface]):"$'\n' AWG_PRIVATE_KEY_INT

    while true; do
        read -r -p "Enter internal IP address with subnet, example 192.168.100.5/24 (from [Interface]):"$'\n' AWG_IP
        if echo "$AWG_IP" | egrep -oq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "This IP is not valid. Please repeat"
        fi
    done

    read -r -p "Enter the public key (from [Peer]):"$'\n' AWG_PUBLIC_KEY_INT
    read -r -p "If use PresharedKey, Enter this (from [Peer]). If your don't use leave blank:"$'\n' AWG_PRESHARED_KEY_INT
    read -r -p "Enter Endpoint host without port (Domain or IP) (from [Peer]):"$'\n' AWG_ENDPOINT_INT

    read -r -p "Enter Endpoint host port (from [Peer]) [51820]:"$'\n' AWG_ENDPOINT_PORT_INT
    AWG_ENDPOINT_PORT_INT=${AWG_ENDPOINT_PORT_INT:-51820}
    if [ "$AWG_ENDPOINT_PORT_INT" = '51820' ]; then
        echo $AWG_ENDPOINT_PORT_INT
    fi

    read -r -p "Enter Jc value (from [Interface]):"$'\n' AWG_JC
    read -r -p "Enter Jmin value (from [Interface]):"$'\n' AWG_JMIN
    read -r -p "Enter Jmax value (from [Interface]):"$'\n' AWG_JMAX
    read -r -p "Enter S1 value (from [Interface]):"$'\n' AWG_S1
    read -r -p "Enter S2 value (from [Interface]):"$'\n' AWG_S2
    read -r -p "Enter H1 value (from [Interface]):"$'\n' AWG_H1
    read -r -p "Enter H2 value (from [Interface]):"$'\n' AWG_H2
    read -r -p "Enter H3 value (from [Interface]):"$'\n' AWG_H3
    read -r -p "Enter H4 value (from [Interface]):"$'\n' AWG_H4

    # AWG 2.0 новые параметры
    if [ "$AWG_VERSION" = "2.0" ]; then
        read -r -p "Enter S3 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_S3
        read -r -p "Enter S4 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_S4
        read -r -p "Enter I1 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I1
        read -r -p "Enter I2 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I2
        read -r -p "Enter I3 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I3
        read -r -p "Enter I4 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I4
        read -r -p "Enter I5 value (from [Interface]) [optional, leave blank to skip]:"$'\n' AWG_I5
    fi

    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    uci set network.${INTERFACE_NAME}.private_key=$AWG_PRIVATE_KEY_INT
    uci set network.${INTERFACE_NAME}.listen_port='51821'
    uci set network.${INTERFACE_NAME}.addresses=$AWG_IP

    uci set network.${INTERFACE_NAME}.awg_jc=$AWG_JC
    uci set network.${INTERFACE_NAME}.awg_jmin=$AWG_JMIN
    uci set network.${INTERFACE_NAME}.awg_jmax=$AWG_JMAX
    uci set network.${INTERFACE_NAME}.awg_s1=$AWG_S1
    uci set network.${INTERFACE_NAME}.awg_s2=$AWG_S2
    uci set network.${INTERFACE_NAME}.awg_h1=$AWG_H1
    uci set network.${INTERFACE_NAME}.awg_h2=$AWG_H2
    uci set network.${INTERFACE_NAME}.awg_h3=$AWG_H3
    uci set network.${INTERFACE_NAME}.awg_h4=$AWG_H4

    # Устанавливаем новые параметры для AWG 2.0 (только если они заданы)
    if [ "$AWG_VERSION" = "2.0" ]; then
        [ -n "$AWG_S3" ] && uci set network.${INTERFACE_NAME}.awg_s3=$AWG_S3
        [ -n "$AWG_S4" ] && uci set network.${INTERFACE_NAME}.awg_s4=$AWG_S4
        [ -n "$AWG_I1" ] && uci set network.${INTERFACE_NAME}.awg_i1=$AWG_I1
        [ -n "$AWG_I2" ] && uci set network.${INTERFACE_NAME}.awg_i2=$AWG_I2
        [ -n "$AWG_I3" ] && uci set network.${INTERFACE_NAME}.awg_i3=$AWG_I3
        [ -n "$AWG_I4" ] && uci set network.${INTERFACE_NAME}.awg_i4=$AWG_I4
        [ -n "$AWG_I5" ] && uci set network.${INTERFACE_NAME}.awg_i5=$AWG_I5
    fi

    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi

    uci set network.@${CONFIG_NAME}[0]=$CONFIG_NAME
    uci set network.@${CONFIG_NAME}[0].name="${INTERFACE_NAME}_client"
    uci set network.@${CONFIG_NAME}[0].public_key=$AWG_PUBLIC_KEY_INT
    uci set network.@${CONFIG_NAME}[0].preshared_key=$AWG_PRESHARED_KEY_INT
    uci set network.@${CONFIG_NAME}[0].route_allowed_ips='0'
    uci set network.@${CONFIG_NAME}[0].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[0].endpoint_host=$AWG_ENDPOINT_INT
    uci set network.@${CONFIG_NAME}[0].allowed_ips='0.0.0.0/0'
    uci add_list network.@${CONFIG_NAME}[0].allowed_ips='::/0'
    uci set network.@${CONFIG_NAME}[0].endpoint_port=$AWG_ENDPOINT_PORT_INT
    uci commit network

    if ! uci show firewall | grep -q "@zone.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mZone Create\033[0m\n"
        uci add firewall zone
        uci set firewall.@zone[-1].name=$ZONE_NAME
        uci set firewall.@zone[-1].network=$INTERFACE_NAME
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi

    if ! uci show firewall | grep -q "@forwarding.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="${ZONE_NAME}-lan"
        uci set firewall.@forwarding[-1].dest=${ZONE_NAME}
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi

    service network restart
}

# ==================== ВТОРАЯ ЧАСТЬ: НАСТРОЙКА МАРШРУТИЗАЦИИ ПО ДОМЕНАМ ====================

# Функция создания маршрута для awg1
route_vpn() {
    cat << EOF > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh

ip route add table vpn default dev awg1
EOF

    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

add_zone_vpn() {
    # Удаляем старые зоны если есть
    zone_awg_id=$(uci show firewall | grep -E '@zone.*awg1' | awk -F '[][{}]' '{print $2}' | head -n 1)
    if [ "$zone_awg_id" == 0 ] || [ "$zone_awg_id" == 1 ]; then
        printf "\033[32;1mawg1 zone has an identifier of 0 or 1. That's not ok. Fix your firewall. lan and wan zones should have identifiers 0 and 1. \033[0m\n"
        exit 1
    fi
    if [ ! -z "$zone_awg_id" ]; then
        while uci -q delete firewall.@zone[$zone_awg_id]; do :; done
    fi

    # Создаем зону для awg1
    if uci show firewall | grep -q "@zone.*name='awg'"; then
        printf "\033[32;1mZone already exist\033[0m\n"
    else
        printf "\033[32;1mCreate zone for awg1\033[0m\n"
        uci add firewall zone
        uci set firewall.@zone[-1].name='awg'
        uci set firewall.@zone[-1].network='awg1'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi
    
    # Настройка forwarding
    if uci show firewall | grep -q "@forwarding.*name='awg-lan'"; then
        printf "\033[32;1mForwarding already configured\033[0m\n"
    else
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        # Удаляем старый forwarding если есть
        forward_id=$(uci show firewall | grep -E "@forwarding.*dest='awg'" | awk -F '[][{}]' '{print $2}' | head -n 1)
        if [ ! -z "$forward_id" ]; then
            while uci -q delete firewall.@forwarding[$forward_id]; do :; done
        fi

        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name='awg-lan'
        uci set firewall.@forwarding[-1].dest='awg'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
}

add_set() {
    if uci show firewall | grep -q "@ipset.*name='vpn_domains'"; then
        printf "\033[32;1mSet already exist\033[0m\n"
    else
        printf "\033[32;1mCreate set\033[0m\n"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit
    fi
    if uci show firewall | grep -q "@rule.*name='mark_domains'"; then
        printf "\033[32;1mRule for set already exist\033[0m\n"
    else
        printf "\033[32;1mCreate rule set\033[0m\n"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit
    fi
}

dnsmasqfull() {
    if opkg list-installed | grep -q dnsmasq-full; then
        printf "\033[32;1mdnsmasq-full already installed\033[0m\n"
    else
        printf "\033[32;1mInstalled dnsmasq-full\033[0m\n"
        cd /tmp/ && opkg download dnsmasq-full
        opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/

        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
    fi
}

dnsmasqconfdir() {
    if [ $VERSION_ID -ge 24 ]; then
        if uci get dhcp.@dnsmasq[0].confdir | grep -q /tmp/dnsmasq.d; then
            printf "\033[32;1mconfdir already set\033[0m\n"
        else
            printf "\033[32;1mSetting confdir\033[0m\n"
            uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
            uci commit dhcp
        fi
    fi
}

add_dns_resolver() {
    echo "Configure DNSCrypt2 or Stubby? It does matter if your ISP is spoofing DNS requests"
    DISK=$(df -m / | awk 'NR==2{ print $2 }')
    if [[ "$DISK" -lt 32 ]]; then 
        printf "\033[31;1mYour router a disk have less than 32MB. It is not recommended to install DNSCrypt, it takes 10MB\033[0m\n"
    fi
    echo "Select:"
    echo "1) No [Default]"
    echo "2) DNSCrypt2 (10.7M)"
    echo "3) Stubby (36K)"

    while true; do
    read -r -p '' DNS_RESOLVER
        case $DNS_RESOLVER in 

        1) 
            echo "Skiped"
            break
            ;;

        2)
            DNS_RESOLVER=DNSCRYPT
            break
            ;;

        3) 
            DNS_RESOLVER=STUBBY
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$DNS_RESOLVER" == 'DNSCRYPT' ]; then
        if opkg list-installed | grep -q dnscrypt-proxy2; then
            printf "\033[32;1mDNSCrypt2 already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled dnscrypt-proxy2\033[0m\n"
            opkg install dnscrypt-proxy2
            if grep -q "# server_names" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml; then
                sed -i "s/^# server_names =.*/server_names = [\'google\', \'cloudflare\', \'scaleway-fr\', \'yandex\']/g" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
            fi

            printf "\033[32;1mDNSCrypt restart\033[0m\n"
            service dnscrypt-proxy restart
            printf "\033[32;1mDNSCrypt needs to load the relays list. Please wait\033[0m\n"
            sleep 30

            if [ -f /etc/dnscrypt-proxy2/relays.md ]; then
                uci set dhcp.@dnsmasq[0].noresolv="1"
                uci -q delete dhcp.@dnsmasq[0].server
                uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
                uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
                uci commit dhcp
                
                printf "\033[32;1mDnsmasq restart\033[0m\n"

                /etc/init.d/dnsmasq restart
            else
                printf "\033[31;1mDNSCrypt not download list on /etc/dnscrypt-proxy2. Repeat install DNSCrypt by script.\033[0m\n"
            fi
    fi

    fi

    if [ "$DNS_RESOLVER" == 'STUBBY' ]; then
        printf "\033[32;1mConfigure Stubby\033[0m\n"

        if opkg list-installed | grep -q stubby; then
            printf "\033[32;1mStubby already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled stubby\033[0m\n"
            opkg install stubby

            printf "\033[32;1mConfigure Dnsmasq for Stubby\033[0m\n"
            uci set dhcp.@dnsmasq[0].noresolv="1"
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
            uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
            uci commit dhcp

            printf "\033[32;1mDnsmasq restart\033[0m\n"

            /etc/init.d/dnsmasq restart
        fi
    fi
}

add_packages() {
    for package in curl nano; do
        if opkg list-installed | grep -q "^$package "; then
            printf "\033[32;1m$package already installed\033[0m\n"
        else
            printf "\033[32;1mInstalling $package...\033[0m\n"
            opkg install "$package"
            
            if "$package" --version >/dev/null 2>&1; then
                printf "\033[32;1m$package was successfully installed and available\033[0m\n"
            else
                printf "\033[31;1mError: failed to install $package\033[0m\n"
                exit 1
            fi
        fi
    done
}

add_getdomains() {
    echo "Choose you country"
    echo "Select:"
    echo "1) Russia inside. You are inside Russia"
    echo "2) Russia outside. You are outside of Russia, but you need access to Russian resources"
    echo "3) Ukraine. uablacklist.net list"
    echo "4) Skip script creation"

    while true; do
    read -r -p '' COUNTRY
        case $COUNTRY in 

        1) 
            COUNTRY=russia_inside
            break
            ;;

        2)
            COUNTRY=russia_outside
            break
            ;;

        3) 
            COUNTRY=ukraine
            break
            ;;

        4) 
            echo "Skiped"
            COUNTRY=0
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$COUNTRY" == 'russia_inside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" == 'russia_outside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" == 'ukraine' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst
    fi

    if [ "$COUNTRY" != '0' ]; then
        printf "\033[32;1mCreate script /etc/init.d/getdomains\033[0m\n"

cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99

start () {
    $EOF_DOMAINS
EOF
cat << 'EOF' >> /etc/init.d/getdomains
    count=0
    while true; do
        if curl -m 3 github.com; then
            curl -f $DOMAINS --output /tmp/dnsmasq.d/domains.lst
            break
        else
            echo "GitHub is not available. Check the internet availability [$count]"
            count=$((count+1))
        fi
    done

    if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart
    fi
}
EOF

        chmod +x /etc/init.d/getdomains
        /etc/init.d/getdomains enable

        if crontab -l | grep -q /etc/init.d/getdomains; then
            printf "\033[32;1mCrontab already configured\033[0m\n"

        else
            crontab -l | { cat; echo "0 */8 * * * /etc/init.d/getdomains start"; } | crontab -
            printf "\033[32;1mIgnore this error. This is normal for a new installation\033[0m\n"
            /etc/init.d/cron restart
        fi

        printf "\033[32;1mStart script\033[0m\n"

        /etc/init.d/getdomains start
    fi
}

fix_awg_routing() {
    printf "\033[32;1mDisabling 'Route Allowed IPs' for awg1 peer...\033[0m\n"
    
    # Ищем секцию peer для awg1
    PEER_SECTION=$(uci show network | grep -E "network.@amneziawg_awg1\[[0-9]+\].name='awg1_client'" | awk -F'[=.]' '{print $2}')
    
    if [ ! -z "$PEER_SECTION" ]; then
        # Устанавливаем route_allowed_ips в 0
        uci set network.$PEER_SECTION.route_allowed_ips='0'
        uci commit network
        printf "\033[32;1mRoute Allowed IPs disabled for $PEER_SECTION\033[0m\n"
    else
        # Если секция не найдена по имени, пробуем найти по интерфейсу
        PEER_SECTION=$(uci show network | grep -E "network.@amneziawg_awg1\[[0-9]+\]" | head -n 1 | awk -F'[=.]' '{print $2}')
        if [ ! -z "$PEER_SECTION" ]; then
            uci set network.$PEER_SECTION.route_allowed_ips='0'
            uci commit network
            printf "\033[32;1mRoute Allowed IPs disabled for $PEER_SECTION\033[0m\n"
        else
            printf "\033[31;1mWarning: Could not find awg1 peer section. Skipping...\033[0m\n"
        fi
    fi
    
    printf "\033[32;1mRestarting network interfaces...\033[0m\n"
    
    # Перезапускаем awg1 интерфейс
    ifdown awg1 2>/dev/null
    sleep 2
    ifup awg1 2>/dev/null
    sleep 2
    
    # Перезапускаем wan интерфейс (обычно это wan или wan6)
    ifdown wan 2>/dev/null
    sleep 2
    ifup wan 2>/dev/null
    sleep 2
    
    printf "\033[32;1mInterfaces restarted successfully\033[0m\n"
}

# ==================== ОСНОВНОЙ БЛОК ВЫПОЛНЕНИЯ ====================

# System Details
MODEL=$(cat /tmp/sysinfo/model)
source /etc/os-release
printf "\033[34;1mModel: $MODEL\033[0m\n"
printf "\033[34;1mVersion: $OPENWRT_RELEASE\033[0m\n"

VERSION_ID=$(echo $VERSION | awk -F. '{print $1}')

if [ "$VERSION_ID" -ne 23 ] && [ "$VERSION_ID" -ne 24 ]; then
    printf "\033[31;1mScript only support OpenWrt 23.05 and 24.10\033[0m\n"
    echo "For OpenWrt 21.02 and 22.03 you can:"
    echo "1) Use ansible https://github.com/itdoginfo/domain-routing-openwrt"
    echo "2) Configure manually. Old manual: https://itdog.info/tochechnaya-marshrutizaciya-na-routere-s-openwrt-wireguard-i-dnscrypt/"
    exit 1
fi

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

# --- ПЕРВАЯ ЧАСТЬ: Установка AWG 2.0 ---
detect_package_manager
check_repo
install_awg_packages

# Настраиваем интерфейс AWG (всегда)
printf "\033[32;1mConfiguring AmneziaWG interface...\033[0m\n"
configure_amneziawg_interface

# --- ВТОРАЯ ЧАСТЬ: Настройка маршрутизации по доменам ---
add_packages

printf "\033[32;1mUsing Amnezia WireGuard interface awg1\033[0m\n"
route_vpn

add_mark
add_zone_vpn
add_set
dnsmasqfull
dnsmasqconfdir
add_dns_resolver
add_getdomains

# Фикс для Route Allowed IPs
fix_awg_routing

printf "\033[32;1mRestart network\033[0m\n"
/etc/init.d/network restart

printf "\033[32;1mDone\033[0m\n"
