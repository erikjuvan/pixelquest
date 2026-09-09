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
RETROARCH_CONFIG_DIR = DATA_DIR / "retroarch" / "config"
GLOBAL_SHADER_PRESET = RETROARCH_CONFIG_DIR / "global.glslp"

# The global preset is both RetroArch configuration and Pixel Quest state. There
# is deliberately no separate mode flag: no file means color; the canonical file
# means monochrome. Any other content is invalid and is never changed implicitly.
PIXELQUEST_MANAGED_SETTINGS = {
    "auto_shaders_enable": "true",
    "config_save_on_exit": "false",
    "rgui_config_directory": RETROARCH_CONFIG_DIR.as_posix(),
    "video_shader": "",
    "video_shader_enable": "true",
}


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


def _monochrome_preset_content():
    shader = RESOURCE_DIR / "shaders" / "pixelquest-monochrome.glslp"
    reference = os.path.relpath(shader, GLOBAL_SHADER_PRESET.parent).replace(os.sep, "/")
    return f'#reference "{reference}"\n'


def validate_monochrome_preset():
    """Raise an error if the global preset exists but is not canonical."""
    if not GLOBAL_SHADER_PRESET.exists():
        return
    if GLOBAL_SHADER_PRESET.read_text(encoding="utf-8") != _monochrome_preset_content():
        raise ValueError(f"invalid Pixel Quest global shader preset: {GLOBAL_SHADER_PRESET}")


def monochrome_enabled():
    """Return whether monochrome is enabled."""
    validate_monochrome_preset()
    return GLOBAL_SHADER_PRESET.exists()


def set_monochrome_enabled(enabled):
    """Enable monochrome by creating the preset, or disable it by removing it."""
    GLOBAL_SHADER_PRESET.parent.mkdir(parents=True, exist_ok=True)

    if not enabled:
        GLOBAL_SHADER_PRESET.unlink(missing_ok=True)
        return

    temporary = GLOBAL_SHADER_PRESET.with_suffix(".tmp")
    try:
        temporary.write_text(_monochrome_preset_content(), encoding="utf-8")
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
    """Translate a checked-in RetroArch path to its installed location."""
    path = Path(relative_path)
    if ".." in path.parts:
        raise ValueError(f"RetroArch path escapes its installation: {relative_path}")
    if path.parts == ("config", "retroarch", "shaders"):
        return RESOURCE_DIR / "shaders"
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
        ("var", "retroarch", "assets"),
        ("var", "retroarch", "downloads"),
        ("var", "retroarch", "thumbnails"),
    ):
        return CACHE_DIR.joinpath(*path.parts[1:])
    if path.parts[:2] == ("var", "retroarch"):
        return DATA_DIR.joinpath(*path.parts[1:])
    raise ValueError(f"unknown RetroArch path: {relative_path}")


def retroarch_config():
    ensure_runtime_directories()
    validate_monochrome_preset()
    source = (CONFIG_DIR / "retroarch.cfg").read_text(encoding="utf-8")

    def expand(match):
        setting, relative_path = match.groups()
        path = runtime_path(relative_path)
        directory = path if setting in DIRECTORY_SETTINGS else path.parent
        directory.mkdir(parents=True, exist_ok=True)
        return f'{setting} = "{path.as_posix()}"'

    rendered = RELATIVE_SETTING.sub(expand, source)
    for setting, value in PIXELQUEST_MANAGED_SETTINGS.items():
        replacement = f'{setting} = "{value}"'
        pattern = rf"^[ \t]*{re.escape(setting)}[ \t]*=.*$"
        if re.search(pattern, rendered, re.MULTILINE):
            rendered = re.sub(pattern, replacement, rendered, flags=re.MULTILINE)
        else:
            rendered = rendered.rstrip("\n") + "\n" + replacement + "\n"

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
