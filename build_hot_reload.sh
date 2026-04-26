#!/bin/bash
set -e

mkdir -p build/hot_reload

# Build game as shared library (.so)
# -extra-linker-flags: keep raylib symbols unresolved in .so so launcher owns them
odin build game \
    -build-mode:shared \
    -out:build/hot_reload/game.so \
    -extra-linker-flags:"-Wl,--unresolved-symbols=ignore-all"

echo "Game DLL built: build/hot_reload/game.so"

# Build launcher (only if not already running)
if [ ! -f "waveviz" ] || [ "main_hot_reload/main_hot_reload.odin" -nt "waveviz" ]; then
    ODIN_ROOT=$(odin root)
    odin build main_hot_reload \
        -out:waveviz \
        -extra-linker-flags:"-L${ODIN_ROOT}/vendor/raylib/linux -lraylib -lGL -lm -lpthread -ldl -Wl,-rpath,${ODIN_ROOT}/vendor/raylib/linux"
    echo "Launcher built: waveviz"
fi

echo "Done. Run: ./waveviz <track1.wav> <track2.wav> <track3.wav> <track4.wav>"
echo "Press F5 in-game to hot reload after rebuilding the DLL."
