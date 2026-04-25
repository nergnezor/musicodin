package main

import "core:fmt"
import "core:os"
import "core:math"
import "core:thread"
import "core:sync"
import "vendor:raylib"

WIN_W         :: 1280
WIN_H         :: 720
DISPLAY_WIDTH :: f32(60.0)
TIME_COLS     :: 600
FREQ_BINS     :: 96
TRACK_DX      :: f32(12.0)
TRACK_DZ      :: f32(16.0)

// Only draw peaks above this threshold — skips silent/flat bins
MAG_THRESHOLD :: f32(0.15)

FFTJob :: struct {
    wdata:     [4]^WaveData,
    waterfall: [4][]f32,
    done:      b32,
}

fft_worker :: proc(t: ^thread.Thread) {
    job := cast(^FFTJob)t.user_args[0]
    for track := 0; track < 4; track += 1 {
        wd := job.wdata[track]
        if wd == nil { continue }
        samples_i16 := cast([^]i16)wd.data
        col_step    := wd.frame_count / TIME_COLS
        half        := FFT_SIZE / 2
        mags        := make([]f32, half)
        for col := 0; col < TIME_COLS; col += 1 {
            fft_magnitude(samples_i16, wd.frame_count, wd.channels, col * col_step, mags)
            for b := 0; b < FREQ_BINS; b += 1 {
                job.waterfall[track][col * FREQ_BINS + b] = mags[b]
            }
        }
        delete(mags)
        fmt.println("FFT done for track", track+1)
    }
    sync.atomic_store(&job.done, true)
}

// Pre-built line strip per freq bin per track: [TIME_COLS]Vector3
BinLines :: struct {
    pts: [4][FREQ_BINS][TIME_COLS]raylib.Vector3,
}

main :: proc() {
    args := os.args
    if len(args) < 5 {
        fmt.println("Usage: waveviz file1.wav file2.wav file3.wav file4.wav")
        return
    }

    raylib.InitWindow(WIN_W, WIN_H, "Odin WaveViz")
    raylib.InitAudioDevice()
    raylib.SetTargetFPS(60)

    tracking := make([]raylib.Wave, 4)
    wdata    := make([]^WaveData, 4)
    music    := make([]raylib.Music, 4)

    for i := 0; i < 4; i += 1 {
        file  := args[i+1]
        cfile := cstring(raw_data(file))
        w := raylib.LoadWave(cfile)
        if w.frameCount == 0 { fmt.println("Failed to load wave:", file); continue }
        tracking[i] = w
        wdata[i]    = WaveFromRaylib(w)
        fmt.println("Loaded wave track", i+1)

        ogg_buf  := [512]u8{}
        base_len := len(file) - 4
        for j := 0; j < base_len; j += 1 { ogg_buf[j] = file[j] }
        ogg_buf[base_len] = '.'; ogg_buf[base_len+1] = 'o'; ogg_buf[base_len+2] = 'g'; ogg_buf[base_len+3] = 'g'
        ogg_path := cstring(raw_data(ogg_buf[:]))

        music[i] = raylib.LoadMusicStream(ogg_path)
        if music[i].frameCount > 0 {
            raylib.SetMusicVolume(music[i], 0.5)
            fmt.println("Loaded OGG track", i+1)
        }
    }

    for i := 0; i < 4; i += 1 {
        if music[i].frameCount > 0 { raylib.PlayMusicStream(music[i]) }
    }

    job := FFTJob{}
    for t := 0; t < 4; t += 1 {
        job.wdata[t]     = wdata[t]
        job.waterfall[t] = make([]f32, TIME_COLS * FREQ_BINS)
    }

    fft_thread := thread.create(fft_worker)
    fft_thread.user_args[0] = &job
    thread.start(fft_thread)

    // Pre-computed geometry (built once after FFT)
    lines    := new(BinLines)
    lines_ready := false

    is_playing   := true
    PI           :: f32(3.14159265)
    loading_dots := 0
    dot_timer    := f32(0)

    x_step := DISPLAY_WIDTH / f32(TIME_COLS)
    z_step := f32(10.0) / f32(FREQ_BINS)

    for {
        if raylib.WindowShouldClose() { break }

        dt := raylib.GetFrameTime()

        for i := 0; i < 4; i += 1 {
            if music[i].frameCount > 0 { raylib.UpdateMusicStream(music[i]) }
        }

        play_time := f32(0)
        if music[0].frameCount > 0 { play_time = raylib.GetMusicTimePlayed(music[0]) }

        fft_ready := sync.atomic_load(&job.done)

        // Build line geometry once after FFT completes
        if fft_ready && !lines_ready {
            for t := 0; t < 4; t += 1 {
                ox := f32(t) * TRACK_DX
                oz := f32(t) * TRACK_DZ
                for b := 0; b < FREQ_BINS; b += 1 {
                    freq_boost := 1.0 + f32(b) * 0.018
                    for col := 0; col < TIME_COLS; col += 1 {
                        mag := job.waterfall[t][col * FREQ_BINS + b]
                        lines.pts[t][b][col] = raylib.Vector3{
                            ox + f32(col) * x_step,
                            mag * 6.0 * freq_boost,
                            oz + f32(b) * z_step,
                        }
                    }
                }
            }
            lines_ready = true
            fmt.println("Lines built")
        }

        track_dur   := cast(f32)(tracking[0].frameCount) / cast(f32)(tracking[0].sampleRate)
        play_frac   := raylib.Clamp(play_time / track_dur if track_dur > 0 else f32(0), 0, 1)
        current_col := int(play_frac * f32(TIME_COLS - 1))

        cam_cx := play_frac * DISPLAY_WIDTH + f32(2) * TRACK_DX
        cam_cz := f32(2) * TRACK_DZ
        camera := raylib.Camera3D{
            position = {cam_cx - 20 + math.sin(play_time * 0.07) * 5, 20, cam_cz + 35},
            target   = {cam_cx, 0, cam_cz},
            up       = {0, 1, 0},
            fovy     = 50,
        }

        raylib.BeginDrawing()
        raylib.ClearBackground({3, 3, 10, 255})

        if !fft_ready {
            dot_timer += dt
            if dot_timer > 0.4 { dot_timer = 0; loading_dots = (loading_dots + 1) % 4 }
            dots := [4]cstring{"Analyserar ljud.", "Analyserar ljud..", "Analyserar ljud...", "Analyserar ljud...."}
            raylib.DrawText(dots[loading_dots], WIN_W/2 - 120, WIN_H/2 - 10, 22, {180, 180, 255, 255})
            raylib.DrawText("(musiken spelar redan)", WIN_W/2 - 100, WIN_H/2 + 20, 14, {100, 100, 140, 255})
            raylib.EndDrawing()
            if raylib.IsKeyPressed(.ESCAPE) { break }
            continue
        }

        status_text  : cstring = is_playing ? "PLAYING" : "STOPPED"
        status_color := is_playing ? raylib.Color{100, 255, 100, 255} : raylib.Color{255, 100, 100, 255}
        raylib.DrawText(status_text,                       15, 15, 18, status_color)
        raylib.DrawText("SPACE: play/stop  |  ESC: exit", 15, 40, 14, {140, 140, 140, 255})

        raylib.BeginMode3D(camera)

        for t := 0; t < 4; t += 1 {
            hue := f32(t) * 90.0 + play_time * 10.0

            for b := 0; b < FREQ_BINS; b += 1 {
                freq_hue := hue + f32(b) * 2.5
                base_r := u8((math.sin_f32(freq_hue * PI / 180.0) * 0.5 + 0.5) * 255)
                base_g := u8((math.sin_f32((freq_hue + 120) * PI / 180.0) * 0.5 + 0.5) * 255)
                base_b := u8((math.sin_f32((freq_hue + 240) * PI / 180.0) * 0.5 + 0.5) * 255)

                played_color   := raylib.Color{base_r, base_g, base_b, 220}
                unplayed_color := raylib.Color{base_r / 5, base_g / 5, base_b / 5, 100}

                for col := 0; col < TIME_COLS - 1; col += 1 {
                    p0 := lines.pts[t][b][col]
                    p1 := lines.pts[t][b][col + 1]

                    // Skip flat/silent segments
                    if p0.y < 0.01 && p1.y < 0.01 { continue }

                    lc := played_color if col < current_col else unplayed_color
                    raylib.DrawLine3D(p0, p1, lc)
                }
            }
        }

        raylib.EndMode3D()
        raylib.EndDrawing()

        if raylib.IsKeyPressed(.ESCAPE) { break }
        if raylib.IsKeyPressed(.SPACE)  { is_playing = !is_playing }
    }

    thread.join(fft_thread)
    thread.destroy(fft_thread)
    free(lines)

    for i := 0; i < 4; i += 1 {
        raylib.UnloadWave(tracking[i])
        if music[i].frameCount > 0 { raylib.UnloadMusicStream(music[i]) }
        if wdata[i] != nil         { free(wdata[i]) }
        delete(job.waterfall[i])
    }

    raylib.CloseAudioDevice()
    raylib.CloseWindow()
}
