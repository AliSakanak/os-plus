#include "WorkbenchAudioRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct WBPipe {
    float *ring;             // interleaved L/R, capacity * 2 floats
    uint32_t capacity;       // power of two
    uint32_t mask;

    _Atomic uint64_t writePos;   // total frames ever written (writer owns)
    _Atomic uint64_t readPos;    // total frames ever read (reader owns)

    _Atomic uint32_t targetFrames;
    _Atomic uint32_t maxFrames;

    _Atomic float targetGain;
    _Atomic float immediateGain; // < 0 means "none pending"
    float currentGain;           // reader only
    float glide;                 // per-sample smoothing coefficient
    bool primed;                 // reader only

    _Atomic float inputPeak;
    _Atomic float outputPeak;
    _Atomic uint32_t underruns;
    _Atomic uint32_t overruns;
    _Atomic uint32_t skips;
};

static uint32_t next_pow2(uint32_t v) {
    if (v < 64) v = 64;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

static float clamp_gain(float g) {
    if (!(g >= 0.0f)) return 0.0f;   // also catches NaN
    return g > 1.0f ? 1.0f : g;
}

/// Anything that isn't a sane sample (NaN, inf, wildly out of range) becomes silence.
static inline float sane(float x) {
    return (x >= -8.0f && x <= 8.0f) ? x : 0.0f;
}

static inline float clamp_unit(float x) {
    return x > 1.0f ? 1.0f : (x < -1.0f ? -1.0f : x);
}

static void raise_peak(_Atomic float *slot, float value) {
    float old = atomic_load_explicit(slot, memory_order_relaxed);
    if (value > old) atomic_store_explicit(slot, value, memory_order_relaxed);
}

WBPipe *wb_pipe_create(uint32_t capacityFrames, double sampleRate, float initialGain) {
    WBPipe *p = calloc(1, sizeof(WBPipe));
    if (!p) return NULL;
    p->capacity = next_pow2(capacityFrames);
    p->mask = p->capacity - 1;
    p->ring = calloc((size_t)p->capacity * 2, sizeof(float));
    if (!p->ring) { free(p); return NULL; }
    atomic_init(&p->writePos, 0);
    atomic_init(&p->readPos, 0);
    atomic_init(&p->targetFrames, 512);
    atomic_init(&p->maxFrames, p->capacity / 2);
    float g = clamp_gain(initialGain);
    atomic_init(&p->targetGain, g);
    atomic_init(&p->immediateGain, -1.0f);
    p->currentGain = g;
    double rate = sampleRate > 1000.0 ? sampleRate : 48000.0;
    p->glide = (float)(1.0 - exp(-1.0 / (0.015 * rate)));   // ~15 ms time constant
    atomic_init(&p->inputPeak, 0.0f);
    atomic_init(&p->outputPeak, 0.0f);
    atomic_init(&p->underruns, 0);
    atomic_init(&p->overruns, 0);
    atomic_init(&p->skips, 0);
    return p;
}

void wb_pipe_destroy(WBPipe *p) {
    if (!p) return;
    free(p->ring);
    free(p);
}

void wb_pipe_set_latency(WBPipe *p, uint32_t targetFrames, uint32_t maxFrames) {
    uint32_t limit = p->capacity / 2;
    if (targetFrames < 32) targetFrames = 32;
    if (targetFrames > limit) targetFrames = limit;
    if (maxFrames < targetFrames * 2) maxFrames = targetFrames * 2;
    if (maxFrames > p->capacity - 64) maxFrames = p->capacity - 64;
    atomic_store(&p->targetFrames, targetFrames);
    atomic_store(&p->maxFrames, maxFrames);
}

void wb_pipe_set_gain(WBPipe *p, float gain) {
    atomic_store_explicit(&p->targetGain, clamp_gain(gain), memory_order_relaxed);
}

void wb_pipe_set_gain_immediately(WBPipe *p, float gain) {
    float g = clamp_gain(gain);
    atomic_store_explicit(&p->targetGain, g, memory_order_relaxed);
    atomic_store_explicit(&p->immediateGain, g, memory_order_release);
}

void wb_pipe_write(WBPipe *p, const AudioBufferList *in, uint32_t frames) {
    if (!in || in->mNumberBuffers == 0 || frames == 0) return;

    // Work out where left/right samples live, and never read past the end of a buffer.
    const AudioBuffer *b0 = &in->mBuffers[0];
    if (!b0->mData || b0->mNumberChannels == 0) return;
    const float *srcL, *srcR;
    uint32_t strideL, strideR;
    if (in->mNumberBuffers == 1) {
        uint32_t ch = b0->mNumberChannels;
        uint32_t fit = b0->mDataByteSize / (uint32_t)(sizeof(float) * ch);
        if (frames > fit) frames = fit;
        srcL = (const float *)b0->mData;
        srcR = ch > 1 ? srcL + 1 : srcL;
        strideL = strideR = ch;
    } else {
        const AudioBuffer *b1 = &in->mBuffers[1];
        uint32_t fit = b0->mDataByteSize / (uint32_t)(sizeof(float) * b0->mNumberChannels);
        if (frames > fit) frames = fit;
        srcL = (const float *)b0->mData;
        strideL = b0->mNumberChannels;
        if (b1->mData && b1->mNumberChannels > 0) {
            uint32_t fit1 = b1->mDataByteSize / (uint32_t)(sizeof(float) * b1->mNumberChannels);
            if (frames > fit1) frames = fit1;
            srcR = (const float *)b1->mData;
            strideR = b1->mNumberChannels;
        } else {
            srcR = srcL;
            strideR = strideL;
        }
    }
    if (frames == 0) return;

    uint64_t w = atomic_load_explicit(&p->writePos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&p->readPos, memory_order_acquire);
    uint64_t used = w - r;
    uint64_t space = used >= p->capacity ? 0 : p->capacity - used;
    if (frames > space) {
        atomic_fetch_add_explicit(&p->overruns, 1, memory_order_relaxed);
        frames = (uint32_t)space;
        if (frames == 0) return;
    }

    float peak = 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        float l = sane(srcL[(size_t)i * strideL]);
        float rr = sane(srcR[(size_t)i * strideR]);
        float al = fabsf(l), ar = fabsf(rr);
        if (al > peak) peak = al;
        if (ar > peak) peak = ar;
        uint32_t idx = (uint32_t)((w + i) & p->mask);
        p->ring[(size_t)idx * 2] = l;
        p->ring[(size_t)idx * 2 + 1] = rr;
    }
    raise_peak(&p->inputPeak, peak);
    atomic_store_explicit(&p->writePos, w + frames, memory_order_release);
}

void wb_pipe_read(WBPipe *p, float *left, float *right, uint32_t frames) {
    if (frames == 0) return;

    float immediate = atomic_exchange_explicit(&p->immediateGain, -1.0f, memory_order_acquire);
    if (immediate >= 0.0f) p->currentGain = immediate;

    uint64_t r = atomic_load_explicit(&p->readPos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&p->writePos, memory_order_acquire);
    uint64_t avail = w - r;
    uint32_t target = atomic_load_explicit(&p->targetFrames, memory_order_relaxed);
    uint32_t maxFill = atomic_load_explicit(&p->maxFrames, memory_order_relaxed);

    if (!p->primed) {
        if (avail < target) {
            memset(left, 0, sizeof(float) * frames);
            if (right) memset(right, 0, sizeof(float) * frames);
            return;
        }
        p->primed = true;
    }
    if (avail > maxFill) {
        // A backlog built up (e.g. after a hiccup): drop the oldest audio to get back to the target.
        r = w - target;
        avail = target;
        atomic_fetch_add_explicit(&p->skips, 1, memory_order_relaxed);
    }

    uint32_t n = avail < frames ? (uint32_t)avail : frames;
    float goal = atomic_load_explicit(&p->targetGain, memory_order_relaxed);
    float g = p->currentGain;
    const float k = p->glide;
    float peak = 0.0f;

    for (uint32_t i = 0; i < n; i++) {
        g += (goal - g) * k;
        uint32_t idx = (uint32_t)((r + i) & p->mask);
        float l = clamp_unit(p->ring[(size_t)idx * 2] * g);
        float rr = clamp_unit(p->ring[(size_t)idx * 2 + 1] * g);
        float al = fabsf(l), ar = fabsf(rr);
        if (al > peak) peak = al;
        if (ar > peak) peak = ar;
        if (right) {
            left[i] = l;
            right[i] = rr;
        } else {
            left[i] = 0.5f * (l + rr);
        }
    }
    if (fabsf(goal - g) < 1e-5f) g = goal;
    p->currentGain = g;

    if (n < frames) {
        // Ran dry: pad with silence and wait for a fresh cushion before playing again.
        memset(left + n, 0, sizeof(float) * (frames - n));
        if (right) memset(right + n, 0, sizeof(float) * (frames - n));
        atomic_fetch_add_explicit(&p->underruns, 1, memory_order_relaxed);
        p->primed = false;
    }
    raise_peak(&p->outputPeak, peak);
    atomic_store_explicit(&p->readPos, r + n, memory_order_release);
}

float wb_pipe_take_peak(WBPipe *p, bool input) {
    return atomic_exchange_explicit(input ? &p->inputPeak : &p->outputPeak, 0.0f, memory_order_relaxed);
}

WBPipeStats wb_pipe_stats(const WBPipe *p) {
    WBPipe *m = (WBPipe *)p;
    uint64_t w = atomic_load(&m->writePos);
    uint64_t r = atomic_load(&m->readPos);
    WBPipeStats s;
    s.framesWritten = w;
    s.framesRead = r;
    s.underruns = atomic_load(&m->underruns);
    s.overruns = atomic_load(&m->overruns);
    s.skips = atomic_load(&m->skips);
    s.buffered = (uint32_t)(w - r);
    s.currentGain = p->currentGain;
    return s;
}

OSStatus wb_tap_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *inputData,
                       const AudioTimeStamp *inputTime, AudioBufferList *outputData,
                       const AudioTimeStamp *outputTime, void *clientData) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    WBPipe *p = (WBPipe *)clientData;
    if (p && inputData && inputData->mNumberBuffers > 0) {
        const AudioBuffer *b0 = &inputData->mBuffers[0];
        uint32_t channels = inputData->mNumberBuffers == 1 ? b0->mNumberChannels : 1;
        if (channels > 0) {
            uint32_t frames = b0->mDataByteSize / (uint32_t)(sizeof(float) * channels);
            wb_pipe_write(p, inputData, frames);
        }
    }
    // The aggregate has no outputs, but be tidy if it ever does.
    if (outputData) {
        for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
            if (outputData->mBuffers[i].mData)
                memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
        }
    }
    return noErr;
}

OSStatus wb_output_render(void *refCon, AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timeStamp,
                          UInt32 busNumber, UInt32 frames, AudioBufferList *ioData) {
    (void)timeStamp; (void)busNumber;
    if (!ioData || ioData->mNumberBuffers == 0) return noErr;
    WBPipe *p = (WBPipe *)refCon;

    float *left = (float *)ioData->mBuffers[0].mData;
    float *right = ioData->mNumberBuffers > 1 ? (float *)ioData->mBuffers[1].mData : NULL;
    uint32_t fitL = ioData->mBuffers[0].mDataByteSize / sizeof(float);
    if (frames > fitL) frames = fitL;
    if (right) {
        uint32_t fitR = ioData->mBuffers[1].mDataByteSize / sizeof(float);
        if (frames > fitR) frames = fitR;
    }
    if (!left || !p) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            if (ioData->mBuffers[i].mData)
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        if (actionFlags) *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    wb_pipe_read(p, left, right, frames);
    // Any extra channels (unusual for a stereo client format) stay silent.
    for (UInt32 i = 2; i < ioData->mNumberBuffers; i++) {
        if (ioData->mBuffers[i].mData)
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    return noErr;
}
