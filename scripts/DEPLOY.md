# Deploying Penumbra

Run these commands from the Penumbra repository. The script detects the
connected phone architecture through SSH. SSH uses your existing keys,
agent or interactive password prompt; it does not require sshpass.

## Galaxy S4 (jflte, ARMv7)

This checkout uses the adjacent postmarketOS workspace:

- Package recipe: `../pmaports/temp/penumbra-env/APKBUILD`
- Build output: `../work/packages/edge/armv7/`
- Phone: `user@172.16.42.1`

For the first deployment:

```sh
./scripts/deploy.sh --build
```

The ARMv7 builder snapshots the committed Penumbra revision with
`git archive`, refreshes the source checksum and package release, commits
those two generated packaging changes, then invokes:

```sh
pmbootstrap build --lax --arch armv7 penumbra-env --force
```

Commit source changes before building. The ARMv7 package directory must
also have no uncommitted changes. Untracked source files are not included
in the Git snapshot. pmbootstrap must already be configured for this
postmarketOS workspace. The package builds the native DRM compositor.

The deploy script installs the resulting APK, allowing apk to resolve
runtime dependencies. It checks shared libraries before restarting the
active display manager. On the S4 this is OpenRC's greetd with the Phrog
greeter. Select **Penumbra Mobile** in the login screen, then log in.
Select **Phosh** there to return to the previous environment. Deployment
adds a session entry; it does not replace the greeter configuration or
enable automatic login. Restarting the display manager ends the current
graphical session.

To install without ending the current session:

```sh
./scripts/deploy.sh --build --no-restart
```

Then log out manually and select Penumbra. Subsequent deployments can
reuse the existing package:

```sh
./scripts/deploy.sh
./scripts/deploy.sh --apk /path/to/penumbra-env-0.1.0-r2.apk
```

The S4 display defaults are installed in `/etc/penumbra/session.conf`:
1080×1920 physical pixels and shell scale 1.0. The compositor currently
uses a fixed 412×915 logical canvas and fits it to the panel, so the S4
can have side margins. This deployment change does not resize that
canvas or establish compositor/rendering compatibility with the Adreno
320; those require testing on the phone.

## ARM64

ARM64 deployment retains the Docker builder and raw release binaries:

```sh
./scripts/deploy.sh --build
./scripts/deploy.sh --release-dir target/cross/aarch64-unknown-linux-musl/release
```

Raw binaries are checked for the target ELF architecture. Install their
runtime dependencies before deploying. APK installation is currently
supported only for the ARMv7 package in this workspace.

## Options and diagnostics

```sh
./scripts/deploy.sh --help
./scripts/deploy.sh --status
./scripts/deploy.sh --logs
./scripts/deploy.sh --ip 172.16.42.1 --user user --no-restart
```

`--status` and `--logs` do not build, install or restart anything, even
when `--build` is also specified. Logs are written to stderr; session
logs remain under `/tmp/penumbra-session-*.log` on the phone.

Environment overrides: `DEVICE_IP`, `DEVICE_USER`, `SUDO_PASSWORD`,
`PENUMBRA_APK`, `PENUMBRA_RELEASE_DIR`, `PMAPORTS_DIR`, and `PMB_WORK`.
`SUDO_PASSWORD` defaults to `1`; an explicitly empty value selects
passwordless `sudo -n`. To repair USB networking in this workspace, run
`../tools/fixup-network.sh`, then wake/unlock the phone and retry.
