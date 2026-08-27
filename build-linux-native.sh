#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# EXPERIMENTAL native Linux ELF build (Clang/GCC, no llvm-mingw/Wine). Needs
# MKW_EXPERIMENTAL_LINUX_NATIVE in runtime/CMakeLists.txt, turned on below.

# --package (or PACKAGE=1) zips a movable copy to dist/. Not self-contained -
# system shared libs (SDL3, Vulkan loader, abseil, ...) aren't bundled, see
# `ldd`. --appimage is for real self-containment.
PACKAGE="${PACKAGE:-0}"

# --appimage (or APPIMAGE=1) builds a self-contained .AppImage to dist/ via
# linuxdeploy, fetched into .toolchain/ on first use.
APPIMAGE="${APPIMAGE:-0}"

# --retro (or RETRO=1) also builds Retro Rewind; see build.sh for RETRO_ROOT.
# Shares generated/build_shards/ and build/mods/retro_rewind_full_cpp/ with
# build.sh (ELF vs COFF assembly) - re-run whichever script you trust last.
RETRO="${RETRO:-0}"
RETRO_SKIP_WFC="${RETRO_SKIP_WFC:-0}"
for arg in "$@"; do
    case "$arg" in
        --retro) RETRO=1 ;;
        --retro-skip-wfc) RETRO=1; RETRO_SKIP_WFC=1 ;;
        --package) PACKAGE=1 ;;
        --appimage) APPIMAGE=1 ;;
    esac
done
RETRO_ROOT="${RETRO_ROOT:-$(pwd)/PulsarPacks/completed/RetroRewind/RetroRewind6}"
RETRO_OUT="build/mods/retro_rewind_full_cpp"

BUILD_DIR="${BUILD_DIR:-linux-native-build}"
PROJECT_MANIFEST="projects/mkwii/recomp.yml"
TRANSLATOR_DLL="translator/src/Translator.Cli/bin/Release/net8.0/Translator.Cli.dll"

EXPECTED_DOL_SHA256="80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05"
EXPECTED_REL_SHA256="16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d"

verify_sha256() {
    [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

have_assets() {
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256" && verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"
}

have_extracted_data() {
    [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]
}

NODTOOL_VERSION="${NODTOOL_VERSION:-v2.0.0-alpha.10}"
NODTOOL_DIR="${NODTOOL_DIR:-$(pwd)/.toolchain/nodtool}"

# Resolve `nodtool` (encounter/nod, MIT/Apache-2.0) for Wii disc extraction.
# Prefers $NODTOOL or one on PATH, else downloads the pinned prebuilt into
# .toolchain/ once. Sets $NODTOOL on success; non-zero if it can't be had.
ensure_nodtool() {
    if [ -n "${NODTOOL:-}" ] && [ -x "${NODTOOL:-}" ]; then return 0; fi
    if command -v nodtool >/dev/null 2>&1; then NODTOOL="$(command -v nodtool)"; return 0; fi
    local asset
    case "$(uname -m)" in
        x86_64|amd64)  asset="nodtool-linux-x86_64" ;;
        aarch64|arm64) asset="nodtool-linux-aarch64" ;;
        i686|i386|x86) asset="nodtool-linux-i686" ;;
        *) echo "error: no prebuilt nodtool for $(uname -m); install nodtool and set NODTOOL" >&2; return 1 ;;
    esac
    NODTOOL="$NODTOOL_DIR/$asset"
    if [ ! -x "$NODTOOL" ]; then
        echo "==> fetching nodtool $NODTOOL_VERSION into $NODTOOL_DIR (first disc extract only)" >&2
        mkdir -p "$NODTOOL_DIR"
        if ! curl -fL -o "$NODTOOL.tmp" \
            "https://github.com/encounter/nod/releases/download/$NODTOOL_VERSION/$asset"; then
            rm -f "$NODTOOL.tmp"; echo "error: could not download nodtool" >&2; return 1
        fi
        chmod +x "$NODTOOL.tmp"
        mv -f "$NODTOOL.tmp" "$NODTOOL"
    fi
}

# Auto-extract from a local disc image, same as build.sh.
if ! have_assets || { { [ "$PACKAGE" = "1" ] || [ "$APPIMAGE" = "1" ]; } && ! have_extracted_data; }; then
    if [ -z "${GAME_IMAGE:-}" ]; then
        shopt -s nullglob nocaseglob
        candidates=(*.wbfs *.iso *.gcm *.gcz *.ciso *.wia *.rvz)
        shopt -u nullglob nocaseglob
        if [ "${#candidates[@]}" -eq 1 ]; then
            GAME_IMAGE="${candidates[0]}"
        elif [ "${#candidates[@]}" -gt 1 ]; then
            echo "error: multiple disc images found at the repo root; set GAME_IMAGE=path/to/image" >&2
            printf '  - %s\n' "${candidates[@]}" >&2
            exit 1
        fi
    fi

    if [ -n "${GAME_IMAGE:-}" ] && ensure_nodtool; then
        if ! verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" ||
           ! verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            echo "==> extracting $GAME_IMAGE (this only needs to happen once)"
            rm -rf extracted
            "$NODTOOL" extract "$GAME_IMAGE" extracted/DATA -q
        fi
        if verify_sha256 "extracted/DATA/sys/main.dol" "$EXPECTED_DOL_SHA256" &&
           verify_sha256 "extracted/DATA/files/rel/StaticR.rel" "$EXPECTED_REL_SHA256"; then
            mkdir -p Assets
            cp -f extracted/DATA/sys/main.dol Assets/main.dol
            cp -f extracted/DATA/files/rel/StaticR.rel Assets/StaticR.rel
        else
            echo "error: $GAME_IMAGE did not produce a clean PAL RMCP01 main.dol/StaticR.rel (wrong region/revision?)" >&2
        fi
    fi
fi

if ! have_assets; then
    echo "error: missing game files under Assets/" >&2
    verify_sha256 "Assets/main.dol" "$EXPECTED_DOL_SHA256"     || echo "  - Assets/main.dol     (expected sha256 $EXPECTED_DOL_SHA256)" >&2
    verify_sha256 "Assets/StaticR.rel" "$EXPECTED_REL_SHA256"  || echo "  - Assets/StaticR.rel  (expected sha256 $EXPECTED_REL_SHA256)" >&2
    echo "" >&2
    echo "place a clean PAL RMCP01 disc image (ISO/WBFS/RVZ/...) at the repo root and re-run" >&2
    echo "(nodtool is fetched automatically), or extract it yourself:" >&2
    echo "  nodtool extract your-game.iso ./extracted/DATA" >&2
    echo "then copy extracted/DATA/sys/main.dol and extracted/DATA/files/rel/StaticR.rel into Assets/" >&2
    exit 1
fi

# Clang is what this port's been tested with; GCC is allowed but untested.
CXX_COMPILER="${CXX:-}"
if [ -z "$CXX_COMPILER" ]; then
    if command -v clang++ >/dev/null 2>&1; then
        CXX_COMPILER="clang++"
    elif command -v g++ >/dev/null 2>&1; then
        echo "warning: clang++ not found, falling back to g++ (untested for this target)" >&2
        CXX_COMPILER="g++"
    else
        echo "error: no clang++ or g++ found on PATH; set CXX=/path/to/compiler" >&2
        exit 1
    fi
fi
C_COMPILER="${CC:-}"
if [ -z "$C_COMPILER" ]; then
    if command -v clang >/dev/null 2>&1; then
        C_COMPILER="clang"
    elif command -v gcc >/dev/null 2>&1; then
        C_COMPILER="gcc"
    else
        echo "error: no clang or gcc found on PATH; set CC=/path/to/compiler" >&2
        exit 1
    fi
fi

# Build the translator CLI once if it hasn't been built yet.
if [ ! -f "$TRANSLATOR_DLL" ]; then
    echo "==> building translator"
    dotnet build translator/src/Translator.Cli/Translator.Cli.csproj -c Release
fi

PUL_SHA=""
if [ "$RETRO" = "1" ]; then
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        # The FULL pack (<version>-full2.zip on the CDN), not
        # update.rwfc.net/.../RetroRewind.zip - that one is the in-game
        # updater's incremental bundle and omits menu/UI archives an existing
        # install already has, so Retro Rewind's pause menu ends up missing
        # pages (page 0x19 -> null -> Page::Activate(null) crash). Set
        # RETRO_FULL_ZIP_URL to override.
        if [ -z "${RETRO_FULL_ZIP_URL:-}" ]; then
            rr_version="$(curl -fsSL "https://update.rwfc.net/RetroRewind/RetroRewindVersion.txt" \
                | grep -oE '^[0-9]+(\.[0-9]+)+' | tail -n1)"
            [ -n "$rr_version" ] || { echo "error: could not determine the latest Retro Rewind version" >&2; exit 1; }
            RETRO_FULL_ZIP_URL="https://cdn.update.rwfc.net/RetroRewind/zip/${rr_version}-full2.zip"
        fi
        echo "==> $RETRO_ROOT is missing Binaries/Code.pul; downloading the full Retro Rewind pack"
        echo "    $RETRO_FULL_ZIP_URL"
        tmp_archive="$(mktemp --suffix=.zip)"
        tmp_extract="$(mktemp -d)"
        curl -fL -o "$tmp_archive" "$RETRO_FULL_ZIP_URL"
        unzip -q "$tmp_archive" "RetroRewind6/*" -d "$tmp_extract"
        rm -f "$tmp_archive"
        if [ ! -f "$tmp_extract/RetroRewind6/Binaries/Code.pul" ]; then
            echo "error: downloaded Retro Rewind archive did not contain RetroRewind6/Binaries/Code.pul" >&2
            rm -rf "$tmp_extract"
            exit 1
        fi
        # This branch only runs when RETRO_ROOT has no Code.pul, i.e. it is
        # missing or a stale partial tree - replace it wholesale so leftovers
        # from an old incremental RetroRewind.zip can't shadow the full pack.
        rm -rf "$RETRO_ROOT"
        mkdir -p "$(dirname "$RETRO_ROOT")"
        cp -r "$tmp_extract/RetroRewind6" "$RETRO_ROOT"
        rm -rf "$tmp_extract"
    fi
    if [ ! -f "$RETRO_ROOT/Binaries/Code.pul" ]; then
        echo "error: --retro needs a Retro Rewind install with Binaries/Code.pul" >&2
        echo "  place your RetroRewind6 folder at $RETRO_ROOT" >&2
        echo "  or point RETRO_ROOT at an existing one: RETRO_ROOT=/path/to/RetroRewind6 ./build-linux-native.sh --retro" >&2
        exit 1
    fi
    # The manifest's retro-rewind profile always reads Code.pul from here.
    STAGED_PUL="PulsarPacks/completed/RetroRewind/RetroRewind6/Binaries/Code.pul"
    if [ "$(readlink -f "$RETRO_ROOT/Binaries/Code.pul")" != "$(readlink -f "$STAGED_PUL" 2>/dev/null || true)" ]; then
        mkdir -p "$(dirname "$STAGED_PUL")"
        cp -f "$RETRO_ROOT/Binaries/Code.pul" "$STAGED_PUL"
    fi
    PUL_SHA=$(sha256sum "$RETRO_ROOT/Binaries/Code.pul" | cut -d' ' -f1)
fi

# Translate once (or retranslate if this Code.pul is newer); output is
# portable C++ shared with the mingw build.
NEED_BASE_TRANSLATE=0
if [ ! -f "generated/base_translation_output.json" ]; then
    NEED_BASE_TRANSLATE=1
elif [ "$RETRO" = "1" ] && ! grep -q "\"codePulSha256\":\"$PUL_SHA\"" generated/base_translation_output.json; then
    echo "==> base translation predates this Code.pul; retranslating"
    NEED_BASE_TRANSLATE=1
fi

if [ "$NEED_BASE_TRANSLATE" = "1" ]; then
    echo "==> translating Assets/main.dol"
    entry_addr=$(grep -A1 '^\s*entry_points:' "$PROJECT_MANIFEST" | tail -n1 | grep -oE '0x[0-9A-Fa-f]+')
    dotnet "$TRANSLATOR_DLL" translate-recursive "$entry_addr" --project "$PROJECT_MANIFEST" \
        --output-metadata generated/base_translation_output.json \
        --production-source-bundle generated/base_translation_sources.bin
fi

# ELF section syntax for the embedded-data assembly (COFF on the mingw
# build). Always regenerated (cheap).
echo "==> generating data section init (ELF)"
MKW_ASM_OBJECT_FORMAT=elf dotnet "$TRANSLATOR_DLL" generate-data-init --project "$PROJECT_MANIFEST"

if [ "$RETRO" = "1" ]; then
    mkdir -p build/base
    # Must pass --translation-output-metadata: without it the base manifest is
    # written with zero function ranges, and translate-mod then builds Retro
    # Rewind's dispatch/page tables against an empty base - the pause menu ends
    # up resolving a page index to a garbage pointer and crashes on Activate.
    # Regenerated every run (cheap) so a stale/empty manifest can't linger.
    dotnet "$TRANSLATOR_DLL" emit-base-manifest --project "$PROJECT_MANIFEST" \
        --translation-output-metadata generated/base_translation_output.json \
        --region P
    echo "==> translating Retro Rewind Code.pul"
    retro_mod_args=(translate-mod --project "$PROJECT_MANIFEST" --profile retro-rewind
        --base-manifest build/base/mkwii_base_manifest.json
        --base-translation-output-metadata generated/base_translation_output.json
        --code-pul "$RETRO_ROOT/Binaries/Code.pul" --mod-root "$RETRO_ROOT" --mod-name "Retro Rewind"
        --region P --out "$RETRO_OUT" --emit-cpp)
    if [ "$RETRO_SKIP_WFC" = "1" ]; then
        retro_mod_args+=(--skip-retro-wfc)
    fi
    MKW_ASM_OBJECT_FORMAT=elf dotnet "$TRANSLATOR_DLL" "${retro_mod_args[@]}"
fi

NEED_SHARDS=0
if [ ! -f "generated/build_shards/shards.cmake" ]; then
    NEED_SHARDS=1
elif [ "$RETRO" = "1" ] && ! grep -q "MKW_HAVE_RETRO_REWIND_SHARDS ON" generated/build_shards/shards.cmake; then
    NEED_SHARDS=1
fi

if [ "$NEED_SHARDS" = "1" ]; then
    shard_args=(emit-build-shards --project "$PROJECT_MANIFEST")
    if [ "$RETRO" = "1" ]; then
        shard_args+=(--resolved-profile "$RETRO_OUT/resolved_dispatch_profile.json" --retro-cpp-dir "$RETRO_OUT/cpp")
    fi
    dotnet "$TRANSLATOR_DLL" "${shard_args[@]}"
fi

cmake -S runtime -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$C_COMPILER" \
    -DCMAKE_CXX_COMPILER="$CXX_COMPILER" \
    -DMKW_EXPERIMENTAL_LINUX_NATIVE=ON

cmake --build "$BUILD_DIR"

# Portable config next to the binary, same as build.sh.
touch "$BUILD_DIR/portable.txt"
mkdir -p "$BUILD_DIR/UserData"
CONFIG_FILE="$BUILD_DIR/UserData/Config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    dvd_root_line='# dvd_root = "/path/to/MarioKartWii/DATA"'
    if [ -d "extracted/DATA/sys" ] && [ -d "extracted/DATA/files" ]; then
        dvd_root_line="dvd_root = \"$(realpath --relative-to="$BUILD_DIR/UserData" "extracted/DATA")\""
    fi
    cat > "$CONFIG_FILE" <<EOF_CONFIG
# WiiCompiled user configuration (generated by build-linux-native.sh; portable mode)
# Set paths.dvd_root to an extracted Mario Kart Wii DATA directory.

[video]
widescreen = true
resolution_multiplier = 1.0
frame_interpolation_fps = 0
display_mode = "windowed"
graphics_api = "auto"
skip_unready_pipelines = true
disable_copy_filter = true
show_fps = true
texture_replacements = false
texture_dumps = false

[audio]
volume = 1.0
music_volume = 1.0
sound_effects_volume = 1.0
ui_volume = 1.0
voices_volume = 1.0
muted = false
attenuate_music_when_media_plays = false
mix_worker = true

[network]
enabled = true

[paths]
$dvd_root_line
# nand_root = "/path/to/WiiNand"
EOF_CONFIG
    echo "==> wrote portable config: $CONFIG_FILE"
fi

if [ "$RETRO" = "1" ] && ! grep -q '^retro_rewind_root' "$CONFIG_FILE"; then
    retro_root_value="$(realpath --relative-to="$BUILD_DIR/UserData" "$RETRO_ROOT")"
    sed -i "/^\[paths\]/a retro_rewind_root = \"$retro_root_value\"" "$CONFIG_FILE"
    echo "==> set retro_rewind_root in $CONFIG_FILE"
fi

if [ "$PACKAGE" = "1" ] || [ "$APPIMAGE" = "1" ]; then
    if [ ! -d "extracted/DATA/sys" ] || [ ! -d "extracted/DATA/files" ]; then
        echo "error: --package/--appimage need extracted/DATA, which isn't there yet." >&2
        echo "" >&2
        echo "This is your own disc's filesystem (game files, not this project's - see the README's" >&2
        echo "note on that), extracted once so it can be bundled into a movable copy:" >&2
        echo "  1. place a clean PAL RMCP01 disc image (ISO/WBFS/GCZ/CISO/WIA/RVZ) at the repo root" >&2
        echo "  2. re-run this script with the same flags (nodtool is fetched automatically)" >&2
        echo "" >&2
        echo "or extract it yourself:" >&2
        echo "  Dolphin: right-click the game -> Properties -> Filesystem -> Extract Entire Disc" >&2
        echo "           -> point the destination at extracted/DATA" >&2
        echo "  nodtool CLI: nodtool extract your-game.iso ./extracted/DATA" >&2
        echo "then re-run this script with the same flags" >&2
        exit 1
    fi

    # Staged once; --package zips it, --appimage drops it into an AppDir.
    STAGE_DIR="dist/.stage-WiiCompiled-linux"
    echo ""
    echo "==> staging a movable copy at $STAGE_DIR (this could take a while)"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR/UserData"
    cp -f "$BUILD_DIR/WiiCompiled" "$BUILD_DIR/dsp_coef.bin" "$BUILD_DIR/initial_pipeline_cache.db" "$STAGE_DIR/"
    if [ "$RETRO" = "1" ]; then
        cp -f "$BUILD_DIR/RetroRewind" "$STAGE_DIR/"
    fi
    cp -r "$BUILD_DIR/wii_bootstrap" "$STAGE_DIR/wii_bootstrap"
    touch "$STAGE_DIR/portable.txt"
    cp -r "extracted/DATA" "$STAGE_DIR/DATA"

    stage_paths=('dvd_root = "../DATA"')
    if [ "$RETRO" = "1" ]; then
        echo "==> copying RetroRewind6 ($(du -sh "$RETRO_ROOT" | cut -f1))"
        cp -r "$RETRO_ROOT" "$STAGE_DIR/RetroRewind6"
        stage_paths+=('retro_rewind_root = "../RetroRewind6"')
    fi
    sed "/^\[paths\]/,\$d" "$CONFIG_FILE" > "$STAGE_DIR/UserData/Config.toml"
    { echo "[paths]"; printf '%s\n' "${stage_paths[@]}"; } >> "$STAGE_DIR/UserData/Config.toml"

    if [ "$PACKAGE" = "1" ]; then
        echo "==> zipping $STAGE_DIR"
        rm -rf "dist/WiiCompiled-linux"
        cp -r "$STAGE_DIR" "dist/WiiCompiled-linux"
        rm -f "dist/WiiCompiled-linux.zip"
        (cd dist && zip -rq -1 "WiiCompiled-linux.zip" "WiiCompiled-linux")
        rm -rf "dist/WiiCompiled-linux"
        echo "==> packaged: dist/WiiCompiled-linux.zip ($(du -sh dist/WiiCompiled-linux.zip | cut -f1))"
    fi

    if [ "$APPIMAGE" = "1" ]; then
        echo ""
        echo "==> building AppImage(s)"

        # Bundles the shared libs --package leaves out; fetched once into
        # .toolchain/, same pattern as build.sh's llvm-mingw/cppwinrt.
        LINUXDEPLOY_DIR="$(pwd)/.toolchain/linuxdeploy"
        LINUXDEPLOY="$LINUXDEPLOY_DIR/linuxdeploy-x86_64.AppImage"
        LINUXDEPLOY_PLUGIN="$LINUXDEPLOY_DIR/linuxdeploy-plugin-appimage-x86_64.AppImage"
        if [ ! -x "$LINUXDEPLOY" ] || [ ! -x "$LINUXDEPLOY_PLUGIN" ]; then
            echo "==> fetching linuxdeploy into $LINUXDEPLOY_DIR (first --appimage build only)"
            mkdir -p "$LINUXDEPLOY_DIR"
            curl -L -o "$LINUXDEPLOY" "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
            curl -L -o "$LINUXDEPLOY_PLUGIN" "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage"
            chmod +x "$LINUXDEPLOY" "$LINUXDEPLOY_PLUGIN"
        fi

        # AppImages need an icon, checked into version control at this path.
        ICON_FILE="runtime/assets/appimage/wiicompiled.png"
        if [ ! -f "$ICON_FILE" ]; then
            echo "error: --appimage needs an icon at $ICON_FILE (any size) - place one and re-run" >&2
            exit 1
        fi

        export PATH="$LINUXDEPLOY_DIR:$PATH"
        export APPIMAGE_EXTRACT_AND_RUN=1
        mkdir -p dist

        # Each AppImage gets its own fresh AppDir - sharing one between
        # WiiCompiled and RetroRewind made linuxdeploy's appimage plugin pick
        # the wrong output name and clobber the first build.
        #
        # $1=output name, $2=binary to run, $3=desktop Name=.
        build_appimage() {
            local out_name="$1" binary="$2" human_name="$3"
            local appdir="dist/.stage-AppDir-$out_name"
            rm -rf "$appdir"
            mkdir -p "$appdir/usr/bin"
            cp -r "$STAGE_DIR/." "$appdir/usr/bin/"
            # Skip portable.txt: it'd put UserData/ (Cache/, saves, NAND)
            # inside the read-only squashfs mount. AppRun below redirects
            # writes to $HOME instead.
            rm -f "$appdir/usr/bin/portable.txt"

            # $HERE is only stable for this run (fresh mount dir each
            # launch), so [paths] gets rewritten every time instead of baked
            # in at build time. ApplicationDataDirectory() is $DATA_HOME
            # itself here - no UserData/ nesting.
            cat > "$appdir/AppRun" <<EOF_APPRUN
#!/bin/sh
set -eu
HERE="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
DATA_HOME="\${XDG_DATA_HOME:-\$HOME/.local/share}/WiiCompiled"
mkdir -p "\$DATA_HOME"
CONFIG="\$DATA_HOME/Config.toml"
if [ ! -f "\$CONFIG" ]; then
    cp "\$HERE/usr/bin/UserData/Config.toml" "\$CONFIG"
fi
sed -i '/^\[paths\]/,\$d' "\$CONFIG"
{
    echo "[paths]"
    echo "dvd_root = \"\$HERE/usr/bin/DATA\""
EOF_APPRUN
            if [ "$RETRO" = "1" ]; then
                cat >> "$appdir/AppRun" <<'EOF_APPRUN'
    echo "retro_rewind_root = \"$DATA_HOME/sdroot/RetroRewind6\""
EOF_APPRUN
            fi
            cat >> "$appdir/AppRun" <<EOF_APPRUN
} >> "\$CONFIG"
EOF_APPRUN
            if [ "$RETRO" = "1" ]; then
                # Retro Rewind saves next to retro_rewind_root's *parent*,
                # not inside RetroRewind6/ itself. A plain symlink for
                # RetroRewind6 gets resolved back to the read-only mount by
                # weakly_canonical() (riivolution.cpp), so RetroRewind6/
                # itself must be a real directory - one level of symlinks
                # into the mount is enough.
                cat >> "$appdir/AppRun" <<'EOF_APPRUN'
mkdir -p "$DATA_HOME/sdroot/RetroRewind6"
for entry in "$HERE"/usr/bin/RetroRewind6/* "$HERE"/usr/bin/RetroRewind6/.[!.]*; do
    [ -e "$entry" ] || continue
    ln -sfn "$entry" "$DATA_HOME/sdroot/RetroRewind6/$(basename "$entry")"
done
EOF_APPRUN
            fi
            cat >> "$appdir/AppRun" <<EOF_APPRUN
exec "\$HERE/usr/bin/$binary" "\$@"
EOF_APPRUN
            chmod +x "$appdir/AppRun"

            cat > "$appdir/$out_name.desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=$human_name
Comment=Statically recompiled Mario Kart Wii
Exec=$binary
Icon=wiicompiled
Categories=Game;
Terminal=false
EOF_DESKTOP

            rm -f ./*.AppImage
            "$LINUXDEPLOY" --appdir "$appdir" --executable "$appdir/usr/bin/$binary" \
                --desktop-file "$appdir/$out_name.desktop" --icon-file "$ICON_FILE" --output appimage
            mv -f ./*.AppImage "dist/$out_name-linux-x86_64.AppImage"
            rm -rf "$appdir"
            echo "==> packaged: dist/$out_name-linux-x86_64.AppImage ($(du -sh "dist/$out_name-linux-x86_64.AppImage" | cut -f1))"
        }

        build_appimage WiiCompiled WiiCompiled "WiiCompiled"
        if [ "$RETRO" = "1" ]; then
            build_appimage RetroRewind RetroRewind "WiiCompiled Retro Rewind"
        fi
    fi

    rm -rf "$STAGE_DIR"
fi

echo ""
echo "Build complete! Find it at $BUILD_DIR/WiiCompiled"
if [ "$RETRO" = "1" ]; then
    echo "Retro Rewind build at $BUILD_DIR/RetroRewind"
fi
echo ""
echo "EXPERIMENTAL native Linux build - not the shipped/supported path (build.sh"
echo "produces that)."

if [ "$APPIMAGE" = "1" ]; then
    echo ""
    echo "To play: chmod +x dist/WiiCompiled-linux-x86_64.AppImage and run it, anywhere."
    echo "Game data and shared libraries are both bundled - nothing else to install."
    if [ "$RETRO" = "1" ]; then
        echo "Retro Rewind: dist/RetroRewind-linux-x86_64.AppImage, same way."
    fi
elif [ "$PACKAGE" = "1" ]; then
    echo ""
    echo "To play: unzip dist/WiiCompiled-linux.zip anywhere and run ./WiiCompiled inside it."
    echo "Your extracted game data is already bundled (UserData/Config.toml's dvd_root points at"
    echo "the DATA/ folder next to the binary). NOT bundled: the shared libraries it dynamically"
    echo "links (SDL3, the Vulkan loader, abseil, libpng, zlib, ...) - run 'ldd WiiCompiled' to see"
    echo "the full list, and install whichever your target machine is missing."
else
    echo ""
    echo "To play: run $BUILD_DIR/WiiCompiled as-is. If you move it, take the whole $BUILD_DIR/"
    echo "folder with it (wii_bootstrap/, dsp_coef.bin, initial_pipeline_cache.db,"
    echo "UserData/Config.toml) plus whatever game data/mod folders Config.toml points at."
    echo "Re-run with --package for a movable copy instead."
fi
