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
1080×1920 physical pixels, a 515×915 logical canvas, and shell scale 1.0.
The compositor and layer-shell clients use the configured logical width
for rendering, app sizes, touch coordinates and external-display origins.
This aspect ratio fills the S4 panel width using uniform scaling; it does
not stretch the old 412-pixel-wide layout. The default remains 412×915
when no device width is configured. The logical height remains 915.

### UI verification after rebuilding

Check that the home screen, apps, bars and keyboard span the display,
then open the top shade and swipe upward from empty space and its bottom
handle. Shade gestures now use screen coordinates and incremental motion,
and state notifications are drained during its close animation.

For the app drawer, compare dragging on an icon with dragging on empty
space, then test kinetic scrolling in both directions. The launcher now
refreshes task models and icons only when the window list changes. Its
software rendering backend retains the previous pixel frame for
[Slint partial repainting](https://docs.slint.dev/latest/docs/rust/slint/platform/software_renderer/enum.RepaintBufferType),
copying complete frames to available Wayland SHM buffers and repainting
fully after a resize. The desktop-shell supervisor waits for an external
display rather than repeatedly launching on a phone-only session.
These changes require on-device validation; no new frame-rate measurement
or compilation was performed while preparing them.

### Reusing ARMv7 build work

The local package keeps its caches under
`/home/pmos/.cache/penumbra-env` inside the ARMv7 build chroot:

- `cargo/`: downloaded crates and registry metadata.
- `source/armv7/`: stable source paths, synchronized by content without
  changing the timestamps of unchanged files.
- `target/armv7/`: compiled dependencies, binaries and incremental state.

These survive ordinary package cleanup and `--force` rebuilds. The
workspace is built once with `penumbra-comp/native-drm` enabled. The first
build after this cache change is still cold; subsequent changes should
reuse dependencies and unchanged crates. Modified crates and their
dependents still need compilation/linking, and APK packaging still runs.
No build-time improvement has been measured yet. Removing the build
chroot or these cache directories makes the next build cold again.
`XDG_CACHE_HOME`, if set by the build environment, replaces the `.cache`
base directory. See [Cargo's build cache documentation](https://doc.rust-lang.org/cargo/reference/build-cache.html).

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
