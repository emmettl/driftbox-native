// Driftbox's bridge to VST 3 plug-ins, in C so that Swift can call it: find the plug-ins a module
// holds, make one, and play audio and notes through it, its params and its state, on Steinberg's
// VST 3 SDK (MIT), which lives beside this under include/ and sdk/.
//
// A plug-in made here is driven from two threads, as a host's are: everything but `dbvst3_process`
// from one — the main one — and `dbvst3_process` from the audio thread alone, which never waits on
// the other. Params set from the main thread reach the audio thread through a queue.
#ifndef CVST3_H
#define CVST3_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One plug-in a module holds: an audio processor class of it.
typedef struct DBVST3Class {
  /// Its class ID, as 32 hexadecimal digits: what a patch keeps it by.
  char classID[33];
  char name[128];
  char vendor[128];
  char version[64];
  /// The VST 3 subcategories, separated by `|`, as `Instrument|Synth` or `Fx|Delay`.
  char subCategories[128];
} DBVST3Class;

/// The audio processor classes of the module at `path` (UTF-8): a `.vst3` bundle folder or file.
/// Writes up to `capacity` into `classes` and returns how many there are, or -1, with why in
/// `error`, when the module will not load.
int32_t dbvst3_classes(
  const char *path, DBVST3Class *classes, int32_t capacity, char *error, size_t errorSize);

typedef struct DBVST3Plugin DBVST3Plugin;

/// A plug-in of class `classID` from the module at `path`, set up to play stereo at `sampleRate` in
/// blocks of up to `maxFrames`, and processing. Null, with why in `error`, when it will not.
DBVST3Plugin *dbvst3_open(
  const char *path, const char *classID, double sampleRate, int32_t maxFrames, char *error, size_t errorSize);

/// Stopped, released, and its module let go of if nothing else holds it.
void dbvst3_close(DBVST3Plugin *plugin);

/// Its main audio buses' channels, input and output, and whether it takes notes.
int32_t dbvst3_input_channels(const DBVST3Plugin *plugin);
int32_t dbvst3_output_channels(const DBVST3Plugin *plugin);
bool dbvst3_takes_notes(const DBVST3Plugin *plugin);

/// How late its output is, in samples.
int32_t dbvst3_latency(const DBVST3Plugin *plugin);

/// One block, on the audio thread: `frames` of `inputs` (null for none) into `outputs`, each
/// `channels` long; with the transport's tempo, where it is in beats and whether it runs; and MIDI
/// `events`, each packed as the rack packs them — the frame in the top half, then the status and the
/// two data bytes — notes on and off becoming the plug-in's notes.
void dbvst3_process(
  DBVST3Plugin *plugin, const float *const *inputs, int32_t inputChannels, float *const *outputs,
  int32_t outputChannels, int32_t frames, double tempo, double beat, bool running, const uint64_t *events,
  int32_t eventCount);

/// One of its params.
typedef struct DBVST3Parameter {
  uint32_t id;
  char title[128];
  char units[32];
  /// 0 for a continuous param; otherwise how many steps past the first it has.
  int32_t stepCount;
  double defaultValue;
  /// Whether a hand can set it: not read-only, not hidden, not its program list or bypass.
  bool automatable;
} DBVST3Parameter;

int32_t dbvst3_parameter_count(const DBVST3Plugin *plugin);
/// Its `index`th param; false past the end.
bool dbvst3_parameter(const DBVST3Plugin *plugin, int32_t index, DBVST3Parameter *parameter);
/// A param's value, 0...1.
double dbvst3_get_parameter(const DBVST3Plugin *plugin, uint32_t id);
/// Set a param, 0...1: on its controller now, and in the processor at the start of the next block.
void dbvst3_set_parameter(DBVST3Plugin *plugin, uint32_t id, double value);
/// What a param at `value` says it is, as its controller writes it.
bool dbvst3_parameter_text(const DBVST3Plugin *plugin, uint32_t id, double value, char *text, size_t size);

/// Its state, processor and controller together, into `buffer` when it fits in `capacity`: how
/// many bytes it is, or -1 when it cannot say. Asking with no buffer says how many.
int64_t dbvst3_state(DBVST3Plugin *plugin, uint8_t *buffer, int64_t capacity);
/// Its state as `dbvst3_state` wrote it; false when it would not take it.
bool dbvst3_set_state(DBVST3Plugin *plugin, const uint8_t *data, int64_t size);

#ifdef __cplusplus
}
#endif

#endif
