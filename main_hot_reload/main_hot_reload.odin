package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

GAME_DLL_DIR  :: "build/hot_reload/"
GAME_DLL_PATH :: GAME_DLL_DIR + "game.so"

Game_API :: struct {
    lib:             dynlib.Library,
    init_window:     proc(),
    init:            proc(argc: int, argv: [^]cstring),
    update:          proc(),
    should_run:      proc() -> bool,
    shutdown:        proc(),
    shutdown_window: proc(),
    memory:          proc() -> rawptr,
    memory_size:     proc() -> int,
    hot_reloaded:    proc(mem: rawptr),
    force_reload:    proc() -> bool,
    force_restart:   proc() -> bool,
    modification_time: time.Time,
    api_version:     int,
}

load_game_api :: proc(api_version: int) -> (api: Game_API, ok: bool) {
    mod_time, err := os.last_write_time_by_name(GAME_DLL_PATH)
    if err != os.ERROR_NONE {
        fmt.println("Cannot stat", GAME_DLL_PATH)
        return
    }

    versioned := fmt.tprintf(GAME_DLL_DIR + "game_{}.so", api_version)
    copy_err  := os.copy_file(versioned, GAME_DLL_PATH)
    if copy_err != nil {
        fmt.println("Failed to copy DLL:", copy_err)
        return
    }

    _, ok = dynlib.initialize_symbols(&api, versioned, "game_", "lib")
    if !ok {
        fmt.println("Failed to load symbols:", dynlib.last_error())
        return
    }

    api.api_version      = api_version
    api.modification_time = mod_time
    ok = true
    return
}

unload_game_api :: proc(api: ^Game_API) {
    if api.lib != nil {
        dynlib.unload_library(api.lib)
    }
    versioned := fmt.tprintf(GAME_DLL_DIR + "game_{}.so", api.api_version)
    os.remove(versioned)
}

main :: proc() {
    exe_dir := filepath.dir(os.args[0], context.temp_allocator)
    os.set_working_directory(exe_dir)

    game_api_version := 0
    game_api, ok := load_game_api(game_api_version)
    if !ok { fmt.println("Failed to load game API"); return }
    game_api_version += 1

    // Convert os.args[1:] to cstring array for the game DLL
    wav_args := os.args[1:]
    cargs    := make([]cstring, len(wav_args))
    for s, i in wav_args { cargs[i] = cstring(raw_data(s)) }

    game_api.init_window()
    game_api.init(len(cargs), raw_data(cargs))

    old_apis := make([dynamic]Game_API)

    for game_api.should_run() {
        game_api.update()

        force_reload  := game_api.force_reload()
        force_restart := game_api.force_restart()
        reload        := force_reload || force_restart

        mod_time, mod_err := os.last_write_time_by_name(GAME_DLL_PATH)
        if mod_err == os.ERROR_NONE && game_api.modification_time != mod_time {
            // Wait briefly so compiler finishes writing the .so before we load it
            time.sleep(50 * time.Millisecond)
            reload = true
        }

        if reload {
            new_api, new_ok := load_game_api(game_api_version)
            if new_ok {
                size_changed := game_api.memory_size() != new_api.memory_size()
                if force_restart || size_changed {
                    // Full restart
                    game_api.shutdown()
                    for &old in old_apis { unload_game_api(&old) }
                    clear(&old_apis)
                    unload_game_api(&game_api)
                    game_api = new_api
                    game_api.init(len(cargs), raw_data(cargs))
                } else {
                    // Hot reload: pass memory to new DLL
                    mem := game_api.memory()
                    append(&old_apis, game_api)
                    game_api = new_api
                    game_api.hot_reloaded(mem)
                }
                game_api_version += 1
                fmt.println("Hot reloaded game DLL")
            }
        }
    }

    game_api.shutdown()
    game_api.shutdown_window()   // close window while DLL is still loaded
    for &old in old_apis { unload_game_api(&old) }
    delete(old_apis)
    unload_game_api(&game_api)
}
