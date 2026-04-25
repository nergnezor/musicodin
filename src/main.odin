package main

import "core:fmt"
import "core:os"
import "core:math"
import "vendor:raylib"

WIN_W         :: 1280
WIN_H         :: 720
DISPLAY_WIDTH :: f32(60.0)
// Time columns: how many FFT slices to show along X
TIME_COLS     :: 400
// Frequency bins to display (lower half of FFT_SIZE/2)
FREQ_BINS     :: 96
// Spacing between tracks along diagonal
TRACK_DX      :: f32(10.0)
TRACK_DZ      :: f32(14.0)

main :: proc() {
    args := os.args
    if len(args) < 5 {
        fmt.println("Usage: waveviz file1.wav file2.wav file3.wav file4.wav")
        return
    }

    raylib.InitWindow(WIN_W, WIN_H, "Odin WaveViz")
    raylib.InitAudioDevice()
    raylib.SetTargetFPS(60)
    fmt.println("Audio device initialized")

    tracking := make([]raylib.Wave, 4)
    wdata    := make([]^WaveData, 4)
    music    := make([]raylib.Music, 4)

    for i := 0; i < 4; i += 1 {
        file  := args[i+1]
        cfile := cstring(raw_data(file))

        w := raylib.LoadWave(cfile)
        if w.frameCount == 0 {
            fmt.println("Failed to load wave:", file)
            continue
        }
        tracking[i] = w
        wdata[i]    = WaveFromRaylib(w)
        fmt.println("Loaded wave track", i+1)

        ogg_buf  := [512]u8{}
        base_len := len(file) - 4
        for j := 0; j < base_len; j += 1 { ogg_buf[j] = file[j] }
        ogg_buf[base_len]   = '.'
        ogg_buf[base_len+1] = 'o'
        ogg_buf[base_len+2] = 'g'
        ogg_buf[base_len+3] = 'g'
        ogg_path := cstring(raw_data(ogg_buf[:]))

        music[i] = raylib.LoadMusicStream(ogg_path)
        if music[i].frameCount > 0 {
            raylib.SetMusicVolume(music[i], 0.5)
            fmt.println("Loaded OGG track", i+1)
        } else {
            fmt.println("Failed to load OGG track", i+1)
        }
    }

    for i := 0; i < 4; i += 1 {
        if music[i].frameCount > 0 {
            raylib.PlayMusicStream(music[i])
            fmt.println("Playing track", i+1)
        }
    }

    // Precompute full FFT waterfall for each track (TIME_COLS slices × FREQ_BINS)
    // Each cell stores normalized magnitude 0..1
    waterfall := make([][]f32, 4)
    for t := 0; t < 4; t += 1 {
        waterfall[t] = make([]f32, TIME_COLS * FREQ_BINS)
        wd := wdata[t]
        if wd == nil { continue }
        samples_i16 := cast([^]i16)wd.data
        col_step    := wd.frame_count / TIME_COLS
        mags        := make([]f32, FFT_SIZE / 2)
        for col := 0; col < TIME_COLS; col += 1 {
            frame_start := col * col_step
            fft_magnitude(samples_i16, wd.frame_count, wd.channels, frame_start, mags)
            for b := 0; b < FREQ_BINS; b += 1 {
                waterfall[t][col * FREQ_BINS + b] = mags[b]
            }
        }
        delete(mags)
        fmt.println("FFT waterfall computed for track", t+1)
    }

    is_playing := true
    PI :: f32(3.14159265)

    for {
        if raylib.WindowShouldClose() { break }

        for i := 0; i < 4; i += 1 {
            if music[i].frameCount > 0 {
                raylib.UpdateMusicStream(music[i])
            }
        }

        play_time := f32(0)
        if music[0].frameCount > 0 {
            play_time = raylib.GetMusicTimePlayed(music[0])
        }

        // Current column index
        track_dur   := cast(f32)(tracking[0].frameCount) / cast(f32)(tracking[0].sampleRate)
        play_frac   := play_time / track_dur if track_dur > 0 else f32(0)
        play_frac    = raylib.Clamp(play_frac, 0, 1)
        current_col := int(play_frac * f32(TIME_COLS - 1))

        // Camera positioned to see all 4 tracks diagonally
        cam_cx := play_frac * DISPLAY_WIDTH + f32(4) * TRACK_DX * 0.5
        cam_cz := f32(4) * TRACK_DZ * 0.5
        camera := raylib.Camera3D{
            position = {cam_cx - 15 + math.sin(play_time * 0.08) * 4,
                        22,
                        cam_cz + 35},
            target   = {cam_cx, 0, cam_cz},
            up       = {0, 1, 0},
            fovy     = 50,
        }

        raylib.BeginDrawing()
        raylib.ClearBackground({4, 4, 12, 255})

        status_text  : cstring = "STOPPED"
        status_color := raylib.Color{255, 100, 100, 255}
        if is_playing {
            status_text  = "PLAYING"
            status_color = {100, 255, 100, 255}
        }
        raylib.DrawText(status_text,                       15, 15, 18, status_color)
        raylib.DrawText("SPACE: play/stop  |  ESC: exit", 15, 40, 14, {140, 140, 140, 255})

        raylib.BeginMode3D(camera)

        for t := 0; t < 4; t += 1 {
            wd := wdata[t]
            if wd == nil { continue }

            // Track origin offset — diagonal layout
            ox := f32(t) * TRACK_DX
            oz := f32(t) * TRACK_DZ

            // Base hue per track, slowly animating
            hue    := f32(t) * 90.0 + play_time * 15.0
            base_r := math.sin_f32(hue * PI / 180.0) * 0.5 + 0.5
            base_g := math.sin_f32((hue + 120) * PI / 180.0) * 0.5 + 0.5
            base_b := math.sin_f32((hue + 240) * PI / 180.0) * 0.5 + 0.5

            x_step := DISPLAY_WIDTH / f32(TIME_COLS)
            z_step := f32(8.0) / f32(FREQ_BINS)

            for col := 0; col < TIME_COLS - 1; col += 1 {
                x0 := ox + f32(col)   * x_step
                x1 := ox + f32(col+1) * x_step

                is_played := col < current_col
                dim        := f32(0.12) if !is_played else f32(1.0)

                for b := 0; b < FREQ_BINS - 1; b += 1 {
                    mag00 := waterfall[t][col     * FREQ_BINS + b]
                    mag10 := waterfall[t][(col+1) * FREQ_BINS + b]
                    mag11 := waterfall[t][(col+1) * FREQ_BINS + b + 1]
                    mag01 := waterfall[t][col     * FREQ_BINS + b + 1]

                    z0 := oz + f32(b)   * z_step
                    z1 := oz + f32(b+1) * z_step

                    freq_boost := 1.0 + f32(b) * 0.025
                    y00 := mag00 * 5.0 * freq_boost
                    y10 := mag10 * 5.0 * freq_boost
                    y11 := mag11 * 5.0 * freq_boost
                    y01 := mag01 * 5.0 * freq_boost

                    // Color from peak magnitude of the quad
                    peak_mag := mag00
                    if mag10 > peak_mag { peak_mag = mag10 }
                    if mag11 > peak_mag { peak_mag = mag11 }
                    if mag01 > peak_mag { peak_mag = mag01 }

                    freq_hue := hue + f32(b) * 2.0
                    fr := u8((math.sin_f32(freq_hue * PI / 180.0) * 0.5 + 0.5) * peak_mag * dim * 255)
                    fg := u8((math.sin_f32((freq_hue + 120) * PI / 180.0) * 0.5 + 0.5) * peak_mag * dim * 255)
                    fb := u8((math.sin_f32((freq_hue + 240) * PI / 180.0) * 0.5 + 0.5) * peak_mag * dim * 255)
                    _ = base_r; _ = base_g; _ = base_b
                    col_c := raylib.Color{fr, fg, fb, 220}

                    // Quad as two filled triangles
                    v00 := raylib.Vector3{x0, y00, z0}
                    v10 := raylib.Vector3{x1, y10, z0}
                    v11 := raylib.Vector3{x1, y11, z1}
                    v01 := raylib.Vector3{x0, y01, z1}
                    raylib.DrawTriangle3D(v00, v10, v11, col_c)
                    raylib.DrawTriangle3D(v00, v11, v01, col_c)
                }
            }

            // Playhead plane: vertical lines at current column across all freq bins
            px := ox + f32(current_col) * x_step
            for b := 0; b < FREQ_BINS; b += 1 {
                mag := waterfall[t][current_col * FREQ_BINS + b]
                fz  := oz + f32(b) * z_step
                raylib.DrawLine3D({px, 0, fz}, {px, mag * 4.5, fz}, {255, 230, 60, 255})
            }
            // Playhead floor line
            raylib.DrawLine3D({px, 0, oz}, {px, 0, oz + f32(FREQ_BINS) * z_step}, {255, 230, 60, 140})
        }

        raylib.EndMode3D()
        raylib.EndDrawing()

        if raylib.IsKeyPressed(.ESCAPE) { break }
        if raylib.IsKeyPressed(.SPACE)  { is_playing = !is_playing }
    }

    for i := 0; i < 4; i += 1 {
        raylib.UnloadWave(tracking[i])
        if music[i].frameCount > 0 { raylib.UnloadMusicStream(music[i]) }
        if wdata[i] != nil         { free(wdata[i]) }
        if waterfall[i] != nil     { delete(waterfall[i]) }
    }
    delete(waterfall)

    raylib.CloseAudioDevice()
    raylib.CloseWindow()
}
