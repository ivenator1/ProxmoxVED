#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: ivenator1
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/qdm12/gluetun

APP="Gluetun-Gateway"
var_tags="${var_tags:-vpn;wireguard;gateway}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"
var_tun="${var_tun:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /usr/local/bin/gluetun ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "gluetun" "qdm12/gluetun"; then
    msg_info "Stopping Service"
    systemctl stop gluetun
    msg_ok "Stopped Service"

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "gluetun" "qdm12/gluetun" "tarball"

    msg_info "Building Gluetun"
    cd /opt/gluetun
    $STD go mod download
    CGO_ENABLED=0 $STD go build -trimpath -ldflags="-s -w" -o /usr/local/bin/gluetun ./cmd/gluetun/
    msg_ok "Built Gluetun"

    msg_info "Starting Service"
    systemctl start gluetun
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Next steps to get the gateway online:${CL}"
echo -e "${TAB}${BGN}1.${CL}${GN} Set your VPN provider + credentials in the config (also at ~/config.env):${CL}"
echo -e "${TAB}${TAB}${GATEWAY}${BGN}/etc/gluetun/gluetun.env${CL}"
echo -e "${TAB}${TAB}${YW}(VPN_SERVICE_PROVIDER, VPN_TYPE, credentials, CLIENT_SUBNET, GATEWAY_IP)${CL}"
echo -e "${TAB}${BGN}2.${CL}${GN} Attach the VXLAN NIC on the Proxmox host (no IP needed):${CL}"
echo -e "${TAB}${TAB}${GATEWAY}${BGN}pct set <ctid> -net1 name=eth1,bridge=<vxlan-vnet>${CL}"
echo -e "${TAB}${BGN}3.${CL}${GN} Apply the config:${CL}"
echo -e "${TAB}${TAB}${GATEWAY}${BGN}systemctl restart gluetun-gateway-net${CL}"
echo -e "${TAB}${TAB}${GATEWAY}${BGN}systemctl enable --now gluetun gluetun-watchdog.timer${CL}"
echo -e "${TAB}${BGN}4.${CL}${GN} Point each client LXC's default gateway and DNS at this box's VXLAN IP.${CL}"
echo -e "${INFO}${YW} Read-only API endpoints:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000/v1/portforward${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000/v1/vpn/status${CL}"
echo -e "${INFO}${YW} VPN public IP: ${BGN}~/public_ip${CL}${YW}  |  Forwarded port: ${BGN}~/forwarded_port${CL}"
