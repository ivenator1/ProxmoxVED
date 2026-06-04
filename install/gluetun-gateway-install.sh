#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: ivenator1
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/qdm12/gluetun

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  wireguard-tools \
  iptables \
  dnsmasq
msg_ok "Installed Dependencies"

msg_info "Configuring iptables"
$STD update-alternatives --set iptables /usr/sbin/iptables-legacy
$STD update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
msg_ok "Configured iptables"

setup_go

fetch_and_deploy_gh_release "gluetun" "qdm12/gluetun" "tarball"

msg_info "Building Gluetun"
cd /opt/gluetun
$STD go mod download
CGO_ENABLED=0 $STD go build -trimpath -ldflags="-s -w" -o /usr/local/bin/gluetun ./cmd/gluetun/
msg_ok "Built Gluetun"

# Gluetun expects an in-container layout: a writable state dir at /gluetun and an
# alpine-release marker. Mirror the upstream image behaviour on bare metal.
mkdir -p /opt/gluetun-data/auth
touch /etc/alpine-release
ln -sf /opt/gluetun-data /gluetun

# Ask for the VXLAN client-side network. Defaults keep non-interactive installs
# working; everything can be changed later in /etc/gluetun/gluetun.env.
CLIENT_SUBNET=$(prompt_input "VXLAN client subnet (CIDR)" "10.10.10.0/24")
GATEWAY_IP=$(prompt_input "This gateway's IP on the VXLAN" "10.10.10.1")
VXLAN_IFACE=$(prompt_input "VXLAN interface name" "eth1")
VXLAN_PREFIX="${CLIENT_SUBNET##*/}"

msg_info "Enabling IP Forwarding"
cat <<EOF >/etc/sysctl.d/99-gluetun-gateway.conf
net.ipv4.ip_forward=1
EOF
$STD sysctl -p /etc/sysctl.d/99-gluetun-gateway.conf
msg_ok "Enabled IP Forwarding"

msg_info "Configuring Gluetun Gateway"
mkdir -p /etc/gluetun
cat <<EOF >/etc/gluetun/gluetun.env
# ============================================================================
#  Gluetun Gateway - configuration
# ============================================================================
#  This LXC is a VPN gateway/router for other LXCs on a shared VXLAN.
#  All client internet traffic is routed out through the ProtonVPN WireGuard
#  tunnel. If the tunnel drops, client internet is blocked (kill switch);
#  client LAN access is unaffected.
#
#  After editing this file:
#      systemctl restart gluetun-gateway-net && systemctl restart gluetun
#
#  Handy symlinks in this user's home directory:
#      ~/config.env      -> this file (/etc/gluetun/gluetun.env)
#      ~/forwarded_port  -> /gluetun/forwarded_port  (NAT-PMP port, set when up)
#      ~/public_ip       -> /gluetun/ip              (current VPN public IP)
#
# ----------------------------------------------------------------------------
#  1) THIS GATEWAY'S VXLAN INTERFACE (net1)
# ----------------------------------------------------------------------------
#  The installer only ever creates ONE NIC (eth0 = your normal internet LAN).
#  Add the VXLAN-facing NIC from the Proxmox HOST, with NO ip (no gateway):
#
#      pct set <ctid> -net1 name=eth1,bridge=<vxlan-vnet>
#
#  This gateway assigns GATEWAY_IP to that interface itself, so it works even
#  before the VXLAN vnet is wired. The container keeps its default route on
#  eth0 (needed to reach ProtonVPN); eth1 only receives an address.
#
# ----------------------------------------------------------------------------
#  2) CONFIGURING A CLIENT LXC (two interfaces)
# ----------------------------------------------------------------------------
#  A client routes ALL internet through this gateway, but keeps direct access
#  to chosen LAN subnets. Give the client TWO NICs:
#
#  a) VXLAN NIC -> default route (0.0.0.0/0) via this gateway.
#     Set the gateway ONLY on this NIC. From the Proxmox host:
#
#       pct set <ctid> -net0 name=eth0,bridge=<vxlan-vnet>,ip=10.10.10.50/24,gw=10.10.10.1
#
#     (Use an address inside CLIENT_SUBNET and gw = GATEWAY_IP.)
#
#  b) LAN NIC -> NO default gateway; only specified subnets reachable.
#     Add it WITHOUT a gw= so only its connected subnet is routed:
#
#       pct set <ctid> -net1 name=eth1,bridge=vmbr0,ip=192.168.1.50/24
#
#     For extra LAN subnets, add explicit static routes inside the client in
#     /etc/network/interfaces, e.g.:
#
#       up   ip route add 10.0.0.0/8 via 192.168.1.1 dev eth1
#       down ip route del 10.0.0.0/8 via 192.168.1.1 dev eth1
#
#  Equivalent raw /etc/network/interfaces on the client:
#
#       auto eth0
#       iface eth0 inet static
#           address 10.10.10.50/24
#           gateway 10.10.10.1
#           dns-nameservers 10.10.10.1
#
#       auto eth1
#       iface eth1 inet static
#           address 192.168.1.50/24
#           # NOTE: no 'gateway' line here
#           up ip route add 10.0.0.0/8 via 192.168.1.1 dev eth1
#
#  IMPORTANT on the client:
#    - Point DNS ONLY at the gateway (GATEWAY_IP) so DNS is tunnelled.
#    - Use static (not DHCP) on the LAN NIC, or it may pull in a default route
#      and DNS servers. If DHCP is required, strip the default route
#      (post-up: ip route del default dev eth1) and disable IPv6 RA on it
#      (sysctl net.ipv6.conf.eth1.accept_ra=0) so it cannot override the VPN.
#
#  Verify on the client:
#    ip route          -> exactly ONE default, via 10.10.10.1 dev eth0
#    curl ifconfig.me  -> shows the VPN public IP
#    (stop gluetun on the gateway -> client internet blocked, LAN still works)
#
# ----------------------------------------------------------------------------
#  3) GETTING THE FORWARDED PORT (clients)
# ----------------------------------------------------------------------------
#    File : /gluetun/forwarded_port on this gateway
#    HTTP : GET http://<this-gateway-ip>:8000/v1/portforward
#           (only this endpoint is public; other control routes need an API key)
#
# ============================================================================

# ---- Gateway / VXLAN settings (edit to match your network) ----
CLIENT_SUBNET=${CLIENT_SUBNET}
GATEWAY_IP=${GATEWAY_IP}
VXLAN_IFACE=${VXLAN_IFACE}
VXLAN_PREFIX=${VXLAN_PREFIX}

# ---- ProtonVPN WireGuard credentials (FILL THESE IN) ----
VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
# Your ProtonVPN WireGuard private key (generate in the Proton account portal
# with "Moderate NAT" enabled). 32-byte base64 string.
WIREGUARD_PRIVATE_KEY=
# Optional server selection, e.g. SERVER_COUNTRIES=Netherlands
SERVER_COUNTRIES=

# ---- NAT-PMP port forwarding ----
VPN_PORT_FORWARDING=on
VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port

# ---- VPN interface / firewall (kill switch) ----
VPN_INTERFACE=tun0
FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT=on
FIREWALL_OUTBOUND_SUBNETS=${CLIENT_SUBNET}

# ---- DNS (clients point here; queries go out via the tunnel) ----
DOT=on
DNS_UPSTREAM_RESOLVERS=cloudflare

# ---- Control server (forwarded-port API on :8000) ----
HTTP_CONTROL_SERVER_ADDRESS=:8000

# ---- Health / state ----
HEALTH_SERVER_ADDRESS=127.0.0.1:9999
STORAGE_FILEPATH=/gluetun/servers.json
PUBLICIP_FILE=/gluetun/ip
LOG_LEVEL=info
TZ=UTC
EOF
msg_ok "Configured Gluetun Gateway"

msg_info "Locking down Control Server"
cat <<EOF >/opt/gluetun-data/auth/config.toml
[[roles]]
name = "clients-portforward"
routes = ["GET /v1/portforward"]
auth = "none"
EOF
msg_ok "Locked down Control Server"

msg_info "Creating Gateway Networking Helper"
cat <<'EOF' >/usr/local/bin/gluetun-gateway-up
#!/usr/bin/env bash
# Applies the VXLAN gateway networking for Gluetun:
#   - assigns GATEWAY_IP to the VXLAN interface (carrier/bridge independent)
#   - (re)generates the gluetun custom firewall rules from the config file
# Values are read straight from /etc/gluetun/gluetun.env so this stays in sync
# with a single edit + service restart.
ENV_FILE=/etc/gluetun/gluetun.env
val() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }

CLIENT_SUBNET="$(val CLIENT_SUBNET)"
GATEWAY_IP="$(val GATEWAY_IP)"
VXLAN_IFACE="$(val VXLAN_IFACE)"
VXLAN_PREFIX="$(val VXLAN_PREFIX)"

if [ -n "$VXLAN_IFACE" ] && ip link show "$VXLAN_IFACE" >/dev/null 2>&1; then
  ip addr replace "${GATEWAY_IP}/${VXLAN_PREFIX}" dev "$VXLAN_IFACE"
  ip link set "$VXLAN_IFACE" up
fi

# Gluetun applies these AFTER building its own firewall and re-applies them on
# every (re)connect, so they only ever exist while the tunnel is up.
mkdir -p /iptables
cat >/iptables/post-rules.txt <<RULES
iptables -A INPUT -s ${CLIENT_SUBNET} -p udp --dport 53 -j ACCEPT
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport 8000 -j ACCEPT
iptables -A FORWARD -s ${CLIENT_SUBNET} -o tun0 -j ACCEPT
iptables -A FORWARD -d ${CLIENT_SUBNET} -i tun0 -j ACCEPT
iptables -t nat -A POSTROUTING -s ${CLIENT_SUBNET} -o tun0 -j MASQUERADE
RULES
EOF
chmod +x /usr/local/bin/gluetun-gateway-up
/usr/local/bin/gluetun-gateway-up
msg_ok "Created Gateway Networking Helper"

msg_info "Configuring DNS Forwarder"
cat <<EOF >/etc/dnsmasq.d/gluetun-gateway.conf
# Serve DNS on the VXLAN interface and forward to Gluetun's local DoT resolver
# (127.0.0.1:53), which sends queries upstream encrypted through the tunnel.
bind-dynamic
interface=${VXLAN_IFACE}
no-resolv
server=127.0.0.1
cache-size=1000
EOF
systemctl restart dnsmasq
msg_ok "Configured DNS Forwarder"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/gluetun-gateway-net.service
[Unit]
Description=Gluetun Gateway VXLAN networking
After=network.target
Before=gluetun.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/gluetun-gateway-up

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/gluetun.service
[Unit]
Description=Gluetun Gateway (ProtonVPN WireGuard)
After=network.target gluetun-gateway-net.service
Wants=gluetun-gateway-net.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gluetun-data
EnvironmentFile=/etc/gluetun/gluetun.env
UnsetEnvironment=USER
ExecStart=/usr/local/bin/gluetun
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now gluetun-gateway-net gluetun
msg_ok "Created Service"

msg_info "Creating Watchdog"
cat <<EOF >/etc/systemd/system/gluetun-watchdog.service
[Unit]
Description=Gluetun Gateway watchdog
After=gluetun.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'curl -fsS --max-time 10 http://127.0.0.1:9999/ >/dev/null 2>&1 || systemctl restart gluetun'
EOF

cat <<EOF >/etc/systemd/system/gluetun-watchdog.timer
[Unit]
Description=Gluetun Gateway watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
systemctl enable -q --now gluetun-watchdog.timer
msg_ok "Created Watchdog"

msg_info "Creating Convenience Symlinks"
ln -sf /etc/gluetun/gluetun.env /root/config.env
ln -sf /gluetun/forwarded_port /root/forwarded_port
ln -sf /gluetun/ip /root/public_ip
msg_ok "Created Convenience Symlinks"

motd_ssh
customize
cleanup_lxc
