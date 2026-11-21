#ifndef WORKBENCH_AUDIO_RT_H
#define WORKBENCH_AUDIO_RT_H

// Real-time half of per-app volume. Kept in C so the two audio threads never allocate, lock or
// touch reference counting.
//
//   tapped app ──▶ process tap ──▶ private aggregate (tap only) ──wb_tap_ioproc──▶ WBPipe
//   WBPipe ──wb_output_render (gain, clamp)──▶ HAL output unit ──▶ the app's output device
//
// The pipe is a single-producer/single-consumer ring of interleaved stereo float frames.

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WBPipe WBPipe;

/// Creates a pipe holding up to `capacityFrames` (rounded up to a power of two) stereo frames.
/// The gain starts at `initialGain` and glides to whatever wb_pipe_set_gain asks for over ~15 ms.
WBPipe *_Nullable wb_pipe_create(uint32_t capacityFrames, double sampleRate, float initialGain);

/// Frees the pipe. Only call once neither audio thread can run any more.
void wb_pipe_destroy(WBPipe *_Nullable pipe);

/// Output waits until `targetFrames` are buffered before it starts (and again after running dry).
/// If more than `maxFrames` pile up, the reader skips ahead to `targetFrames` to keep latency low.
void wb_pipe_set_latency(WBPipe *_Nonnull pipe, uint32_t targetFrames, uint32_t maxFrames);

/// Target gain, clamped to 0…1: this can only make an app quieter, never louder.
void wb_pipe_set_gain(WBPipe *_Nonnull pipe, float gain);

/// Jump straight to `gain` with no glide (tests, start-up).
void wb_pipe_set_gain_immediately(WBPipe *_Nonnull pipe, float gain);

/// Writer side: copies `frames` frames from an interleaved (1 buffer, N channels) or
/// non-interleaved (N buffers) Float32 buffer list. Mono is duplicated to both sides.
void wb_pipe_write(WBPipe *_Nonnull pipe, const AudioBufferList *_Nullable input, uint32_t frames);

/// Reader side: fills `frames` samples per side, applying the gain. Silence while priming or dry.
/// `right` may be NULL for a mono destination (gets the average of both sides).
void wb_pipe_read(WBPipe *_Nonnull pipe, float *_Nonnull left, float *_Nullable right, uint32_t frames);

/// Peak absolute sample since the last call: before the gain (`input`) or after it (output).
float wb_pipe_take_peak(WBPipe *_Nonnull pipe, bool input);

typedef struct {
    uint64_t framesWritten;
    uint64_t framesRead;
    uint32_t underruns;   // reader ran dry after starting
    uint32_t overruns;    // writer found the ring full (frames dropped)
    uint32_t skips;       // reader dropped a backlog to cut latency
    uint32_t buffered;    // frames waiting right now
    float currentGain;
} WBPipeStats;

WBPipeStats wb_pipe_stats(const WBPipe *_Nonnull pipe);

/// AudioDeviceIOProc for the tap-only aggregate device. `clientData` is the WBPipe.
OSStatus wb_tap_ioproc(AudioObjectID device,
                       const AudioTimeStamp *_Nonnull now,
                       const AudioBufferList *_Nonnull inputData,
                       const AudioTimeStamp *_Nonnull inputTime,
                       AudioBufferList *_Nonnull outputData,
                       const AudioTimeStamp *_Nonnull outputTime,
                       void *_Nullable clientData);

/// AURenderCallback for the HAL output unit (client format: non-interleaved Float32 stereo).
/// `refCon` is the WBPipe.
OSStatus wb_output_render(void *_Nonnull refCon,
                          AudioUnitRenderActionFlags *_Nonnull actionFlags,
                          const AudioTimeStamp *_Nonnull timeStamp,
                          UInt32 busNumber,
                          UInt32 frames,
                          AudioBufferList *_Nullable ioData);

#ifdef __cplusplus
}
#endif

#endif
