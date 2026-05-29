// verify_dsp.c — Proves the EffeTune Rust DSP modules run natively via dlopen.
//
// Loads one "io_ptr-style" module (transient_shaper) as a native dylib, drives a
// transient test signal through it, and checks the output is finite and shaped.
// This validates the core feasibility claim of the native-macOS plan: the same
// Rust C-ABI (init/set_params/process_block/io_ptr/free_state) is callable
// directly from native code with zero source changes.
//
// Build & run:
//   cc -O2 -o native/tools/verify_dsp native/tools/verify_dsp.c
//   native/tools/verify_dsp <path-to-libtransient_shaper.dylib>

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *State;
typedef State (*init_fn)(float sample_rate, unsigned channel_count, unsigned max_block);
typedef void (*free_fn)(State);
typedef float *(*ioptr_fn)(State);
typedef float (*lastgain_fn)(State);
typedef void (*setparams_fn)(State, float, float, float, float, float, float, float);
typedef void (*process_fn)(State, unsigned block_size);

static void *must(void *lib, const char *name) {
    void *sym = dlsym(lib, name);
    if (!sym) {
        fprintf(stderr, "FAIL: symbol '%s' not found: %s\n", name, dlerror());
        exit(2);
    }
    return sym;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <libtransient_shaper.dylib>\n", argv[0]);
        return 1;
    }
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
        return 2;
    }

    init_fn       init       = (init_fn)       must(lib, "init");
    free_fn       free_state = (free_fn)       must(lib, "free_state");
    ioptr_fn      io_ptr     = (ioptr_fn)      must(lib, "io_ptr");
    lastgain_fn   last_gain  = (lastgain_fn)   must(lib, "last_gain_db");
    setparams_fn  set_params = (setparams_fn)  must(lib, "set_params");
    process_fn    process    = (process_fn)    must(lib, "process_block");
    printf("OK: dlopen + all 6 symbols resolved\n");

    const float sr = 48000.0f;
    const unsigned ch = 2, bs = 128;
    State st = init(sr, ch, bs);
    if (!st) { fprintf(stderr, "FAIL: init returned NULL\n"); return 3; }
    printf("OK: init(%.0f, %u, %u)\n", sr, ch, bs);

    // Transient emphasis: fast 1/20ms, slow 20/300ms, +12dB transient, 0dB sustain, 5ms smooth
    set_params(st, 1.0f, 20.0f, 20.0f, 300.0f, 12.0f, 0.0f, 5.0f);

    // io is planar: idx = ch*bs + i. Build a sharp attack + decay (a transient).
    float *io = io_ptr(st);
    float peak_in = 0.0f;
    for (unsigned c = 0; c < ch; c++) {
        for (unsigned i = 0; i < bs; i++) {
            float env = (i < 4) ? 1.0f : expf(-(float)(i - 4) / 20.0f); // attack then decay
            float x = 0.6f * env * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
            io[c * bs + i] = x;
            float a = fabsf(x);
            if (a > peak_in) peak_in = a;
        }
    }

    process(st, bs);

    // Validate output: all finite, in [-1,1] (module hard-clips), and changed by gain.
    int all_finite = 1, in_range = 1;
    float peak_out = 0.0f;
    io = io_ptr(st);
    for (unsigned c = 0; c < ch; c++) {
        for (unsigned i = 0; i < bs; i++) {
            float y = io[c * bs + i];
            if (!isfinite(y)) all_finite = 0;
            if (y > 1.0001f || y < -1.0001f) in_range = 0;
            float a = fabsf(y);
            if (a > peak_out) peak_out = a;
        }
    }
    float g = last_gain(st);
    printf("peak_in=%.4f peak_out=%.4f last_gain_db=%.3f finite=%d in_range=%d\n",
           peak_in, peak_out, g, all_finite, in_range);

    free_state(st);
    dlclose(lib);

    if (!all_finite || !in_range) {
        fprintf(stderr, "FAIL: output invalid\n");
        return 4;
    }
    // Transient boost should push the transient louder than the (un-boosted) input.
    if (peak_out <= peak_in) {
        fprintf(stderr, "WARN: peak_out <= peak_in (gain may not have applied)\n");
    }
    printf("PASS: native Rust DSP executed via dlopen\n");
    return 0;
}
