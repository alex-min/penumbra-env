#!/usr/bin/env bash
set -euo pipefail

# Legacy deploy-to-device.sh wrapper forwarding to scripts/deploy.sh
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

args=()
while (($# > 0)); do
    case "$1" in
        --build-only)
            args+=(--build --no-restart)
            ;;
        --deploy-only)
            args+=(--no-build)
            ;;
        --device-ip)
            args+=(--ip "$2")
            shift
            ;;
        --device-user)
            args+=(--user "$2")
            shift
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift
done

exec "$repo_root/scripts/deploy.sh" "${args[@]}"