#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

MODE="${MODE:-}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/snowluma}"
BOT_NETWORK="${SNOWLUMA_BOT_NETWORK:-maim_bot}"
IMAGE="${SNOWLUMA_IMAGE:-motricseven7/snowluma:latest}"
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
SnowLuma Linux installer (Docker).

Usage:
  ./install.sh [--mode docker|compose] [--dir PATH] [--network NAME] [--yes] [--dry-run]

Modes:
  docker    Standalone official image (default for an empty host)
  compose   Sidecar: join an existing bot compose network, do not edit the bot files
  host      Advanced, not in this installer yet

Examples:
  ./install.sh --mode docker --yes
  ./install.sh --mode compose --network maim_bot --dir ~/snowluma --yes

Do not pipe this script from a URL. Download it, inspect it, then run it.
EOF
}

log() { printf '%s\n' "$*"; }
err() { printf '错误: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

is_tty() { [[ -t 0 && -t 1 ]]; }

panel_docker() {
  if have 1pctl || [[ -d /opt/1panel ]] || systemctl is-active --quiet 1panel 2>/dev/null; then
    return 0
  fi
  if [[ -x /etc/init.d/bt ]] || [[ -d /www/server/panel ]]; then
    return 0
  fi
  return 1
}

mem_kb() { awk '/MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0; }

choose_mode() {
  if [[ -n "${MODE}" ]]; then
    return
  fi
  if have gum && is_tty; then
    MODE="$(gum choose --header '安装模式' docker compose)"
    return
  fi
  if is_tty; then
    log '1) docker   独立官方镜像（空 VPS）'
    log '2) compose  接入已有机器人网络（sidecar）'
    printf '选择 [1/2]（默认 1）: '
    read -r reply || true
    case "${reply}" in
      2|compose) MODE=compose ;;
      *) MODE=docker ;;
    esac
    return
  fi
  MODE=docker
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --mode) MODE="${2:-}"; shift 2 ;;
      --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --network) BOT_NETWORK="${2:-}"; shift 2 ;;
      --image) IMAGE="${2:-}"; shift 2 ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      host|--host)
        die '宿主机模式是进阶路径，本安装器尚未覆盖。请使用 --mode docker 或 --mode compose。'
        ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi
  if have gum && is_tty; then
    gum confirm "${prompt}"
    return
  fi
  if is_tty; then
    printf '%s [y/N] ' "${prompt}"
    read -r reply || true
    [[ "${reply}" == [yY] || "${reply}" == yes ]]
    return
  fi
  die '非交互环境请加上 --yes'
}

preflight() {
  [[ "$(uname -s)" == Linux ]] || die '只支持 Linux。'
  local kb
  kb="$(mem_kb)"
  if [[ "${kb}" -gt 0 && "${kb}" -lt 1900000 ]]; then
    die "内存约 $((kb / 1024)) MB，低于 2 GB。QQ 桌面跑不起来。"
  fi
  if have docker && docker info >/dev/null 2>&1; then
    if docker info 2>/dev/null | grep -qi 'snap'; then
      die '检测到 snap 版 Docker。请改用发行版或 Docker CE，然后重跑。'
    fi
  fi
}

install_docker_if_needed() {
  if have docker && docker info >/dev/null 2>&1; then
    log '已检测到可用的 Docker，跳过安装。'
    return
  fi
  if panel_docker; then
    die '本机是 1Panel / 宝塔环境且 Docker 不可用。请先在面板里安装 Docker，不要让本脚本改 daemon.json。'
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log '[dry-run] 将安装 Docker CE（国内镜像源）。'
    return
  fi
  confirm '未检测到 Docker，将安装 Docker CE。继续？' || die '已取消。'
  local get_docker
  get_docker="$(mktemp)"
  if ! curl -fsSL --retry 3 --retry-delay 2 https://get.docker.com -o "${get_docker}"; then
    die '下载 get.docker.com 失败（网络/TLS）。请检查出网后再试，或手动安装 Docker CE。'
  fi
  sh "${get_docker}" --mirror Aliyun
  rm -f "${get_docker}"
  if ! have docker; then
    die 'Docker 安装流程结束但仍没有 docker 命令。'
  fi
}

write_stack() {
  local template dest_compose
  mkdir -p "${INSTALL_DIR}"
  dest_compose="${INSTALL_DIR}/docker-compose.yml"
  if [[ "${MODE}" == compose ]]; then
    template="${TEMPLATE_DIR}/compose.sidecar.yml"
  else
    template="${TEMPLATE_DIR}/compose.yml"
  fi
  [[ -f "${template}" ]] || die "找不到模板 ${template}（请在 SnowLuma.Docker.Framework 仓库内运行）。"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] 将复制 ${template} -> ${dest_compose}"
    log "[dry-run] 镜像 ${IMAGE}  网络 ${BOT_NETWORK}  目录 ${INSTALL_DIR}"
    return
  fi
  cp "${template}" "${dest_compose}"
  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    sed \
      -e "s|^SNOWLUMA_IMAGE=.*|SNOWLUMA_IMAGE=${IMAGE}|" \
      -e "s|^SNOWLUMA_BOT_NETWORK=.*|SNOWLUMA_BOT_NETWORK=${BOT_NETWORK}|" \
      "${TEMPLATE_DIR}/.env.example" > "${INSTALL_DIR}/.env"
  fi
}

pull_image() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] 将拉取 ${IMAGE}"
    return
  fi
  if docker pull "${IMAGE}"; then
    return
  fi
  err "直连拉取失败，尝试镜像前缀 docker.1ms.run"
  local prefixed="docker.1ms.run/${IMAGE#docker.io/}"
  if docker pull "${prefixed}"; then
    docker tag "${prefixed}" "${IMAGE}"
    return
  fi
  die "拉取镜像失败。这是 Docker Hub 这一跳。可在面板/云厂商加镜像加速，或离线 docker load。"
}

compose_up() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] 将在 ${INSTALL_DIR} 执行 docker compose up -d"
    return
  fi
  if [[ "${MODE}" == compose ]]; then
    if ! docker network inspect "${BOT_NETWORK}" >/dev/null 2>&1; then
      die "找不到外部网络 ${BOT_NETWORK}。先启动机器人那一套 compose，或把 --network 改成实际网络名（docker network ls）。"
    fi
  fi
  (cd "${INSTALL_DIR}" && docker compose up -d)
}

print_next() {
  local name
  name="$(awk -F= '/^SNOWLUMA_CONTAINER=/{print $2; exit}' "${INSTALL_DIR}/.env" 2>/dev/null || true)"
  name="${name:-snowluma}"
  log
  log "已写入 ${INSTALL_DIR}"
  log "noVNC:  http://<主机IP>:6081/"
  log "WebUI:  http://<主机IP>:5099/"
  if [[ "${MODE}" == compose ]]; then
    log "正向 WS: ws://snowluma:3001  （机器人容器内用服务名 snowluma）"
  fi
  log
  log "查看远程桌面密码和 WebUI 临时密码："
  log "  docker logs ${name} 2>&1 | grep -E '远程桌面密码:|remote desktop password:|临时密码|initial credentials' | tail -n 5"
}

parse_args "$@"
choose_mode
case "${MODE}" in
  docker|compose) ;;
  host) die '宿主机模式是进阶路径，本安装器尚未覆盖。' ;;
  *) die "未知模式: ${MODE}" ;;
esac

log "模式=${MODE}  目录=${INSTALL_DIR}  镜像=${IMAGE}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  write_stack
  log 'dry-run 结束，未改动本机。'
  exit 0
fi
preflight
install_docker_if_needed
write_stack
pull_image
compose_up
print_next
