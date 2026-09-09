#!/usr/bin/env bash
set -euo pipefail

# Install Pixel Quest from this source checkout. Run: sudo ./install.sh
#
# Application files are replaceable; configuration and console data are not.
# Re-running the installer updates /opt while leaving /etc and /var/lib intact.

APPLICATION_DIR=/opt/pixelquest
CONFIG_DIR=/etc/pixelquest
DATA_DIR=/var/lib/pixelquest
CACHE_DIR=/var/cache/pixelquest
LOG_DIR=/var/log/pixelquest
SERVICE_USER=pixelquest
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMMAND_LINK=/usr/local/bin/pixelquest
FORCE_CORES=false

# Increment this whenever a build input or command changes.  The value is stored
# with the core manifest so an older, verified build cannot be reused by mistake.
CORE_RECIPE=1
CORE_BUILD_DIR=""
CORE_STATUS=""

# Each entry is: name | repository | commit | source directory | Makefile | library.
# Cores are built from these pinned revisions and copied into the application.
CORES=(
    "stella2014|https://github.com/libretro/stella2014-libretro.git|7d1361e407e63f29e52892655069e5fb4096e691|.|Makefile|stella2014_libretro.so"
    "nestopia|https://github.com/libretro/nestopia.git|0a46d231849ecfa3d777b6bf9107d57ce82452cb|libretro|Makefile|nestopia_libretro.so"
    "genesis-plus-gx|https://github.com/libretro/Genesis-Plus-GX.git|a7985a9c4278ac352f8ca7bb4d3cc6b36e9e3e7d|.|Makefile.libretro|genesis_plus_gx_libretro.so"
    "snes9x|https://github.com/libretro/snes9x.git|890b5d445538fe790aa3add3d5702c80f551e0ae|libretro|Makefile|snes9x_libretro.so"
)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

cleanup_core_build() {
    [[ -z "$CORE_BUILD_DIR" ]] || rm -rf -- "$CORE_BUILD_DIR"
}

trap cleanup_core_build EXIT

[[ ${EUID} -eq 0 ]] || die "run as root: sudo ./install.sh"
[[ -f "$SOURCE_ROOT/bin/pixelquest-daemon" && -f "$SOURCE_ROOT/config/retroarch.cfg" ]] || \
    die "run from the Pixel Quest source checkout"

case "${1:-}" in
    "")
        ;;
    --rebuild-cores)
        FORCE_CORES=true
        ;;
    *)
        echo "usage: $0 [--rebuild-cores]" >&2
        exit 2
        ;;
esac

install_packages() {
    step "Checking system packages"

    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            git \
            build-essential \
            pkg-config \
            python3 \
            python3-libgpiod \
            retroarch \
            ca-certificates
    elif command -v pacman >/dev/null; then
        pacman -Syu --needed --noconfirm \
            git \
            base-devel \
            pkgconf \
            python \
            python-gpiod \
            retroarch \
            ca-certificates
    else
        die "install git, a C/C++ build toolchain, Python 3, and RetroArch, then run this again"
    fi
}

create_user() {
    step "Ensuring the $SERVICE_USER service account"

    if getent group "$SERVICE_USER" >/dev/null; then
        echo "    Group $SERVICE_USER already exists."
    else
        groupadd --system "$SERVICE_USER"
        echo "    Created group $SERVICE_USER."
    fi

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir "$DATA_DIR" \
            --shell /usr/sbin/nologin \
            --gid "$SERVICE_USER" \
            "$SERVICE_USER"
        echo "    Created user $SERVICE_USER."
    else
        echo "    User $SERVICE_USER already exists."
    fi

    # RetroArch needs audio, graphics, render, and input-device access.  tty1
    # remains root-only because the service's display initializer owns it.
    local device_group
    for device_group in audio video render input gpio; do
        if getent group "$device_group" >/dev/null; then
            usermod -aG "$device_group" "$SERVICE_USER"
        fi
    done
}

platform() {
    if [[ -n ${PIXELQUEST_LIBRETRO_PLATFORM:-} ]]; then
        printf '%s\n' "$PIXELQUEST_LIBRETRO_PLATFORM"
    elif [[ $(getconf LONG_BIT) == 32 ]] &&
        [[ -r /proc/device-tree/model ]] &&
        grep -aq 'Raspberry Pi 3' /proc/device-tree/model; then
        printf 'rpi3\n'
    else
        printf 'unix\n'
    fi
}

cores_current() {
    local platform_value
    local name
    local url
    local revision
    local directory
    local makefile
    local library

    # Reuse cores only when their files, build recipe, target platform, and
    # upstream pins all match.  BUILD_REVISIONS.txt records the latter three;
    # SHA256SUMS confirms the installed libraries have not changed.
    if [[ ! -f "$APPLICATION_DIR/cores/BUILD_REVISIONS.txt" ||
        ! -f "$APPLICATION_DIR/cores/SHA256SUMS" ]]; then
        CORE_STATUS="no verified core manifest is installed"
        return 1
    fi

    if ! (
        cd "$APPLICATION_DIR/cores" &&
            sha256sum --strict -c SHA256SUMS >/dev/null 2>&1
    ); then
        CORE_STATUS="the installed core checksums do not match"
        return 1
    fi

    if ! grep -Fqx \
        "recipe $CORE_RECIPE" \
        "$APPLICATION_DIR/cores/BUILD_REVISIONS.txt"; then
        CORE_STATUS="the core build recipe changed"
        return 1
    fi

    platform_value="$(platform)"
    if ! grep -Fqx \
        "platform $platform_value" \
        "$APPLICATION_DIR/cores/BUILD_REVISIONS.txt"; then
        CORE_STATUS="the installed cores target a different platform"
        return 1
    fi

    while IFS='|' read -r name url revision directory makefile library; do
        if ! grep -Fqx \
            "$name $revision $url" \
            "$APPLICATION_DIR/cores/BUILD_REVISIONS.txt"; then
            CORE_STATUS="the pinned source revision for $name changed"
            return 1
        fi
    done < <(printf '%s\n' "${CORES[@]}")

    CORE_STATUS="verified cores match recipe $CORE_RECIPE for $platform_value"
}

build_cores() {
    local platform_value
    local jobs
    local name
    local url
    local revision
    local directory
    local makefile
    local library
    local source_dir

    # Build outside /opt so a failed build cannot leave a partial installed core
    # set.  The verified output is copied into the application only at the end.
    CORE_BUILD_DIR="$(mktemp -d "$CACHE_DIR/cores.XXXXXXXX")"
    platform_value="$(platform)"
    jobs="${PIXELQUEST_BUILD_JOBS:-2}"

    [[ $jobs =~ ^[1-9][0-9]*$ ]] || \
        die "PIXELQUEST_BUILD_JOBS must be a positive integer"

    step "Building ${#CORES[@]} cores for $platform_value (jobs: $jobs)"
    mkdir -p "$CORE_BUILD_DIR/output"

    {
        printf 'recipe %s\n' "$CORE_RECIPE"
        printf 'platform %s\n' "$platform_value"
    } > "$CORE_BUILD_DIR/output/BUILD_REVISIONS.txt"

    while IFS='|' read -r name url revision directory makefile library; do
        echo "    Building $name"
        source_dir="$CORE_BUILD_DIR/$name"

        git init -q "$source_dir"
        git -C "$source_dir" remote add origin "$url"
        git -C "$source_dir" fetch -q --depth 1 origin "$revision"
        git -C "$source_dir" checkout -q --detach FETCH_HEAD
        git -C "$source_dir" submodule update --init --recursive

        make \
            -C "$source_dir/$directory" \
            -f "$makefile" \
            platform="$platform_value" \
            -j"$jobs"

        install -m 0644 \
            "$source_dir/$directory/$library" \
            "$CORE_BUILD_DIR/output/$library"
        printf '%s %s %s\n' "$name" "$revision" "$url" \
            >> "$CORE_BUILD_DIR/output/BUILD_REVISIONS.txt"
    done < <(printf '%s\n' "${CORES[@]}")

    (
        cd "$CORE_BUILD_DIR/output"
        sha256sum ./*.so > SHA256SUMS
        sha256sum --strict -c SHA256SUMS
    )

    step "Installing verified cores"
    rm -f \
        "$APPLICATION_DIR/cores"/*.so \
        "$APPLICATION_DIR/cores/SHA256SUMS" \
        "$APPLICATION_DIR/cores/BUILD_REVISIONS.txt"
    install -m 0644 "$CORE_BUILD_DIR/output"/* "$APPLICATION_DIR/cores/"
}

install_packages
create_user

step "Preparing Pixel Quest directories"
service_state="$(systemctl is-active pixelquest.service 2>/dev/null || true)"
case "$service_state" in
    active | activating | deactivating)
        step "Stopping pixelquest.service ($service_state) for update"
        systemctl stop pixelquest.service
        ;;
    *)
        echo "    Pixel Quest service is not running; nothing to stop."
        ;;
esac

# Application files are root-owned and can be replaced on every update.  Console
# state is owned by the service account and persists across updates/uninstalls.
install -d -o root -g root -m 0755 "$APPLICATION_DIR/cores" "$CONFIG_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 \
    "$CACHE_DIR" \
    "$LOG_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 \
    "$DATA_DIR" \
    "$DATA_DIR/roms" \
    "$DATA_DIR/saves" \
    "$DATA_DIR/states" \
    "$DATA_DIR/state"

for system in atari2600 nes sega snes; do
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 \
        "$DATA_DIR/roms/$system"
done

step "Installing replaceable application files"
rm -rf "$APPLICATION_DIR/bin" "$APPLICATION_DIR/retroarch"
cp -a "$SOURCE_ROOT/bin" "$APPLICATION_DIR/"
cp -a "$SOURCE_ROOT/config/retroarch" "$APPLICATION_DIR/"
chown -R root:root "$APPLICATION_DIR/bin" "$APPLICATION_DIR/retroarch"
find "$APPLICATION_DIR/bin" -type f ! -name '*.py' -exec chmod 0755 {} +

# Keep the canonical program with its release under /opt, while providing the
# ordinary command name on users' PATH without copying a version that can stale.
if [[ -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    die "refusing to replace non-symlink command: $COMMAND_LINK"
fi
ln --symbolic --force --no-dereference \
    "$APPLICATION_DIR/bin/pixelquest" \
    "$COMMAND_LINK"

# The active configuration is created only once; fresh shipped defaults are kept
# beside it so an administrator can compare them after an update.
install -m 0644 \
    "$SOURCE_ROOT/config/cartridges.json" \
    "$CONFIG_DIR/cartridges.json.default"
install -m 0644 \
    "$SOURCE_ROOT/config/cartridges.json.example" \
    "$CONFIG_DIR/cartridges.json.example"
install -m 0644 \
    "$SOURCE_ROOT/config/retroarch.cfg" \
    "$CONFIG_DIR/retroarch.cfg.default"

if [[ -e "$CONFIG_DIR/cartridges.json" ]]; then
    echo "    Preserving existing cartridge configuration."
else
    install -m 0644 \
        "$CONFIG_DIR/cartridges.json.default" \
        "$CONFIG_DIR/cartridges.json"
    echo "    Seeded cartridge configuration."
fi

if [[ -e "$CONFIG_DIR/retroarch.cfg" ]]; then
    echo "    Preserving existing RetroArch configuration."
else
    install -m 0644 \
        "$CONFIG_DIR/retroarch.cfg.default" \
        "$CONFIG_DIR/retroarch.cfg"
    echo "    Seeded RetroArch configuration."
fi

if [[ $FORCE_CORES == true ]]; then
    echo "==> Rebuilding cores because --rebuild-cores was requested."
    build_cores
elif cores_current; then
    echo "==> Reusing $CORE_STATUS."
else
    echo "==> Rebuilding cores because $CORE_STATUS."
    build_cores
fi

step "Validating installed scripts and configuration"
python3 -m py_compile \
    "$APPLICATION_DIR/bin/pixelquest" \
    "$APPLICATION_DIR/bin/pixelquest-daemon" \
    "$APPLICATION_DIR/bin/pixelquest-retroarch" \
    "$APPLICATION_DIR/bin/pixelquest_runtime.py"
python3 -m json.tool "$CONFIG_DIR/cartridges.json" >/dev/null

step "Installing the systemd service"
install -m 0644 \
    "$SOURCE_ROOT/systemd/pixelquest.service" \
    /etc/systemd/system/pixelquest.service
systemctl daemon-reload

if systemctl is-enabled --quiet pixelquest.service; then
    echo "    pixelquest.service is already enabled."
else
    echo "    Enabling pixelquest.service."
    systemctl enable pixelquest.service
fi

step "Starting pixelquest.service"
systemctl start pixelquest.service

systemctl is-active --quiet pixelquest.service || \
    die "pixelquest.service did not become active; inspect: journalctl -u pixelquest.service"

echo "    pixelquest.service is active."
echo 'Installed and running. Add ROMs under /var/lib/pixelquest/roms and use pixelquest reset to launch one.'
