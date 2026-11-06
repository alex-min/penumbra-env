#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEVICE_IP=${DEVICE_IP:-172.16.42.1}
DEVICE_USER=${DEVICE_USER:-user}
SUDO_PASSWORD=${SUDO_PASSWORD-1}
PMAPORTS_DIR=${PMAPORTS_DIR:-$repo_root/../pmaports}
PMB_WORK=${PMB_WORK:-$repo_root/../work}
build=false
restart=true
action=deploy
apk=${PENUMBRA_APK:-}
release_dir=${PENUMBRA_RELEASE_DIR:-}

log() { printf '[penumbra] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
usage() {
    cat <<'EOF'
Usage: ./scripts/deploy.sh [OPTIONS]

  --build                Build for the connected phone before deploying.
  --no-build             Deploy an existing build (default).
  --apk PATH             Use an existing ARMv7 penumbra-env APK.
  --release-dir PATH     Use existing binaries instead of an APK.
  --no-restart           Install without restarting the display manager.
  --status               Show phone, display-manager and battery status.
  --logs                 Show recent Penumbra session logs.
  --ip ADDRESS           SSH address (default: 172.16.42.1).
  --user USER            SSH user (default: user).
  --sudo-pass PASSWORD   Remote sudo password (default: 1).
  -h, --help             Show this help.

SSH uses normal keys, an agent or interactive authentication; no sshpass.
ARMv7 builds use pmbootstrap and ../pmaports/temp/penumbra-env.
ARM64 builds use the existing Docker builder.
Override package locations with PMAPORTS_DIR and PMB_WORK.
After deployment select "Penumbra Mobile" in the login screen.
EOF
}

while (($#)); do
    case "$1" in
        --build|-b) build=true ;;
        --no-build|--deploy-only) build=false ;;
        --no-restart|--skip-restart) restart=false ;;
        --status) action=status ;;
        --logs) action=logs ;;
        --ip|--device-ip|--user|--device-user|--sudo-pass|--sudo-password|--apk|--release-dir)
            (($# >= 2)) && [[ -n "$2" ]] || die "Missing value for $1"
            case "$1" in
                --ip|--device-ip) DEVICE_IP=$2 ;;
                --user|--device-user) DEVICE_USER=$2 ;;
                --sudo-pass|--sudo-password) SUDO_PASSWORD=$2 ;;
                --apk) apk=$2 ;;
                --release-dir) release_dir=$2 ;;
            esac
            shift ;;
        --password|--device-password)
            die 'Use SSH keys, an agent or interactive SSH authentication instead of --password.' ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

[[ $DEVICE_USER =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die 'Invalid SSH user'
[[ $DEVICE_IP != -* && $DEVICE_IP != *[[:space:]]* && $DEVICE_IP != *@* ]] || die 'Invalid SSH address'
[[ -z $apk || -z $release_dir ]] || die 'Choose --apk or --release-dir, not both.'
if $build && [[ -n $apk || -n $release_dir ]]; then
    die '--build cannot be combined with an explicit artifact path.'
fi
remote=$DEVICE_USER@$DEVICE_IP
ssh_cmd=(ssh -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
scp_cmd=(scp -o ConnectTimeout=8)

log "Connecting to $remote"
if ! arch=$("${ssh_cmd[@]}" "$remote" uname -m); then
    die "Cannot reach $remote. Check USB networking (../tools/fixup-network.sh) and wake/unlock the phone."
fi
case "$arch" in
    armv7l|armv8l) target=armv7 ;;
    aarch64) target=aarch64 ;;
    *) die "Unsupported phone architecture: $arch" ;;
esac

if [[ $action == status ]]; then
    "${ssh_cmd[@]}" "$remote" sh -s <<'STATUS'
set -eu
uname -a
uptime
if command -v rc-service >/dev/null 2>&1; then
    for service in greetd lightdm gdm tinydm; do
        rc-service "$service" status 2>/dev/null || true
    done
elif command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status greetd gdm lightdm tinydm 2>/dev/null || true
fi
pgrep -af 'penumbra|phrog|phosh|phoc' || true
for property in capacity status voltage_now; do
    if [ -r "/sys/class/power_supply/battery/$property" ]; then
        printf '%s: ' "$property"
        cat "/sys/class/power_supply/battery/$property"
    fi
done
STATUS
    exit 0
elif [[ $action == logs ]]; then
    "${ssh_cmd[@]}" "$remote" 'tail -n 80 /tmp/penumbra-session-*.log 2>/dev/null || true'
    exit 0
fi

if $build; then
    if [[ $target == armv7 ]]; then
        PMAPORTS_DIR="$PMAPORTS_DIR" "$repo_root/scripts/build-armv7-alpine.sh" >&2
    else
        "$repo_root/scripts/build-arm64-alpine.sh" >&2
    fi
fi

mode=binaries
if [[ $target == armv7 && -z $release_dir ]]; then
    mode=apk
    if [[ -z $apk ]]; then
        apkbuild=$PMAPORTS_DIR/temp/penumbra-env/APKBUILD
        [[ -f $apkbuild ]] || die "Missing $apkbuild"
        version=$(sed -n 's/^pkgver=//p' "$apkbuild")-r$(sed -n 's/^pkgrel=//p' "$apkbuild")
        apk=$PMB_WORK/packages/edge/armv7/penumbra-env-$version.apk
    fi
    [[ -f $apk ]] || die "Missing $apk; run ./scripts/deploy.sh --build first."
    info=$(tar --warning=no-unknown-keyword -xOf "$apk" .PKGINFO)
    grep -qx 'pkgname = penumbra-env' <<<"$info" || die 'APK is not penumbra-env.'
    grep -qx 'arch = armv7' <<<"$info" || die 'APK is not built for ARMv7.'
else
    [[ -z $apk ]] || die '--apk is only supported for ARMv7.'
    release_dir=${release_dir:-$repo_root/target/cross/aarch64-unknown-linux-musl/release}
    required_bins=(penumbra-comp penumbra-top-bar penumbra-homescreen penumbra-nav-bar
        penumbra-settings penumbra-keyboard penumbra-greeter penumbra-shell penumbra-desktop-shell)
    for binary in "${required_bins[@]}"; do
        [[ -x $release_dir/$binary ]] || die "Missing executable: $release_dir/$binary"
        header=$(LC_ALL=C readelf -h "$release_dir/$binary")
        if [[ $target == armv7 ]]; then
            grep -Eq 'Machine:[[:space:]]+ARM$' <<<"$header" || die "$binary is not ARMv7."
            grep -q 'hard-float ABI' <<<"$header" || die "$binary does not use the ARM hard-float ABI."
        else
            grep -Eq 'Machine:[[:space:]]+AArch64$' <<<"$header" || die "$binary is not ARM64."
        fi
    done
fi

"${ssh_cmd[@]}" "$remote" 'command -v bash >/dev/null' || die 'Install bash on the phone first.'
stage=$("${ssh_cmd[@]}" "$remote" 'mktemp -d /tmp/penumbra-deploy.XXXXXXXX')
[[ $stage =~ ^/tmp/penumbra-deploy\.[a-zA-Z0-9]+$ ]] || die 'Unexpected staging path'
cleanup() { "${ssh_cmd[@]}" "$remote" "rm -rf '$stage'" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [[ $mode == apk ]]; then
    "${scp_cmd[@]}" "$apk" "$remote:$stage/penumbra-env.apk" >&2
else
    "${ssh_cmd[@]}" "$remote" "mkdir '$stage/bin' '$stage/assets'"
    "${scp_cmd[@]}" "${required_bins[@]/#/$release_dir/}" "$remote:$stage/bin/" >&2
    "${scp_cmd[@]}" "$repo_root"/scripts/penumbra{,-native,-nested}-session \
        "$repo_root"/data/penumbra{,-settings,-keyboard}.desktop "$remote:$stage/" >&2
    "${scp_cmd[@]}" -r "$repo_root/assets/." "$remote:$stage/assets/" >&2
fi

# Keep the installer separate from sudo's password input.
"${ssh_cmd[@]}" "$remote" "cat > '$stage/install.sh'" <<'INSTALL'
#!/bin/sh
set -eu
stage=$1 mode=$2 target=$3 login_user=$4 restart=$5
if [ "$mode" = apk ]; then
    apk --no-interactive --wait 30 add --allow-untrusted "$stage/penumbra-env.apk" >&2
    compositor=/usr/bin/penumbra-comp
else
    install -d /usr/local/bin /usr/share/wayland-sessions /usr/share/applications /usr/share/penumbra/assets
    install -m755 "$stage"/bin/* "$stage"/penumbra*-session /usr/local/bin/
    install -m644 "$stage/penumbra.desktop" /usr/share/wayland-sessions/
    install -m644 "$stage/penumbra-settings.desktop" "$stage/penumbra-keyboard.desktop" /usr/share/applications/
    cp -a "$stage/assets/." /usr/share/penumbra/assets/
    compositor=/usr/local/bin/penumbra-comp
fi

for binary in "$(dirname "$compositor")"/penumbra-*; do
    case "$binary" in *-session) continue ;; esac
    dependencies=$(ldd "$binary" 2>&1) || {
        case "$dependencies" in *'Not a valid dynamic program'*|*'not a dynamic executable'*|*'statically linked'*) continue ;; esac
        printf '%s\n' "$dependencies" >&2
        exit 1
    }
    if printf '%s\n' "$dependencies" | grep -Eq 'not found|Error loading|Error relocating'; then
        printf '%s\n' "$dependencies" >&2
        exit 1
    fi
done

if [ "$target" = armv7 ]; then
    install -d /etc/penumbra
    if [ -f /etc/penumbra/session.conf ]; then
        cp -p /etc/penumbra/session.conf /etc/penumbra/session.conf.before-deploy
    fi
    cat > /etc/penumbra/session.conf <<'CONFIG'
export PENUMBRA_OUTPUT_WIDTH=1080
export PENUMBRA_OUTPUT_HEIGHT=1920
export PENUMBRA_LOGICAL_WIDTH=515
export PENUMBRA_LOGICAL_HEIGHT=915
export PENUMBRA_SCALE_FACTOR=1.0
CONFIG
fi
install -d /etc/udev/rules.d
cat > /etc/udev/rules.d/90-penumbra-backlight.rules <<'RULE'
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod 0664 /sys/class/backlight/%k/brightness"
RULE
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --action=add --subsystem-match=backlight 2>/dev/null || true
udevadm settle 2>/dev/null || true
for brightness in /sys/class/backlight/*/brightness; do
    [ -e "$brightness" ] || continue
    chgrp video "$brightness"
    chmod 0664 "$brightness"
done
for group in video input audio; do
    if ! id -nG "$login_user" | tr ' ' '\n' | grep -qx "$group"; then
        if command -v usermod >/dev/null 2>&1; then
            usermod -aG "$group" "$login_user"
        else
            addgroup "$login_user" "$group"
        fi
    fi
done
if [ "$restart" = true ]; then
    if command -v rc-service >/dev/null 2>&1; then
        for service in greetd lightdm gdm tinydm; do
            if rc-service "$service" status >/dev/null 2>&1; then
                exec rc-service "$service" restart
            fi
        done
    elif command -v systemctl >/dev/null 2>&1; then
        for service in greetd gdm lightdm tinydm; do
            if systemctl is-active --quiet "$service"; then
                exec systemctl restart "$service"
            fi
        done
    fi
    echo 'No active display manager found; log out and select Penumbra manually.' >&2
fi
INSTALL

printf -v install_args '%q ' "$stage/install.sh" "$stage" "$mode" "$target" "$DEVICE_USER" "$restart"
if [[ -n $SUDO_PASSWORD ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | "${ssh_cmd[@]}" "$remote" "sudo -S -p '' sh $install_args" >&2
else
    "${ssh_cmd[@]}" "$remote" "sudo -n sh $install_args" >&2
fi
log 'Installed. Select Penumbra Mobile in the login screen; select Phosh to return.'
