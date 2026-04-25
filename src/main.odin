package main

import "core:fmt"
import "core:os"
import "core:math"
import "vendor:raylib"

WIN_W :: 1280
WIN_H :: 720
TRACK_SPACING :: 4.0
TIME_SCALE :: 0.001

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
        file := args[i+1]
        cfile := cstring(raw_data(file))

        // Load wave for visualization
        w := raylib.LoadWave(cfile)
        if w.frameCount == 0 {
            fmt.println("Failed to load wave:", file)
            continue
        }
        tracking[i] = w
        wdata[i] = WaveFromRaylib(w)
        fmt.println("Loaded wave track", i+1)

        // Build OGG filename: replace ".wav" with ".ogg"
        ogg_buf := [512]u8{}
        base_len := len(file) - 4
        for j := 0; j < base_len; j += 1 {
            ogg_buf[j] = file[j]
        }
        ogg_buf[base_len]   = '.'
        ogg_buf[base_len+1] = 'o'
        ogg_buf[base_len+2] = 'g'
        ogg_buf[base_len+3] = 'g'
        ogg_path := cstring(raw_data(ogg_buf[:]))

        music[i] = raylib.LoadMusicStream(ogg_path)
        if music[i].frameCount > 0 {
            raylib.SetMusicVolume(music[i], 0.5)
            fmt.println("Loaded OGG track", i+1, "frames:", music[i].frameCount)
        } else {
            fmt.println("Failed to load OGG track", i+1)
        }
    }

    // Play all OGG streams
    for i := 0; i < 4; i += 1 {
        if music[i].frameCount > 0 {
            raylib.PlayMusicStream(music[i])
            fmt.println("Playing track", i+1)
        }
    }

    fmt.println("Starting visualization...")

    fmt.println("Entering main loop...")
    is_playing := true

    for {
        if raylib.WindowShouldClose() {
            break
        }

        // Update music streams
        for i := 0; i < 4; i += 1 {
            if music[i].frameCount > 0 {
                raylib.UpdateMusicStream(music[i])
            }
        }

        // Get playback time from first track
        play_time := f32(0)
        if music[0].frameCount > 0 {
            play_time = raylib.GetMusicTimePlayed(music[0])
        }

        raylib.BeginDrawing()
        raylib.ClearBackground({5, 5, 10, 255})

        // HUD
        status_text  : cstring = "STOPPED"
        status_color := raylib.Color{255, 100, 100, 255}
        if is_playing {
            status_text  = "PLAYING"
            status_color = {100, 255, 100, 255}
        }
        raylib.DrawText(status_text,                           15, 15, 18, status_color)
        raylib.DrawText("SPACE: play/stop  |  ESC: exit",     15, 40, 14, {140, 140, 140, 255})

        // Camera follows playhead X position
        track_dur := cast(f32)(tracking[0].frameCount) / cast(f32)(tracking[0].sampleRate)
        head_x := (play_time / track_dur) * DISPLAY_WIDTH
        head_x = raylib.Clamp(head_x, 0, DISPLAY_WIDTH)
        camera := raylib.Camera3D{
            position = {head_x + math.sin(play_time * 0.15) * 8, 10, 25},
            target   = {head_x, 0, 6},
            up       = {0, 1, 0},
            fovy     = 55,
        }
        raylib.BeginMode3D(camera)
        raylib.DrawGrid(20, 1.0)

        DISPLAY_WIDTH :: f32(50.0)
        MAX_SEGMENTS  :: 800

        PI :: f32(3.14159265)

        for t := 0; t < 4; t += 1 {
            wd := wdata[t]
            if wd == nil { continue }

            samples_i16 := cast([^]i16)wd.data
            frame_count := wd.frame_count
            channels := wd.channels
            z := cast(f32)(t) * TRACK_SPACING

            step := frame_count / MAX_SEGMENTS
            if step < 1 { step = 1 }

            x_scale := DISPLAY_WIDTH / cast(f32)(frame_count)

            // Playhead X position for this track
            t_dur := cast(f32)(frame_count) / cast(f32)(wd.sample_rate)
            px := f32(0)
            if t_dur > 0 {
                px = (play_time / t_dur) * DISPLAY_WIDTH
                px = raylib.Clamp(px, 0, DISPLAY_WIDTH)
            }

            // Color per track (animated hue)
            hue := f32(t) * 90.0 + play_time * 20.0
            color_r := u8(math.sin_f32(hue * PI / 180.0) * 100 + 155)
            color_g := u8(math.sin_f32((hue + 120) * PI / 180.0) * 100 + 155)
            color_b := u8(math.sin_f32((hue + 240) * PI / 180.0) * 100 + 155)
            played_color   := raylib.Color{color_r, color_g, color_b, 230}
            unplayed_color := raylib.Color{color_r / 4, color_g / 4, color_b / 4, 120}

            prev: raylib.Vector3
            first := true
            frame := 0

            for frame < frame_count {
                sum := f32(0)
                for c := 0; c < channels; c += 1 {
                    idx := frame*channels + c
                    sum += cast(f32)(samples_i16[idx]) / 32768.0
                }
                amp := sum / cast(f32)(channels) if channels > 0 else 0
                x := cast(f32)(frame) * x_scale
                y := amp * 3.0
                cur := raylib.Vector3{x, y, z}
                if !first {
                    seg_color := played_color if x <= px else unplayed_color
                    raylib.DrawLine3D(prev, cur, seg_color)
                }
                prev = cur
                first = false
                frame += step
            }

            // Baseline
            raylib.DrawLine3D({0, 0, z}, {DISPLAY_WIDTH, 0, z}, {60, 60, 60, 120})

            // Playhead: vertical bar + sphere
            if t_dur > 0 {
                raylib.DrawLine3D({px, -3.5, z}, {px,  3.5, z}, {255, 230, 60, 255})
                raylib.DrawSphere({px, 0, z}, 0.3, {255, 230, 60, 255})
                // Glow rings
                raylib.DrawCircle3D({px, 0, z}, 0.5, {1,0,0}, 90, {255, 230, 60, 120})
                raylib.DrawCircle3D({px, 0, z}, 0.7, {1,0,0}, 90, {255, 230, 60,  60})
            }
        }

        raylib.EndMode3D()
        raylib.EndDrawing()

        // Keyboard controls
        if raylib.IsKeyPressed(.ESCAPE) {
            break
        }
        if raylib.IsKeyPressed(.SPACE) {
            is_playing = !is_playing
        }
    }

    for i := 0; i < 4; i += 1 {
        raylib.UnloadWave(tracking[i])
        if music[i].frameCount > 0 {
            raylib.UnloadMusicStream(music[i])
        }
        if wdata[i] != nil {
            free(wdata[i])
        }
    }

    raylib.CloseAudioDevice()
    raylib.CloseWindow()
}

