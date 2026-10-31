#!/usr/bin/env bash
set -euo pipefail

# Deploy Penumbra to a Samsung Galaxy S4 (jflte) running postmarketOS.
# The phone is armv7, so deployment goes through a postmarketOS package build
# instead of the legacy aarch64 Docker cross-build.

DEVICE_IP="${DEVICE_IP:-172.16.42.1}"
DEVICE_USER="${DEVICE_USER:-user}"
ARCH="${DEVICE_ARCH:-armv7}"
PMAPORTS_DIR="${PMAPORTS_DIR:-}"
PENUMBRA_PACKAGE="penumbra-env"
UI_PACKAGE="postmarketos-ui-penumbra"
BUILD_FIRST=true
RESTART_SESSION=true
CHECK_STATUS_ONLY=false
SHOW_LOGS=false

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[✓]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

usage() {
    cat <<EOF
${BOLD}Usage:${NC} scripts/deploy.sh [OPTIONS]

${BOLD}Options:${NC}
  --build               Build the local checkout and UI packages before deploying (default).
  --no-build            Deploy the packages already present in the pmbootstrap package output.
  --no-restart          Install the packages but do not restart greetd.
  --status              Check phone reachability and Penumbra status, then exit.
  --logs                Show the recent Penumbra session log, then exit.
  --ip <ADDRESS>        Phone IP address (default: 172.16.42.1 or \$DEVICE_IP).
  --user <USER>         Phone SSH user (default: user or \$DEVICE_USER).
  -h, --help            Show this help.

${BOLD}Environment:${NC}
  DEVICE_IP             Phone IP address (default: 172.16.42.1)
  DEVICE_USER           Phone SSH user (default: user)
  DEVICE_ARCH           Package architecture (default: armv7)
  PMAPORTS_DIR          postmarketOS ports checkout (default: pmbootstrap config aports)

Authentication uses your normal SSH configuration. This script intentionally does
not use sshpass; SSH may prompt for a key passphrase, and sudo may prompt on the
phone. For the stock jflte user, the sudo password is 1.

${BOLD}Examples:${NC}
  ./scripts/deploy.sh
  ./scripts/deploy.sh --no-build --no-restart
  ./scripts/deploy.sh --status
EOF
}

while (($# > 0)); do
    case "$1" in
        --build|-b)
            BUILD_FIRST=true
            ;;
        --no-build|--deploy-only)
            BUILD_FIRST=false
            ;;
        --no-restart|--skip-restart)
            RESTART_SESSION=false
            ;;
        --status)
            CHECK_STATUS_ONLY=true
            ;;
        --logs)
            SHOW_LOGS=true
            ;;
        --ip|--device-ip)
            (($# >= 2)) || { log_error "Missing value for $1"; exit 2; }
            DEVICE_IP="$2"
            shift
            ;;
        --user|--device-user)
            (($# >= 2)) || { log_error "Missing value for $1"; exit 2; }
            DEVICE_USER="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
    shift
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
remote="${DEVICE_USER}@${DEVICE_IP}"
staging_dir="penumbra-apks-$(date +%s)"

ssh_cmd=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
scp_cmd=(scp -o StrictHostKeyChecking=accept-new)

log_info "Testing connectivity to ${remote}..."
if ! "${ssh_cmd[@]}" "$remote" 'true' >/dev/null 2>&1; then
    log_error "Cannot connect to ${remote}. Check USB networking/SSH, or pass --ip."
    exit 1
fi
log_success "Device reachable at ${DEVICE_IP}"

if [[ "$CHECK_STATUS_ONLY" == true ]]; then
    log_info "Fetching jflte and Penumbra status..."
    "${ssh_cmd[@]}" "$remote" sh -s <<'STATUS_SCRIPT'
echo "=== Host ==="
uname -a
uptime
echo "=== Service manager ==="
if command -v rc-service >/dev/null 2>&1; then
    echo "OpenRC"
    rc-service greetd status 2>/dev/null || true
    rc-status default 2>/dev/null | grep -E 'greetd|networkmanager' || true
elif command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
    systemctl is-active greetd 2>/dev/null || true
fi
echo "=== Penumbra processes ==="
pgrep -la penumbra || echo "No penumbra processes running."
echo "=== Battery ==="
if [ -d /sys/class/power_supply/battery ]; then
    capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "?")
    status=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "?")
    echo "Battery: ${capacity}% (${status})"
fi
STATUS_SCRIPT
    exit 0
fi

if [[ "$SHOW_LOGS" == true ]]; then
    log_info "Displaying recent session logs..."
    "${ssh_cmd[@]}" "$remote" \
        'cat /tmp/penumbra-session-*.log 2>/dev/null | tail -n 100; logread 2>/dev/null | grep -Ei "greetd|penumbra" | tail -n 60'
    exit 0
fi

if [[ -z "$PMAPORTS_DIR" ]]; then
    if command -v pmbootstrap >/dev/null 2>&1; then
        PMAPORTS_DIR=$(pmbootstrap config aports)
    elif [[ -d "$repo_root/../pmaports" ]]; then
        PMAPORTS_DIR="$repo_root/../pmaports"
    else
        log_error "Cannot find pmaports. Set PMAPORTS_DIR or install pmbootstrap."
        exit 1
    fi
fi
[[ -f "$PMAPORTS_DIR/temp/$PENUMBRA_PACKAGE/APKBUILD" ]] || {
    log_error "Missing package: $PMAPORTS_DIR/temp/$PENUMBRA_PACKAGE/APKBUILD"
    exit 1
}
[[ -f "$PMAPORTS_DIR/main/$UI_PACKAGE/APKBUILD" ]] || {
    log_error "Missing UI package: $PMAPORTS_DIR/main/$UI_PACKAGE/APKBUILD"
    exit 1
}

pmbootstrap_cmd=(pmbootstrap -p "$PMAPORTS_DIR")

if [[ "$BUILD_FIRST" == true ]]; then
    log_info "Building local Penumbra checkout for $ARCH..."
    "${pmbootstrap_cmd[@]}" build --lax --arch "$ARCH" --force --src "$repo_root" "$PENUMBRA_PACKAGE"

    log_info "Building $UI_PACKAGE..."
    "${pmbootstrap_cmd[@]}" build --lax --arch "$ARCH" --force "$UI_PACKAGE"
fi

apkbuild_version() {
    local apkbuild=$1
    local pkgver pkgrel
    pkgver=$(awk -F= '/^pkgver=/{print $2; exit}' "$apkbuild")
    pkgrel=$(awk -F= '/^pkgrel=/{print $2; exit}' "$apkbuild")
    printf '%s-r%s' "$pkgver" "$pkgrel"
}

penumbra_version=$(apkbuild_version "$PMAPORTS_DIR/temp/$PENUMBRA_PACKAGE/APKBUILD")
ui_version=$(apkbuild_version "$PMAPORTS_DIR/main/$UI_PACKAGE/APKBUILD")
work_dir=$("${pmbootstrap_cmd[@]}" config work)
packages_dir="$work_dir/packages/edge/$ARCH"

apk_paths=(
    "$packages_dir/$PENUMBRA_PACKAGE-$penumbra_version.apk"
    "$packages_dir/$UI_PACKAGE-$ui_version.apk"
    "$packages_dir/$UI_PACKAGE-openrc-$ui_version.apk"
)

for apk_path in "${apk_paths[@]}"; do
    if [[ ! -f "$apk_path" ]]; then
        log_error "Missing built package: $apk_path"
        log_error "Run './scripts/deploy.sh --build' first."
        exit 1
    fi
done
log_success "Found ${#apk_paths[@]} built packages."

log_info "Uploading packages to $remote..."
"${ssh_cmd[@]}" "$remote" "rm -rf '$staging_dir' && mkdir -p '$staging_dir'"
"${scp_cmd[@]}" "${apk_paths[@]}" "$remote:$staging_dir/"

remote_apks=
for apk_path in "${apk_paths[@]}"; do
    remote_apks="$remote_apks $staging_dir/$(basename "$apk_path")"
done

log_info "Installing Penumbra packages on jflte..."
ssh -tt -o StrictHostKeyChecking=accept-new "$remote" \
    "sudo apk add --allow-untrusted$remote_apks && rm -rf '$staging_dir'"
log_success "Packages installed."

if [[ "$RESTART_SESSION" == true ]]; then
    log_info "Restarting greetd..."
    if "${ssh_cmd[@]}" "$remote" 'command -v rc-service >/dev/null 2>&1'; then
        ssh -tt -o StrictHostKeyChecking=accept-new "$remote" 'sudo rc-service greetd restart'
    elif "${ssh_cmd[@]}" "$remote" 'command -v systemctl >/dev/null 2>&1'; then
        ssh -tt -o StrictHostKeyChecking=accept-new "$remote" 'sudo systemctl restart greetd'
    else
        log_warn "No supported service manager found; Penumbra will start after reboot."
    fi

    log_info "Waiting for the Penumbra compositor..."
    sleep 5
    active_comp=$("${ssh_cmd[@]}" "$remote" 'pgrep -la penumbra-comp || true')
    if [[ -n "$active_comp" ]]; then
        log_success "Penumbra compositor is running: $active_comp"
    else
        log_warn "penumbra-comp is not running yet. Check './scripts/deploy.sh --logs'."
    fi
fi

log_success "Deployment to jflte (${DEVICE_IP}) finished."
