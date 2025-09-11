#!/usr/bin/env bash
# cerebro_internet.sh: internet performance optimization
# Requires: curl, reflector, ethtool, irqbalance

set -euo pipefail

log="/var/log/cerebro_internet.log"
exec > >(tee -a "$log") 2>&1

echo "[*] Starting Cerebro Internet Optimization..."

# --- 0. Ensure required packages ---
echo "[*] Installing required packages..."
for pkg in reflector ethtool irqbalance curl; do
  if ! pacman -Qi "$pkg" &>/dev/null; then
    pacman -S --noconfirm "$pkg"
  fi
done


# Enable and start irqbalance
systemctl enable --now irqbalance
echo "[*] irqbalance enabled and running."

# --- 1. Detect country/continent from IP ---
country=$(curl -s https://ipinfo.io/country || echo "")
continent=$(curl -s https://ipapi.co/continent_code || echo "")
echo "[*] Detected country: $country, continent: $continent"

# --- 2. Choose reflector region ---
if [[ "$country" == "UA" ]]; then
    region_opt="--continent Europe"
elif [[ "$continent" == "EU" ]]; then
    region_opt="--continent Europe"
elif [[ "$continent" == "NA" ]]; then
    region_opt="--continent North America"
elif [[ "$continent" == "SA" ]]; then
    region_opt="--continent South America"
elif [[ "$continent" == "AS" ]]; then
    region_opt="--continent Asia"
elif [[ "$continent" == "AF" ]]; then
    region_opt="--continent Africa"
elif [[ "$continent" == "OC" ]]; then
    region_opt="--continent Oceania"
else
    region_opt=""
fi
echo "[*] Using reflector option: $region_opt"

# --- 3. Update mirrorlist ---
echo "[*] Updating Arch mirrorlist..."
reflector $region_opt --protocol https --age 12 --fastest 20 --sort rate --save /etc/pacman.d/mirrorlist

# --- 4. Set DNS: Cloudflare primary, Google + Quad9 fallback ---
echo "[*] Setting DNS..."
dns_servers=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" "9.9.9.9")
if command -v resolvectl >/dev/null 2>&1; then
  for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
    resolvectl dns "$iface" "${dns_servers[@]}"
  done
  resolvectl flush-caches
else
  cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) || true
  printf "%s\n" "${dns_servers[@]/#/nameserver }" > /etc/resolv.conf
fi

# --- 5. Optimize interfaces ---
echo "[*] Optimizing network interfaces..."
for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
  # Ethernet interfaces only
  if [[ "$iface" =~ ^(en|eth|p[0-9]+p) ]]; then
    speed=$(ethtool "$iface" 2>/dev/null | awk '/Speed:/{print $2}' | tr -d '[:alpha:]')
    if [[ -n "$speed" && "$speed" -ge 1000 ]]; then
      # MTU and transmit queue
      ip link set dev "$iface" mtu 9000
      ip link set dev "$iface" txqueuelen 10000
      echo "  -> $iface MTU=9000, txqueuelen=10000"

      # Disable offloading to reduce CPU overhead
      ethtool -K "$iface" tso off gso off gro off
      echo "  -> $iface offloading: TSO/GSO/GRO disabled"

      # Disable IPv6
      sysctl -w "net.ipv6.conf.$iface.disable_ipv6=1" || true
      echo "  -> $iface IPv6 disabled"
    fi
  fi
done

# --- 6. Sysctl network optimizations ---
echo "[*] Applying sysctl optimizations..."
sysctl_conf=/etc/sysctl.d/99-cerebro.conf
cat > "$sysctl_conf" <<EOF
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 30000 65535
EOF
sysctl --system

echo "[✓] Cerebro Internet Optimization complete. Log: $log"
