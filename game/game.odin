package game

import "core:fmt"
import "core:math"
import "core:thread"
import "core:sync"
import rl "vendor:raylib"

WIN_W         :: 1280
WIN_H         :: 720
DISPLAY_WIDTH :: f32(60.0)
TIME_COLS     :: 600
FREQ_BINS     :: 96
TRACK_DX      :: f32(12.0)
TRACK_DZ      :: f32(16.0)
MAG_THRESHOLD :: f32(0.01)

FFTJob :: struct {
    wdata:     [4]^WaveData,
    waterfall: [4][]f32,
    done:      b32,
}

BinLines :: struct {
    pts: [4][FREQ_BINS][TIME_COLS]rl.Vector3,
}

Game_Memory :: struct {
    // Audio
    tracking:  [4]rl.Wave,
    wdata:     [4]^WaveData,
    music:     [4]rl.Music,

    // FFT
    job:       FFTJob,
    fft_thread: ^thread.Thread,

    // Geometry (built once after FFT)
    lines:       ^BinLines,
    lines_ready: bool,

    // Playback
    is_playing:   bool,
    loading_dots: int,
    dot_timer:    f32,
    run:          bool,
}

g: ^Game_Memory

@(export)
game_init_window :: proc() {
    rl.InitWindow(WIN_W, WIN_H, "WaveViz")
    rl.InitAudioDevice()
    rl.SetTargetFPS(60)
    rl.SetExitKey(nil)
}

@(export)
game_init :: proc(argc: int, argv: [^]cstring) {
    g = new(Game_Memory)
    g.run        = true
    g.is_playing = true

    if argc < 4 {
        fmt.println("Usage: waveviz file1.wav file2.wav file3.wav file4.wav")
        g.run = false
        return
    }

    for i := 0; i < 4; i += 1 {
        wav_path := argv[i]
        w := rl.LoadWave(wav_path)
        if w.frameCount == 0 { fmt.println("Failed to load wav:", wav_path); continue }
        g.tracking[i] = w
        g.wdata[i]    = WaveFromRaylib(w)

        // Build OGG path: replace last 3 chars (wav) with ogg
        wav_str := string(wav_path)
        ogg_buf  := [512]u8{}
        base_len := len(wav_str) - 3
        for j := 0; j < base_len; j += 1 { ogg_buf[j] = wav_str[j] }
        ogg_buf[base_len] = 'o'; ogg_buf[base_len+1] = 'g'; ogg_buf[base_len+2] = 'g'
        ogg_path := cstring(raw_data(ogg_buf[:]))

        g.music[i] = rl.LoadMusicStream(ogg_path)
        if g.music[i].frameCount > 0 {
            rl.SetMusicVolume(g.music[i], 0.5)
        }
    }

    for i := 0; i < 4; i += 1 {
        if g.music[i].frameCount > 0 { rl.PlayMusicStream(g.music[i]) }
    }

    for t := 0; t < 4; t += 1 {
        g.job.wdata[t]     = g.wdata[t]
        g.job.waterfall[t] = make([]f32, TIME_COLS * FREQ_BINS)
    }

    g.fft_thread = thread.create(fft_worker_proc)
    g.fft_thread.user_args[0] = &g.job
    thread.start(g.fft_thread)

    g.lines = new(BinLines)

    game_hot_reloaded(g)
}

fft_worker_proc :: proc(t: ^thread.Thread) {
    job := cast(^FFTJob)t.user_args[0]
    for track := 0; track < 4; track += 1 {
        wd := job.wdata[track]
        if wd == nil { continue }
        s16      := cast([^]i16)wd.data
        col_step := wd.frame_count / TIME_COLS
        half     := FFT_SIZE / 2
        mags     := make([]f32, half)
        for col := 0; col < TIME_COLS; col += 1 {
            fft_magnitude(s16, wd.frame_count, wd.channels, col * col_step, mags)
            for b := 0; b < FREQ_BINS; b += 1 {
                job.waterfall[track][col * FREQ_BINS + b] = mags[b]
            }
        }
        delete(mags)
    }
    sync.atomic_store(&job.done, true)
}

@(export)
game_update :: proc() {
    dt := rl.GetFrameTime()

    for i := 0; i < 4; i += 1 {
        if g.music[i].frameCount > 0 { rl.UpdateMusicStream(g.music[i]) }
    }

    play_time := f32(0)
    if g.music[0].frameCount > 0 { play_time = rl.GetMusicTimePlayed(g.music[0]) }

    fft_ready := sync.atomic_load(&g.job.done)

    if fft_ready && !g.lines_ready {
        x_step := DISPLAY_WIDTH / f32(TIME_COLS)
        z_step := f32(10.0) / f32(FREQ_BINS)
        for t := 0; t < 4; t += 1 {
            ox := f32(t) * TRACK_DX
            oz := f32(t) * TRACK_DZ
            for b := 0; b < FREQ_BINS; b += 1 {
                freq_boost := 1.0 + f32(b) * 0.018
                for col := 0; col < TIME_COLS; col += 1 {
                    mag := g.job.waterfall[t][col * FREQ_BINS + b]
                    g.lines.pts[t][b][col] = rl.Vector3{
                        ox + f32(col) * x_step,
                        mag * 6.0 * freq_boost,
                        oz + f32(b) * z_step,
                    }
                }
            }
        }
        g.lines_ready = true
    }

    track_dur   := cast(f32)(g.tracking[0].frameCount) / cast(f32)(g.tracking[0].sampleRate)
    play_frac   := rl.Clamp(play_time / track_dur if track_dur > 0 else f32(0), 0, 1)
    current_col := int(play_frac * f32(TIME_COLS - 1))

    cam_cx := play_frac * DISPLAY_WIDTH + f32(2) * TRACK_DX
    cam_cz := f32(2) * TRACK_DZ
    camera := rl.Camera3D{
        position = {cam_cx - 20 + math.sin(play_time * 0.07) * 5, 20, cam_cz + 35},
        target   = {cam_cx, 0, cam_cz},
        up       = {0, 1, 0},
        fovy     = 50,
    }

    PI :: f32(3.14159265)

    rl.BeginDrawing()
    rl.ClearBackground({3, 3, 10, 255})

    if !fft_ready {
        g.dot_timer += dt
        if g.dot_timer > 0.4 { g.dot_timer = 0; g.loading_dots = (g.loading_dots + 1) % 4 }
        dots := [4]cstring{"Analyserar ljud.", "Analyserar ljud..", "Analyserar ljud...", "Analyserar ljud...."}
        rl.DrawText(dots[g.loading_dots], WIN_W/2 - 120, WIN_H/2 - 10, 22, {180, 180, 255, 255})
        rl.DrawText("(musiken spelar redan)", WIN_W/2 - 100, WIN_H/2 + 20, 14, {100, 100, 140, 255})
        rl.EndDrawing()
        return
    }

    status_text  : cstring = g.is_playing ? "PLAYING" : "STOPPED"
    status_color := g.is_playing ? rl.Color{100, 255, 100, 255} : rl.Color{255, 100, 100, 255}
    rl.DrawText(status_text,                       15, 15, 18, status_color)
    rl.DrawText("SPACE: play/stop  |  ESC: exit  |  F5: hot reload", 15, 40, 14, {140, 140, 140, 255})

    rl.BeginMode3D(camera)

    x_step := DISPLAY_WIDTH / f32(TIME_COLS)
    z_step := f32(10.0) / f32(FREQ_BINS)
    _ = x_step; _ = z_step

    for t := 0; t < 4; t += 1 {
        hue := f32(t) * 90.0 + play_time * 10.0

        for b := 0; b < FREQ_BINS; b += 1 {
            freq_hue := hue + f32(b) * 2.5
            base_r := u8((math.sin_f32(freq_hue * PI / 180.0) * 0.5 + 0.5) * 255)
            base_g := u8((math.sin_f32((freq_hue + 120) * PI / 180.0) * 0.5 + 0.5) * 255)
            base_b := u8((math.sin_f32((freq_hue + 240) * PI / 180.0) * 0.5 + 0.5) * 255)

            played_color   := rl.Color{base_r, base_g, base_b, 220}
            unplayed_color := rl.Color{base_r / 5, base_g / 5, base_b / 5, 100}

            for col := 0; col < TIME_COLS - 1; col += 1 {
                p0 := g.lines.pts[t][b][col]
                p1 := g.lines.pts[t][b][col + 1]
                if p0.y < MAG_THRESHOLD && p1.y < MAG_THRESHOLD { continue }
                lc := played_color if col < current_col else unplayed_color
                rl.DrawLine3D(p0, p1, lc)
            }
        }
    }

    rl.EndMode3D()
    rl.EndDrawing()

    if rl.IsKeyPressed(.SPACE)  { g.is_playing = !g.is_playing }
}

@(export)
game_should_run :: proc() -> bool {
    if rl.WindowShouldClose() { return false }
    return g.run
}

@(export)
game_shutdown :: proc() {
    // Stop and unload music streams first — audio callback must be dead before freeing wave data
    for i := 0; i < 4; i += 1 {
        if g.music[i].frameCount > 0 {
            rl.StopMusicStream(g.music[i])
            rl.UnloadMusicStream(g.music[i])
        }
    }

    if g.fft_thread != nil {
        thread.join(g.fft_thread)
        thread.destroy(g.fft_thread)
    }

    for i := 0; i < 4; i += 1 {
        rl.UnloadWave(g.tracking[i])
        if g.wdata[i] != nil { free(g.wdata[i]) }
        delete(g.job.waterfall[i])
    }
    if g.lines != nil { free(g.lines) }
    free(g)
}

@(export)
game_shutdown_window :: proc() {
    rl.CloseAudioDevice()
    rl.CloseWindow()
}

@(export)
game_memory :: proc() -> rawptr { return g }

@(export)
game_memory_size :: proc() -> int { return size_of(Game_Memory) }

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
    g = (^Game_Memory)(mem)
}

@(export)
game_force_reload :: proc() -> bool { return rl.IsKeyPressed(.F5) }

@(export)
game_force_restart :: proc() -> bool { return false }
