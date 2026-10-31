# Penumbra jflte Deployment

`deploy.sh` installs the local Penumbra checkout on a Samsung Galaxy S4 (`jflte`) running postmarketOS.

## Packaging layout

The deployment uses pmaports packages rather than copying binaries into `/usr/local`:

- `pmaports/temp/penumbra-env`: Rust binaries, session launchers, desktop entries, assets, and udev backlight rules.
- `pmaports/main/postmarketos-ui-penumbra`: `postmarketos-ui` integration, greetd configuration, and the OpenRC service subpackage.

`pmbootstrap config ui penumbra` discovers the UI through `postmarketos-ui-penumbra` and defaults to OpenRC, which matches the jflte device configuration.

## Usage

```bash
./scripts/deploy.sh
```

By default this command:

1. Connects to `user@172.16.42.1` with normal SSH authentication.
2. Builds the local Penumbra checkout for `armv7` with `pmbootstrap build --src`.
3. Builds `postmarketos-ui-penumbra` and its OpenRC subpackage.
4. Copies the APKs to the phone and installs them with `apk add`.
5. Restarts `greetd` and checks whether `penumbra-comp` starts.

Options:

```text
--build / -b          build before installing (default)
--no-build            install the APKs already in pmbootstrap's package output
--no-restart          install without restarting greetd
--status              show phone, greetd, Penumbra, and battery status
--logs                show recent Penumbra logs
--ip <ADDRESS>        override the phone IP
--user <USER>         override the SSH user
-h, --help            show help
```

Environment overrides:

- `DEVICE_IP` (default `172.16.42.1`)
- `DEVICE_USER` (default `user`)
- `DEVICE_ARCH` (default `armv7`)
- `PMAPORTS_DIR` (default: the active `pmbootstrap config aports`)

## Authentication

The script intentionally does not use `sshpass`. Use an SSH key or respond to the normal SSH prompt. `sudo` runs in a terminal on the phone, so it can prompt interactively.

## Fresh postmarketOS images

For a new image, select Penumbra as the UI:

```bash
pmbootstrap config ui penumbra
pmbootstrap install
```

The UI package installs `/etc/greetd/config.toml`, configures greetd to launch `penumbra-greeter` under `cage`, and enables the greetd OpenRC service. The jflte session defaults to a 1080x1920 output with a 412x732 logical shell canvas.
