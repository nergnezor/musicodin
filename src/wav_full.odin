package main

import "vendor:raylib"

WaveData :: struct {
    data: ^u8,
    frame_count: int,
    channels: int,
    sample_rate: int,
}

WaveFromRaylib :: proc(w: raylib.Wave) -> ^WaveData {
    if w.frameCount == 0 {
        return nil
    }
    wd := new(WaveData)
    wd.data = cast(^u8)w.data
    wd.frame_count = int(w.frameCount)
    wd.channels = int(w.channels)
    wd.sample_rate = int(w.sampleRate)
    return wd
}
/*
// wav_full.odin
// Full WAV -> f32 converter using `vendor:raylib` Wave type.
// To enable: remove comment markers and ensure `vendor:raylib` is available.

package main

import "core:mem"
import "core:fmt"
import "vendor:raylib"

WaveData :: struct {
    sample_rate: int,
    channels: int,
    samples: ^f32,
    sample_count: int,
}

WaveFromRaylib :: proc(w: raylib.Wave) -> ^WaveData {
    if w.sampleSize != 16 {
        fmt.println("Unsupported sampleSize; only 16-bit PCM supported in this helper")
        return nil
    }
    // field names differ between bindings; adjust if necessary
    total := w.sampleCount * w.channels
    // allocate float buffer
    bytes := total * mem.size_of(f32)
    buf := mem.alloc(mem.HeapAllocator, bytes)
    if buf == nil { return nil }
    fptr := cast(^f32) buf

    s16 := cast(^i16) w.data
    for i := 0; i < total; i += 1 {
        fptr[i] = cast(f32)(s16[i]) / 32768.0
    }

    wd := mem.alloc(mem.HeapAllocator, mem.size_of(WaveData))
    wd.sample_rate = w.sampleRate
    wd.channels = w.channels
    wd.samples = fptr
    wd.sample_count = w.sampleCount
    return wd
}

*/
