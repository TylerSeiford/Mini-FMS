#!/bin/bash
# configure-robot-radio.sh
# Run from your laptop - will SSH into a stock/factory-default OpenWrt radio and configure it
#
# Prerequisite: the radio must already have a root password set (via LuCI at
# its default address on first boot) since stock OpenWrt blocks passwordless
# remote SSH. The ssh command below will prompt for it interactively.

set -e

echo "=== OM5P-AC Robot Radio Configurator ==="
echo ""
echo "IMPORTANT: On a stock/factory-default OpenWrt radio, connect your laptop"
echo "to the LAN port (farthest from the barrel jack) - not the port used for"
echo "unlock-and-flash.ps1."
echo ""

# Try to auto-detect the radio's stock IP as the laptop's current default
# gateway (the radio hands this out via DHCP as itself, e.g. 192.168.1.1).
detect_gateway() {
    local gw=""
    if command -v ip >/dev/null 2>&1; then
        gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    fi
    if [ -z "$gw" ] && command -v ipconfig >/dev/null 2>&1; then
        gw=$(ipconfig 2>/dev/null | grep -A1 "Default Gateway" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    fi
    if [ -z "$gw" ] && command -v netstat >/dev/null 2>&1; then
        gw=$(netstat -rn 2>/dev/null | awk '/^(default|0\.0\.0\.0)/ {print $2; exit}')
    fi
    echo "$gw"
}
DETECTED_IP=$(detect_gateway)
DETECTED_IP=${DETECTED_IP:-192.168.1.1}

# Map an IANA zone name to OpenWrt's zonename + POSIX TZ string. Table is
# scoped to the North American zones an FRC team is likely to be in.
declare -A TZ_TABLE=(
    [America/New_York]="EST5EDT,M3.2.0,M11.1.0"
    [America/Chicago]="CST6CDT,M3.2.0,M11.1.0"
    [America/Denver]="MST7MDT,M3.2.0,M11.1.0"
    [America/Phoenix]="MST7"
    [America/Los_Angeles]="PST8PDT,M3.2.0,M11.1.0"
    [America/Anchorage]="AKST9AKDT,M3.2.0,M11.1.0"
    [Pacific/Honolulu]="HST10"
    [America/Halifax]="AST4ADT,M3.2.0,M11.1.0"
    [America/Toronto]="EST5EDT,M3.2.0,M11.1.0"
    [America/Vancouver]="PST8PDT,M3.2.0,M11.1.0"
    [America/Edmonton]="MST7MDT,M3.2.0,M11.1.0"
    [America/Winnipeg]="CST6CDT,M3.2.0,M11.1.0"
    [UTC]="UTC0"
)

# Map a Windows timezone ID (from tzutil) to an IANA zone name in the table above.
windows_tz_to_iana() {
    case "$1" in
        "Eastern Standard Time") echo "America/New_York" ;;
        "Central Standard Time") echo "America/Chicago" ;;
        "Mountain Standard Time") echo "America/Denver" ;;
        "US Mountain Standard Time") echo "America/Phoenix" ;;
        "Pacific Standard Time") echo "America/Los_Angeles" ;;
        "Alaskan Standard Time") echo "America/Anchorage" ;;
        "Hawaiian Standard Time") echo "Pacific/Honolulu" ;;
        "Atlantic Standard Time") echo "America/Halifax" ;;
        "UTC") echo "UTC" ;;
        *) echo "" ;;
    esac
}

detect_timezone() {
    local tz=""
    if command -v tzutil >/dev/null 2>&1; then
        tz=$(windows_tz_to_iana "$(tzutil /g 2>/dev/null)")
    fi
    if [ -z "$tz" ] && [ -L /etc/localtime ]; then
        tz=$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')
    fi
    echo "$tz"
}
DETECTED_TZ=$(detect_timezone)
DETECTED_TZ=${DETECTED_TZ:-America/Chicago}

# Get timezone
while true; do
    read -p "Timezone (IANA name) [${DETECTED_TZ}]: " TZNAME
    TZNAME=${TZNAME:-$DETECTED_TZ}
    if [ -n "${TZ_TABLE[$TZNAME]+set}" ]; then
        break
    fi
    echo "Unknown zone. Valid options: ${!TZ_TABLE[@]}"
done
POSIX_TZ="${TZ_TABLE[$TZNAME]}"

# Get current radio IP
while true; do
    read -p "Current radio IP address [${DETECTED_IP}]: " CURRENT_IP
    CURRENT_IP=${CURRENT_IP:-$DETECTED_IP}
    if [[ $CURRENT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    echo "Invalid IP address, try again."
done

# Get team number
while true; do
    read -p "Team number (1-25699): " TEAM
    if [[ $TEAM =~ ^[0-9]{1,5}$ ]] && [ "$TEAM" -ge 1 ] && [ "$TEAM" -le 25699 ]; then
        break
    fi
    echo "Invalid team number, must be 1-25699."
done

# Calculate IP octets from team number matching Freesy subnet_filter.py logic
if [ ${#TEAM} -le 3 ]; then
    SECOND=0
    THIRD=$((10#$TEAM))
elif [ ${#TEAM} -eq 4 ]; then
    SECOND=$((10#${TEAM:0:2}))
    THIRD=$((10#${TEAM:2:2}))
elif [ ${#TEAM} -eq 5 ]; then
    SECOND=$((10#${TEAM:0:3}))
    THIRD=$((10#${TEAM:3:2}))
fi

NEW_IP="10.${SECOND}.${THIRD}.1"
GATEWAY="10.${SECOND}.${THIRD}.4"

echo "  Radio will be configured at: $NEW_IP"
echo "  Gateway will be: $GATEWAY"
echo ""

# Get AP SSID first - default to TEAM-suffix style
DEFAULT_AP_SSID="${TEAM}-Robot"
while true; do
    read -p "Local AP SSID [${DEFAULT_AP_SSID}]: " AP_SSID
    AP_SSID=${AP_SSID:-$DEFAULT_AP_SSID}
    if [ ${#AP_SSID} -ge 1 ] && [ ${#AP_SSID} -le 32 ]; then
        break
    fi
    echo "SSID must be 1-32 characters."
done

# Get AP key - defaults to AP SSID
while true; do
    read -p "Local AP WPA key [${AP_SSID}]: " AP_KEY
    AP_KEY=${AP_KEY:-$AP_SSID}
    if [ ${#AP_KEY} -ge 8 ] && [ ${#AP_KEY} -le 63 ]; then
        break
    fi
    echo "Key must be 8-63 characters."
done

# Get uplink SSID
while true; do
    read -p "Field uplink SSID [2846-Field]: " UPLINK_SSID
    UPLINK_SSID=${UPLINK_SSID:-2846-Field}
    if [ ${#UPLINK_SSID} -ge 1 ] && [ ${#UPLINK_SSID} -le 32 ]; then
        break
    fi
    echo "SSID must be 1-32 characters."
done

# Get uplink PPSK - defaults to AP SSID
while true; do
    read -p "Field uplink PPSK [${AP_SSID}]: " UPLINK_KEY
    UPLINK_KEY=${UPLINK_KEY:-$AP_SSID}
    if [ ${#UPLINK_KEY} -ge 8 ] && [ ${#UPLINK_KEY} -le 63 ]; then
        break
    fi
    echo "Key must be 8-63 characters."
done

# Get hostname - defaults to OM5P-AC_[AP SSID]
DEFAULT_HOSTNAME="OM5P-AC_${AP_SSID}"
while true; do
    read -p "Hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
    if [[ $HOSTNAME =~ ^[a-zA-Z0-9_-]+$ ]]; then
        break
    fi
    echo "Invalid hostname, use only letters, numbers, hyphens and underscores."
done

# Confirm
echo ""
echo "=== Configuration Summary ==="
echo "  Current IP:    $CURRENT_IP"
echo "  New IP:        $NEW_IP"
echo "  Gateway:       $GATEWAY"
echo "  Hostname:      $HOSTNAME"
echo "  Timezone:      $TZNAME"
echo "  AP SSID:       $AP_SSID"
echo "  AP Key:        $AP_KEY"
echo "  Uplink SSID:   $UPLINK_SSID"
echo "  Uplink Key:    $UPLINK_KEY"
echo ""

read -p "Apply this configuration? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Connecting to radio at $CURRENT_IP..."

# SSH in and apply config. Radios get re-imaged/re-provisioned often and reuse
# the same IPs, so their host key changes constantly - don't check or persist it.
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$CURRENT_IP << EOF
echo "Connected. Applying configuration..."

# Hostname
uci set system.@system[0].hostname='$HOSTNAME'

# Timezone
uci set system.@system[0].zonename='$TZNAME'
uci set system.@system[0].timezone='$POSIX_TZ'

# LAN IP
uci set network.lan.ipaddr='$NEW_IP'

# DHCP options - gateway and DNS
uci del dhcp.lan.dhcp_option 2>/dev/null || true
uci add_list dhcp.lan.dhcp_option='3,$GATEWAY'
uci add_list dhcp.lan.dhcp_option='6,$GATEWAY'

# Radios: 5GHz (radio0) is the field uplink, 2.4GHz (radio1) is the local AP
uci set wireless.radio0.channel='36'
uci set wireless.radio0.htmode='VHT80'
uci set wireless.radio0.disabled='0'
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.htmode='HT20'
uci set wireless.radio1.disabled='0'

# Stock default AP on the 5GHz radio isn't needed - that radio is the uplink
uci -q delete wireless.default_radio0

# 2.4GHz local AP (repurpose stock default AP interface)
uci set wireless.default_radio1.mode='ap'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.ssid='$AP_SSID'
uci set wireless.default_radio1.encryption='sae-mixed'
uci set wireless.default_radio1.key='$AP_KEY'

# 5GHz field uplink (STA) - create new interface
uci set wireless.wifinet0='wifi-iface'
uci set wireless.wifinet0.device='radio0'
uci set wireless.wifinet0.mode='sta'
uci set wireless.wifinet0.network='lan'
uci set wireless.wifinet0.ssid='$UPLINK_SSID'
uci set wireless.wifinet0.encryption='psk2'
uci set wireless.wifinet0.key='$UPLINK_KEY'
uci set wireless.wifinet0.wds='1'

# Firewall: this radio is a bridge, not a router - drop the stock wan zone/
# forwarding and make the lan zone fully permissive
while uci -q delete firewall.@forwarding[0]; do :; done
i=0
while ZNAME=\$(uci -q get firewall.@zone[\$i].name); do
    if [ "\$ZNAME" != "lan" ]; then
        uci delete firewall.@zone[\$i]
    else
        i=\$((i+1))
    fi
done
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'

# Commit everything
uci commit

echo "Configuration applied. Restarting services..."
/etc/init.d/system reload
service network restart &
service firewall restart &
wifi reload &

echo "Done! Radio will now be at $NEW_IP"
EOF

echo ""
echo "=== Complete ==="
echo "Radio is reconfiguring. Reconnect to it at $NEW_IP"
echo "Note: if connected via the radio's LAN port, you will lose connectivity momentarily."
