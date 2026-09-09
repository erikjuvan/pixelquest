"""Filesystem paths and RetroArch configuration for an installed Pixel Quest."""

import os
import re
import tempfile
from pathlib import Path

# Application files are replaceable; configuration and console state survive an
# update or normal uninstall. Generated files remain in the standard cache,
# log, and runtime locations.
APP_DIR = Path("/opt/pixelquest")
CONFIG_DIR = Path("/etc/pixelquest")
DATA_DIR = Path("/var/lib/pixelquest")
CACHE_DIR = Path("/var/cache/pixelquest")
LOG_DIR = Path("/var/log/pixelquest")
RUN_DIR = Path("/run/pixelquest")
CORE_DIR = APP_DIR / "cores"
RESOURCE_DIR = APP_DIR / "retroarch"
SOCKET_FILE = RUN_DIR / "pixelquest.sock"
LOG_FILE = LOG_DIR / "daemon.log"
CARTRIDGE_FILE = DATA_DIR / "state" / "cartridge-present"
MONOCHROME_MODE_FILE = DATA_DIR / "state" / "monochrome-mode"
GLOBAL_SHADER_PRESET = CACHE_DIR / "retroarch" / "config" / "global.glslp"


def ensure_runtime_directories():
    directories = (
        RUN_DIR,
        LOG_DIR,
        DATA_DIR / "state",
        DATA_DIR / "retroarch",
        CACHE_DIR / "retroarch",
        DATA_DIR / "saves",
        DATA_DIR / "states",
    )

    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True)


def monochrome_mode():
    try:
        mode = MONOCHROME_MODE_FILE.read_text(encoding="utf-8").strip().lower()
    except FileNotFoundError:
        return "off"
    if mode not in ("on", "off"):
        raise ValueError(f"invalid monochrome mode: {mode!r}")
    return mode


def sync_monochrome_preset():
    if monochrome_mode() == "off":
        GLOBAL_SHADER_PRESET.unlink(missing_ok=True)
        return

    GLOBAL_SHADER_PRESET.parent.mkdir(parents=True, exist_ok=True)
    shader = RESOURCE_DIR / "shaders" / "pixelquest-monochrome.glslp"
    reference = os.path.relpath(
        shader,
        GLOBAL_SHADER_PRESET.parent,
    ).replace(os.sep, "/")
    temporary = GLOBAL_SHADER_PRESET.with_suffix(".tmp")
    try:
        temporary.write_text(f'#reference "{reference}"\n', encoding="utf-8")
        os.replace(temporary, GLOBAL_SHADER_PRESET)
    finally:
        temporary.unlink(missing_ok=True)


RELATIVE_SETTING = re.compile(r'^[ \t]*(\w+)[ \t]*=[ \t]*"\./([^"\n]+)"', re.MULTILINE)
DIRECTORY_SETTINGS = {
    "assets_directory",
    "audio_filter_dir",
    "cheat_database_path",
    "content_database_path",
    "core_assets_directory",
    "input_remapping_directory",
    "joypad_autoconfig_dir",
    "libretro_directory",
    "libretro_info_path",
    "log_dir",
    "osk_overlay_directory",
    "overlay_directory",
    "playlist_directory",
    "recording_config_directory",
    "recording_output_directory",
    "rgui_config_directory",
    "runtime_log_directory",
    "savefile_directory",
    "savestate_directory",
    "screenshot_directory",
    "system_directory",
    "thumbnails_directory",
    "video_filter_dir",
    "video_shader_dir",
}


def runtime_path(relative_path):
    """Translate the few path prefixes used in the checked-in RetroArch config."""
    path = Path(relative_path)
    if ".." in path.parts:
        raise ValueError(f"RetroArch path escapes its installation: {relative_path}")
    if path.parts[:2] == ("config", "retroarch"):
        return RESOURCE_DIR.joinpath(*path.parts[2:])
    if path.parts[:1] == ("cores",):
        return CORE_DIR.joinpath(*path.parts[1:])
    if path.parts[:2] == ("var", "saves") or path.parts[:2] == (
        "var",
        "states",
    ):
        return DATA_DIR.joinpath(*path.parts[1:])
    if path.parts[:2] == ("var", "log"):
        return LOG_DIR.joinpath(*path.parts[2:])
    if path.parts[:3] in (
        ("var", "retroarch", "downloads"),
        ("var", "retroarch", "thumbnails"),
    ):
        return CACHE_DIR.joinpath(*path.parts[1:])
    if path.parts[:2] == ("var", "retroarch"):
        return DATA_DIR.joinpath(*path.parts[1:])
    raise ValueError(f"unknown RetroArch path: {relative_path}")


def retroarch_config():
    ensure_runtime_directories()
    sync_monochrome_preset()
    source = (CONFIG_DIR / "retroarch.cfg").read_text(encoding="utf-8")

    def expand(match):
        setting, relative_path = match.groups()
        path = runtime_path(relative_path)
        directory = path if setting in DIRECTORY_SETTINGS else path.parent
        directory.mkdir(parents=True, exist_ok=True)
        return f'{setting} = "{path.as_posix()}"'

    rendered = RELATIVE_SETTING.sub(expand, source)
    rendered = re.sub(
        r"^[ \t]*config_save_on_exit[ \t]*=.*$",
        'config_save_on_exit = "false"',
        rendered,
        flags=re.MULTILINE,
    )
    if not re.search(r"^[ \t]*config_save_on_exit[ \t]*=", rendered, re.MULTILINE):
        rendered += '\nconfig_save_on_exit = "false"\n'

    target = CACHE_DIR / "retroarch" / "retroarch-runtime.cfg"
    target.parent.mkdir(parents=True, exist_ok=True)

    # Readers see a complete config even if writing is interrupted.
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=target.parent,
            prefix="retroarch-",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            temporary_file.write(rendered)

        os.replace(temporary_path, target)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

    return target
