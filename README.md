# Pyrowave pacman repository

A signed pacman repository, `[pyrowave]`, for Arch Linux, CachyOS and other
Arch-based x86_64 systems. It provides:

| Package | Contents |
| --- | --- |
| `pyroshine-bin` | [Pyroshine](https://github.com/karsyboy/pyroshine) streaming host: server, systemd service, udev rules and PyroWave library |
| `pyroshine-ui-bin` | Pyroshine desktop app: tray, pairing, client management, settings and stream dashboard |
| `pyrolight-bin` | [Pyrolight](https://github.com/karsyboy/pyrolight) streaming client with PyroWave support |

Each package repackages the Arch package attached to the project's GitHub
release. New stable releases appear here within about an hour.

## Setup

Trust the repository's signing key, then add the repository to pacman:

```sh
curl -fsSL https://raw.githubusercontent.com/karsyboy/pyrowave-packages/main/keys/pyrowave.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key A8054CC188EAE0293E3EA5B509DC88C65239130E
printf '\n[pyrowave]\nServer = https://github.com/karsyboy/pyrowave-packages/releases/download/x86_64\n' | sudo tee -a /etc/pacman.conf
```

The key fingerprint is `A8054CC188EAE0293E3EA5B509DC88C65239130E`
(*Pyrowave pacman repository (karsyboy)*).

## Install and upgrade

```sh
# Streaming host, optionally with its desktop app
sudo pacman -Syu pyroshine-bin pyroshine-ui-bin
sudo systemctl enable --now "pyroshine@$USER"

# Streaming client
sudo pacman -Syu pyrolight-bin
```

`sudo pacman -Syu` upgrades them with the rest of the system. After a Pyroshine
upgrade, restart the service: `sudo systemctl restart "pyroshine@$USER"`.

`pyrolight-bin` replaces `moonlight-qt`: Pyrolight keeps Moonlight's desktop ID
and settings, so paired hosts carry over. `pyroshine-bin` conflicts with
`moonshine`.

To remove the repository, uninstall its packages, delete the `[pyrowave]`
section from `/etc/pacman.conf`, and run
`sudo pacman-key --delete A8054CC188EAE0293E3EA5B509DC88C65239130E`.

## How it works

The [publish workflow](.github/workflows/publish.yml) runs hourly, on manual
dispatch and on pushes that change a package. It runs
[scripts/sync.sh](scripts/sync.sh) in an Arch container, which:

1. Finds each project's newest stable release (tags `vX.Y.Z`; prereleases are
   skipped) and updates `pkgver`, checksums and `.SRCINFO` with
   [scripts/update-pkgbuild.sh](scripts/update-pkgbuild.sh).
2. Builds and signs every package file the database does not list yet.
3. Adds them to the signed `pyrowave` database and uploads packages, then the
   database, to the `x86_64` release of this repository.
4. Deletes package files the database no longer lists.

The workflow then commits the updated PKGBUILDs. A published package file is
never replaced, because pacman caches packages by file name.

## Maintenance

| Task | How |
| --- | --- |
| Publish a release now | Run the **Publish** workflow from the Actions tab |
| Fix a PKGBUILD | Edit it, bump `pkgrel`, run `makepkg --printsrcinfo > .SRCINFO` and push |
| Change dependencies | Keep `depends` in sync with the `archlinux` overrides in Pyroshine's `nfpm.yaml`/`nfpm-ui.yaml` and Pyrolight's `app/deploy/linux/nfpm.yaml` |
| Test locally | `GPGKEY=<fingerprint> STORE=/tmp/pyrowave-repo scripts/sync.sh` publishes to a directory instead of GitHub |

The workflow needs the `PACMAN_SIGNING_KEY` secret: the ASCII-armored private
key for the fingerprint above, without a passphrase. GitHub disables scheduled
workflows after 60 days without repository activity; re-enable **Publish** in
the Actions tab if that happens.
