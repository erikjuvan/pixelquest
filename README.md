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
/var/cache/pixelquest/       rendered RetroArch configuration, assets, downloads, and thumbnails
/var/log/pixelquest/         daemon and RetroArch logs
/run/pixelquest/             daemon socket (created by systemd)
```

The source checkout may be deleted after installation. The files in `/etc/pixelquest` are seeded only on first install; updated `.default` copies are installed alongside them for comparison on later updates. `cartridges.json.example` is an always-current copy/pasteable catalog example.

systemd runs the daemon as the unprivileged `pixelquest` user. The installer adds
that account to the available audio, video, render, input, and GPIO device groups.
Before the daemon starts, a short root-privileged display initializer clears tty1
and hides its text cursor.

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

The installer starts the service automatically. After adding the catalog entry,
use the client to insert and launch the cartridge:

```bash
pixelquest list
pixelquest insert my-game
pixelquest reset
pixelquest status
```

`insert` is a development simulation of the cartridge sensor. It records the cartridge but does not launch a game; `reset` launches the currently inserted cartridge. `remove` stops a running game. RetroArch histories, favorites, remaps, playlists, core options, screenshots, recordings, and rGUI configuration are retained under `/var/lib/pixelquest/retroarch`; only disposable assets, downloads, thumbnails, and rendered configuration use `/var/cache`.

## Monochrome

Color output is the default. `pixelquest monochrome on` creates RetroArch's
persistent global shader preset, and `pixelquest monochrome off` removes it.
Use `pixelquest monochrome status` to show the selected mode. A mode change
applies on the next reset or game launch.

Pixel Quest owns `/var/lib/pixelquest/retroarch/config/global.glslp`: no file
means color, while the canonical preset means monochrome. Unexpected contents
produce an error and are never changed implicitly. Immutable shader sources
remain with the application under `/opt/pixelquest/retroarch/shaders`.

## Reset button

Connect a normally-open reset button between BCM GPIO 26 (physical header pin 37)
and GND. Pixel Quest enables the pin's internal pull-up, so a button press pulls it
low. The daemon listens for the falling edge and ignores additional edges for 50
ms to debounce the switch.

## Uninstall

```bash
sudo ./uninstall.sh
```

Normal uninstall removes the application, cache, logs, and service but retains `/etc/pixelquest` and `/var/lib/pixelquest`. To remove all configuration, ROMs, saves, and state too:

```bash
sudo ./uninstall.sh --purge
```
