// A VST 3 module for the host's tests to load, built from the SDK as any plug-in is. It holds the
// two ways a plug-in is made:
//
// - Driftbox Test Gain, an effect whose processor and controller are separate classes, as most
//   plug-ins' are: one param, its gain, which it keeps as its state, and 32 samples of latency.
// - Driftbox Test Synth, an instrument that is one component: a sine for each note held, at its
//   velocity, and a level.
//
// Windows only, as the host is for now.
#ifdef _WIN32

// The SDK's headers pack their structs as they mean to, and use the C library as written.
#pragma clang diagnostic ignored "-Wpragma-pack"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

#include <cmath>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

constexpr ParamID gainID = 0;
constexpr ParamID levelID = 0;

const FUID gainProcessorUID(0x44726966, 0x74626F78, 0x54657374, 0x4761696E);
const FUID gainControllerUID(0x44726966, 0x74626F78, 0x54657374, 0x4374726C);
const FUID synthUID(0x44726966, 0x74626F78, 0x54657374, 0x53796E74);

/// The last value each changed param has in this block.
template <typename Apply>
void readChanges(ProcessData &data, Apply apply) {
  IParameterChanges *changes = data.inputParameterChanges;
  if (!changes) return;
  for (int32 index = 0; index < changes->getParameterCount(); ++index) {
    IParamValueQueue *queue = changes->getParameterData(index);
    if (!queue || queue->getPointCount() == 0) continue;
    int32 offset = 0;
    ParamValue value = 0;
    if (queue->getPoint(queue->getPointCount() - 1, offset, value) == kResultOk) {
      apply(queue->getParameterId(), value);
    }
  }
}

double readValue(IBStream *state, double fallback) {
  IBStreamer streamer(state, kLittleEndian);
  double value = fallback;
  return streamer.readDouble(value) ? value : fallback;
}

class GainProcessor : public AudioEffect {
public:
  GainProcessor() { setControllerClass(gainControllerUID); }
  static FUnknown *create(void *) { return static_cast<IAudioProcessor *>(new GainProcessor); }

  tresult PLUGIN_API initialize(FUnknown *context) override {
    tresult result = AudioEffect::initialize(context);
    if (result != kResultOk) return result;
    addAudioInput(STR16("Stereo In"), SpeakerArr::kStereo);
    addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
    return kResultOk;
  }

  tresult PLUGIN_API process(ProcessData &data) override {
    readChanges(data, [this](ParamID id, ParamValue value) {
      if (id == gainID) gain = value;
    });
    if (data.numInputs == 0 || data.numOutputs == 0) return kResultOk;
    for (int32 channel = 0; channel < data.outputs[0].numChannels; ++channel) {
      Sample32 *out = data.outputs[0].channelBuffers32[channel];
      const Sample32 *in =
        channel < data.inputs[0].numChannels ? data.inputs[0].channelBuffers32[channel] : nullptr;
      for (int32 frame = 0; frame < data.numSamples; ++frame) {
        out[frame] = in ? in[frame] * static_cast<float>(gain) : 0;
      }
    }
    return kResultOk;
  }

  uint32 PLUGIN_API getLatencySamples() override { return 32; }

  tresult PLUGIN_API setState(IBStream *state) override {
    gain = readValue(state, gain);
    return kResultOk;
  }

  tresult PLUGIN_API getState(IBStream *state) override {
    IBStreamer streamer(state, kLittleEndian);
    streamer.writeDouble(gain);
    return kResultOk;
  }

private:
  double gain = 0.5;
};

class GainController : public EditController {
public:
  static FUnknown *create(void *) { return static_cast<IEditController *>(new GainController); }

  tresult PLUGIN_API initialize(FUnknown *context) override {
    tresult result = EditController::initialize(context);
    if (result != kResultOk) return result;
    parameters.addParameter(STR16("Gain"), STR16("x"), 0, 0.5, ParameterInfo::kCanAutomate, gainID);
    return kResultOk;
  }

  tresult PLUGIN_API setComponentState(IBStream *state) override {
    setParamNormalized(gainID, readValue(state, getParamNormalized(gainID)));
    return kResultOk;
  }
};

class Synth : public SingleComponentEffect {
public:
  static FUnknown *create(void *) { return static_cast<IAudioProcessor *>(new Synth); }

  tresult PLUGIN_API initialize(FUnknown *context) override {
    tresult result = SingleComponentEffect::initialize(context);
    if (result != kResultOk) return result;
    addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
    addEventInput(STR16("Notes"), 16);
    parameters.addParameter(STR16("Level"), nullptr, 0, 0.8, ParameterInfo::kCanAutomate, levelID);
    return kResultOk;
  }

  tresult PLUGIN_API setupProcessing(ProcessSetup &setup) override {
    sampleRate = setup.sampleRate;
    return SingleComponentEffect::setupProcessing(setup);
  }

  tresult PLUGIN_API process(ProcessData &data) override {
    readChanges(data, [this](ParamID id, ParamValue value) {
      if (id == levelID) {
        level = value;
        setParamNormalized(levelID, value);
      }
    });
    if (data.numOutputs == 0) return kResultOk;
    IEventList *events = data.inputEvents;
    int32 eventCount = events ? events->getEventCount() : 0;
    int32 next = 0;
    Sample32 **out = data.outputs[0].channelBuffers32;
    for (int32 frame = 0; frame < data.numSamples; ++frame) {
      Event event {};
      while (next < eventCount && events->getEvent(next, event) == kResultOk && event.sampleOffset <= frame) {
        if (event.type == Event::kNoteOnEvent) {
          pitch = event.noteOn.pitch;
          velocity = event.noteOn.velocity;
          phase = 0;
        } else if (event.type == Event::kNoteOffEvent && event.noteOff.pitch == pitch) {
          velocity = 0;
        }
        ++next;
      }
      float sample = 0;
      if (velocity > 0) {
        double frequency = 440.0 * std::pow(2.0, (pitch - 69) / 12.0);
        sample = static_cast<float>(std::sin(phase) * velocity * level);
        phase += 2 * 3.14159265358979 * frequency / sampleRate;
      }
      for (int32 channel = 0; channel < data.outputs[0].numChannels; ++channel) out[channel][frame] = sample;
    }
    return kResultOk;
  }

  tresult PLUGIN_API setState(IBStream *state) override {
    level = readValue(state, level);
    setParamNormalized(levelID, level);
    return kResultOk;
  }

  tresult PLUGIN_API getState(IBStream *state) override {
    IBStreamer streamer(state, kLittleEndian);
    streamer.writeDouble(level);
    return kResultOk;
  }

private:
  double sampleRate = 48000;
  double level = 0.8;
  int16 pitch = 60;
  float velocity = 0;
  double phase = 0;
};

}  // namespace

BEGIN_FACTORY("Driftbox", "", "", PFactoryInfo::kUnicode)

DEF_CLASS2(
  INLINE_UID_FROM_FUID(gainProcessorUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Driftbox Test Gain",
  Vst::kDistributable, "Fx", "1.0.0", kVstVersionString, GainProcessor::create)
DEF_CLASS2(
  INLINE_UID_FROM_FUID(gainControllerUID), PClassInfo::kManyInstances, kVstComponentControllerClass,
  "Driftbox Test Gain Controller", 0, "", "1.0.0", kVstVersionString, GainController::create)
DEF_CLASS2(
  INLINE_UID_FROM_FUID(synthUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Driftbox Test Synth", 0,
  "Instrument|Synth", "1.0.0", kVstVersionString, Synth::create)

END_FACTORY

#endif
