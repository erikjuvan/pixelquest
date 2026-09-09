# Pixel Quest

Pixel Quest is a Raspberry Pi cartridge-console appliance using RetroArch and locally built libretro cores.

## Install or update

The Git checkout is source only. On the target Linux system, run:

```bash
sudo ./install.sh
```

The installer supports Debian-family distributions and Arch Linux. It installs dependencies, creates the `pixelquest` system user, builds cores, installs application files, and enables and starts the systemd service. Running it again stops the old service while files are updated, then starts the updated service.

Run the same command from a newer checkout to update the installed system. It preserves configuration and game data. Existing cores are reused when their checksums and pinned source revisions match. Force a fresh core build with:

```bash
sudo ./install.sh --rebuild-cores
```

For a memory-constrained Pi:

```bash
sudo PIXELQUEST_BUILD_JOBS=1 ./install.sh
```

Build cores on the target architecture; do not copy Pi `.so` files from another machine.

## Installed layout

```text
/opt/pixelquest/             application code, RetroArch resources, and cores
/usr/local/bin/pixelquest    command-line client symlink
/etc/pixelquest/             cartridges.json, its example/defaults, and retroarch.cfg
/var/lib/pixelquest/         ROMs, saves, states, and cartridge/display state
/var/cache/pixelquest/       rendered RetroArch configuration, downloads, and thumbnails
/var/log/pixelquest/         daemon and RetroArch logs
/run/pixelquest/             daemon socket (created by systemd)
```

The source checkout may be deleted after installation. The files in `/etc/pixelquest` are seeded only on first install; updated `.default` copies are installed alongside them for comparison on later updates. `cartridges.json.example` is an always-current copy/pasteable catalog example.

## ROMs and use

Pixel Quest does not include ROMs. Place legally obtained ROMs in
`/var/lib/pixelquest/roms/atari2600`, `nes`, `sega`, or `snes`. The default
catalog is empty, so a new console starts idle.

For example, copy an NES ROM to the console and replace the catalog with this
ready-to-paste entry. ROM paths are relative to `/var/lib/pixelquest`.

```bash
sudo install -m 0644 /path/to/MyGame.nes \
  /var/lib/pixelquest/roms/nes/MyGame.nes

sudo tee /etc/pixelquest/cartridges.json >/dev/null <<'JSON'
{
    "my-game": {
        "name": "My Game",
        "system": "nes",
        "rom": "roms/nes/MyGame.nes"
    }
}
JSON
```

The same entry is available at `/etc/pixelquest/cartridges.json.example`; copy
it over the active catalog and edit it if you prefer:

```bash
sudo cp /etc/pixelquest/cartridges.json.example \
  /etc/pixelquest/cartridges.json
sudoedit /etc/pixelquest/cartridges.json
```

```bash
sudo systemctl start pixelquest.service
pixelquest list
pixelquest insert my-game
pixelquest reset
pixelquest status
```

`insert` is a development simulation of the cartridge sensor. It records the cartridge but does not launch a game; `reset` launches the currently inserted cartridge. `remove` stops a running game. RetroArch histories, favorites, remaps, playlists, core options, screenshots, recordings, and rGUI configuration are retained under `/var/lib/pixelquest/retroarch`; only disposable downloads, thumbnails, and rendered configuration use `/var/cache`.

The service runs as the `pixelquest` user and joins normal Pi audio, video, render, and input groups when they exist. Its display initializer runs with the systemd privilege needed to clear tty1 before the daemon begins.

## Uninstall

```bash
sudo ./uninstall.sh
```

Normal uninstall removes the application, cache, logs, and service but retains `/etc/pixelquest` and `/var/lib/pixelquest`. To remove all configuration, ROMs, saves, and state too:

```bash
sudo ./uninstall.sh --purge
```
