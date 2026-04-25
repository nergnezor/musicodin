package main

import "core:math"
import "core:math/cmplx"

FFT_SIZE :: 512

// In-place Cooley-Tukey FFT on a power-of-2 sized slice of complex128
fft :: proc(buf: []complex128) {
    n := len(buf)
    if n <= 1 { return }

    // Bit-reversal permutation
    j := 0
    for i := 1; i < n; i += 1 {
        bit := n >> 1
        for ; j & bit != 0; bit >>= 1 {
            j ~= bit
        }
        j ~= bit
        if i < j {
            buf[i], buf[j] = buf[j], buf[i]
        }
    }

    // Butterfly stages
    length := 2
    for length <= n {
        angle := -2.0 * math.PI / f64(length)
        w_base := complex(math.cos(angle), math.sin(angle))
        for i := 0; i < n; i += length {
            w := complex128(1)
            half := length / 2
            for k := 0; k < half; k += 1 {
                u := buf[i + k]
                v := buf[i + k + half] * w
                buf[i + k]        = u + v
                buf[i + k + half] = u - v
                w *= w_base
            }
        }
        length *= 2
    }
}

// Fill magnitude spectrum into out[] from PCM samples starting at frame_start.
// out must have FFT_SIZE/2 elements. Values are normalized 0..1.
fft_magnitude :: proc(samples: [^]i16, frame_count: int, channels: int, frame_start: int, out: []f32) {
    n :: FFT_SIZE
    buf: [n]complex128

    for i := 0; i < n; i += 1 {
        f := frame_start + i
        s := f32(0)
        if f < frame_count {
            for c := 0; c < channels; c += 1 {
                s += f32(samples[f * channels + c]) / 32768.0
            }
            s /= f32(channels)
        }
        // Hann window
        w := 0.5 * (1.0 - math.cos_f32(2.0 * math.PI * f32(i) / f32(n - 1)))
        buf[i] = complex(f64(s * w), 0)
    }

    fft(buf[:])

    half :: n / 2
    max_mag := f32(1e-6)
    mags: [half]f32
    for i := 0; i < half; i += 1 {
        re := f32(real(buf[i]))
        im := f32(imag(buf[i]))
        mags[i] = math.sqrt(re*re + im*im)
        if mags[i] > max_mag { max_mag = mags[i] }
    }
    for i := 0; i < half; i += 1 {
        out[i] = mags[i] / max_mag
    }
}
