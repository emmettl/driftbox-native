// Driftbox's bridge to VST 3 plug-ins: CVST3.h, on the SDK's hosting classes. Windows only for now,
// where the SDK's module loader is compiled; elsewhere this is empty.
#ifdef _WIN32

// The SDK's headers pack their structs as they mean to, and use the C library as written.
#pragma clang diagnostic ignored "-Wpragma-pack"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "CVST3.h"

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/connectionproxy.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/processdata.h"
#include "public.sdk/source/vst/utility/stringconvert.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

/// Who the plug-ins are hosted by, for every one of them.
HostApplication &hostApplication() {
  static HostApplication *host = new HostApplication;
  return *host;
}

/// Modules loaded, shared by every plug-in made from each, and let go of when the last is.
std::mutex modulesLock;
std::map<std::string, std::weak_ptr<VST3::Hosting::Module>> modules;

VST3::Hosting::Module::Ptr loadModule(const std::string &path, std::string &error) {
  std::lock_guard<std::mutex> lock(modulesLock);
  if (auto loaded = modules[path].lock()) return loaded;
  auto module = VST3::Hosting::Module::create(path, error);
  if (module) {
    module->getFactory().setHostContext(&hostApplication());
    modules[path] = module;
  }
  return module;
}

void write(const std::string &text, char *out, size_t size) {
  if (!out || size == 0) return;
  size_t count = std::min(text.size(), size - 1);
  std::memcpy(out, text.data(), count);
  out[count] = 0;
}

std::string utf8(const TChar *text) { return VST3::StringConvert::convert(text); }

/// Params set from the main thread, waiting for the audio thread: one writer, one reader, and
/// neither waits.
class ParameterQueue {
public:
  static constexpr uint32_t capacity = 1024;

  /// False when full: the change is kept on the controller, and the next one carries on.
  bool push(ParamID id, ParamValue value) {
    uint32_t head = this->head.load(std::memory_order_relaxed);
    uint32_t next = (head + 1) % capacity;
    if (next == tail.load(std::memory_order_acquire)) return false;
    slots[head] = {id, value};
    this->head.store(next, std::memory_order_release);
    return true;
  }

  template <typename Take>
  void drain(Take take) {
    uint32_t tail = this->tail.load(std::memory_order_relaxed);
    uint32_t head = this->head.load(std::memory_order_acquire);
    while (tail != head) {
      take(slots[tail].id, slots[tail].value);
      tail = (tail + 1) % capacity;
    }
    this->tail.store(tail, std::memory_order_release);
  }

private:
  struct Change {
    ParamID id;
    ParamValue value;
  };
  Change slots[capacity];
  std::atomic<uint32_t> head {0};
  std::atomic<uint32_t> tail {0};
};

/// What a plug-in's own interface tells the host it is doing: its edits go to the processor as a
/// host's would.
class ComponentHandler : public IComponentHandler {
public:
  explicit ComponentHandler(ParameterQueue &queue) : queue(queue) {}

  tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
    queue.push(id, value);
    return kResultOk;
  }
  tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }

  tresult PLUGIN_API queryInterface(const TUID iid, void **object) override {
    if (FUnknownPrivate::iidEqual(iid, IComponentHandler::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
      *object = static_cast<IComponentHandler *>(this);
      return kResultOk;
    }
    *object = nullptr;
    return kNoInterface;
  }
  // Owned by the plug-in it serves, which outlives everything that holds it.
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }

private:
  ParameterQueue &queue;
};

bool isAudioModule(const VST3::Hosting::ClassInfo &info) { return info.category() == kVstAudioEffectClass; }

}  // namespace

struct DBVST3Plugin {
  VST3::Hosting::Module::Ptr module;
  IPtr<IComponent> component;
  IPtr<IAudioProcessor> processor;
  IPtr<IEditController> controller;
  /// Whether the controller is the component itself, as a single-component plug-in's is.
  bool single = false;
  std::unique_ptr<ConnectionProxy> componentConnection;
  std::unique_ptr<ConnectionProxy> controllerConnection;

  ParameterQueue queue;
  ComponentHandler handler {queue};

  HostProcessData data;
  ParameterChanges changes {256};
  EventList events {512};
  ProcessContext context {};
  double sampleRate = 48000;
  int32_t maxFrames = 0;
  int32_t inputChannels = 0;
  int32_t outputChannels = 0;
  bool takesNotes = false;

  /// Set up to play: stereo buses, the rate and the block, active and processing.
  bool start(double rate, int32_t frames, std::string &error) {
    sampleRate = rate;
    maxFrames = std::max(1, frames);
    int32 audioInputs = component->getBusCount(kAudio, kInput);
    int32 audioOutputs = component->getBusCount(kAudio, kOutput);
    if (audioOutputs == 0) {
      error = "it has no audio output";
      return false;
    }
    // Stereo on the main buses, where it will take it, and what it has otherwise on the rest.
    std::vector<SpeakerArrangement> inputs(audioInputs, SpeakerArr::kStereo);
    std::vector<SpeakerArrangement> outputs(audioOutputs, SpeakerArr::kStereo);
    for (int32 index = 1; index < audioInputs; ++index) processor->getBusArrangement(kInput, index, inputs[index]);
    for (int32 index = 1; index < audioOutputs; ++index) processor->getBusArrangement(kOutput, index, outputs[index]);
    processor->setBusArrangements(
      inputs.empty() ? nullptr : inputs.data(), audioInputs, outputs.data(), audioOutputs);
    if (audioInputs > 0) component->activateBus(kAudio, kInput, 0, true);
    component->activateBus(kAudio, kOutput, 0, true);
    takesNotes = component->getBusCount(kEvent, kInput) > 0;
    if (takesNotes) component->activateBus(kEvent, kInput, 0, true);

    ProcessSetup setup {kRealtime, kSample32, maxFrames, sampleRate};
    if (processor->setupProcessing(setup) != kResultOk) {
      error = "it will not play at this rate";
      return false;
    }
    if (component->setActive(true) != kResultOk) {
      error = "it will not start";
      return false;
    }
    if (!data.prepare(*component, maxFrames, kSample32)) {
      error = "its buses could not be set up";
      return false;
    }
    SpeakerArrangement arrangement = 0;
    if (audioInputs > 0 && processor->getBusArrangement(kInput, 0, arrangement) == kResultOk) {
      inputChannels = SpeakerArr::getChannelCount(arrangement);
    }
    if (processor->getBusArrangement(kOutput, 0, arrangement) == kResultOk) {
      outputChannels = SpeakerArr::getChannelCount(arrangement);
    }
    data.inputParameterChanges = &changes;
    data.inputEvents = takesNotes ? &events : nullptr;
    data.processContext = &context;
    context.sampleRate = sampleRate;
    processor->setProcessing(true);
    return true;
  }

  void stop() {
    if (processor) processor->setProcessing(false);
    if (component) component->setActive(false);
    data.unprepare();
    if (componentConnection) componentConnection->disconnect();
    if (controllerConnection) controllerConnection->disconnect();
    componentConnection.reset();
    controllerConnection.reset();
    if (controller) {
      controller->setComponentHandler(nullptr);
      if (!single) controller->terminate();
    }
    if (component) component->terminate();
    controller = nullptr;
    processor = nullptr;
    component = nullptr;
  }
};

extern "C" {

int32_t dbvst3_classes(const char *path, DBVST3Class *classes, int32_t capacity, char *error, size_t errorSize) {
  std::string why;
  auto module = loadModule(path, why);
  if (!module) {
    write(why.empty() ? "it would not load" : why, error, errorSize);
    return -1;
  }
  int32_t count = 0;
  for (const auto &info : module->getFactory().classInfos()) {
    if (!isAudioModule(info)) continue;
    if (classes && count < capacity) {
      DBVST3Class &out = classes[count];
      write(info.ID().toString(), out.classID, sizeof(out.classID));
      write(info.name(), out.name, sizeof(out.name));
      write(info.vendor(), out.vendor, sizeof(out.vendor));
      write(info.version(), out.version, sizeof(out.version));
      write(info.subCategoriesString(), out.subCategories, sizeof(out.subCategories));
    }
    ++count;
  }
  return count;
}

DBVST3Plugin *dbvst3_open(
  const char *path, const char *classID, double sampleRate, int32_t maxFrames, char *error, size_t errorSize) {
  std::string why;
  auto module = loadModule(path, why);
  if (!module) {
    write(why.empty() ? "it would not load" : why, error, errorSize);
    return nullptr;
  }
  auto uid = VST3::UID::fromString(std::string(classID));
  if (!uid) {
    write("its class ID is not one", error, errorSize);
    return nullptr;
  }
  const auto &factory = module->getFactory();
  auto plugin = std::make_unique<DBVST3Plugin>();
  plugin->module = module;
  plugin->component = factory.createInstance<IComponent>(*uid);
  if (!plugin->component || plugin->component->initialize(&hostApplication()) != kResultOk) {
    write("it has no such plug-in, or it would not start", error, errorSize);
    plugin->component = nullptr;
    return nullptr;
  }
  plugin->processor = FUnknownPtr<IAudioProcessor>(plugin->component);
  if (!plugin->processor) {
    write("it does not process audio", error, errorSize);
    plugin->stop();
    return nullptr;
  }

  // Its controller: the component itself, or a class of its own, initialized and joined to it.
  if (auto same = FUnknownPtr<IEditController>(plugin->component)) {
    plugin->controller = same;
    plugin->single = true;
  } else {
    TUID controllerID;
    if (plugin->component->getControllerClassId(controllerID) == kResultOk) {
      plugin->controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(controllerID));
      if (plugin->controller && plugin->controller->initialize(&hostApplication()) != kResultOk) {
        plugin->controller = nullptr;
      }
    }
    FUnknownPtr<IConnectionPoint> componentPoint(plugin->component);
    FUnknownPtr<IConnectionPoint> controllerPoint(plugin->controller);
    if (componentPoint && controllerPoint) {
      plugin->componentConnection = std::make_unique<ConnectionProxy>(componentPoint);
      plugin->controllerConnection = std::make_unique<ConnectionProxy>(controllerPoint);
      plugin->componentConnection->connect(controllerPoint);
      plugin->controllerConnection->connect(componentPoint);
    }
  }
  if (plugin->controller) {
    plugin->controller->setComponentHandler(&plugin->handler);
    // The controller starts from what the processor holds, as a host hands it over.
    if (!plugin->single) {
      MemoryStream stream;
      if (plugin->component->getState(&stream) == kResultOk) {
        stream.seek(0, IBStream::kIBSeekSet, nullptr);
        plugin->controller->setComponentState(&stream);
      }
    }
  }
  if (!plugin->start(sampleRate, maxFrames, why)) {
    write(why, error, errorSize);
    plugin->stop();
    return nullptr;
  }
  return plugin.release();
}

void dbvst3_close(DBVST3Plugin *plugin) {
  if (!plugin) return;
  plugin->stop();
  delete plugin;
}

int32_t dbvst3_input_channels(const DBVST3Plugin *plugin) { return plugin->inputChannels; }
int32_t dbvst3_output_channels(const DBVST3Plugin *plugin) { return plugin->outputChannels; }
bool dbvst3_takes_notes(const DBVST3Plugin *plugin) { return plugin->takesNotes; }
int32_t dbvst3_latency(const DBVST3Plugin *plugin) {
  return static_cast<int32_t>(plugin->processor->getLatencySamples());
}

void dbvst3_process(
  DBVST3Plugin *plugin, const float *const *inputs, int32_t inputChannels, float *const *outputs,
  int32_t outputChannels, int32_t frames, double tempo, double beat, bool running, const uint64_t *events,
  int32_t eventCount) {
  HostProcessData &data = plugin->data;
  frames = std::min(frames, plugin->maxFrames);
  data.numSamples = frames;

  // What the main thread set since the last block, at its start.
  plugin->changes.clearQueue();
  plugin->queue.drain([plugin](ParamID id, ParamValue value) {
    int32 index = 0;
    if (IParamValueQueue *queue = plugin->changes.addParameterData(id, index)) {
      int32 point = 0;
      queue->addPoint(0, value, point);
    }
  });

  // Notes on and off, where they fall in the block.
  plugin->events.clear();
  if (plugin->takesNotes && events) {
    for (int32_t index = 0; index < eventCount; ++index) {
      uint64_t packed = events[index];
      int32 offset = static_cast<int32>(packed >> 32);
      uint8_t status = static_cast<uint8_t>(packed >> 16);
      uint8_t pitch = static_cast<uint8_t>(packed >> 8) & 0x7F;
      uint8_t velocity = static_cast<uint8_t>(packed) & 0x7F;
      uint8_t kind = status & 0xF0;
      Event event {};
      event.busIndex = 0;
      event.sampleOffset = std::clamp(offset, 0, std::max(0, frames - 1));
      if (kind == 0x90 && velocity > 0) {
        event.type = Event::kNoteOnEvent;
        event.noteOn = {static_cast<int16>(status & 0x0F), static_cast<int16>(pitch), 0, velocity / 127.f, 0, -1};
      } else if (kind == 0x80 || kind == 0x90) {
        event.type = Event::kNoteOffEvent;
        event.noteOff = {static_cast<int16>(status & 0x0F), static_cast<int16>(pitch), velocity / 127.f, -1, 0};
      } else {
        continue;
      }
      plugin->events.addEvent(event);
    }
  }

  ProcessContext &context = plugin->context;
  context.state = ProcessContext::kTempoValid | ProcessContext::kProjectTimeMusicValid;
  if (running) context.state |= ProcessContext::kPlaying;
  context.tempo = tempo;
  context.projectTimeMusic = beat;

  // The rack's channels into the main input, and out of the main output; silence where they
  // differ in number.
  if (data.numInputs > 0 && data.inputs[0].numChannels > 0) {
    for (int32 channel = 0; channel < data.inputs[0].numChannels; ++channel) {
      Sample32 *to = data.inputs[0].channelBuffers32[channel];
      if (inputs && channel < inputChannels && inputs[channel]) {
        std::memcpy(to, inputs[channel], sizeof(float) * frames);
      } else {
        std::memset(to, 0, sizeof(float) * frames);
      }
    }
  }
  plugin->processor->process(data);
  for (int32_t channel = 0; channel < outputChannels; ++channel) {
    if (!outputs || !outputs[channel]) continue;
    if (data.numOutputs > 0 && channel < data.outputs[0].numChannels) {
      std::memcpy(outputs[channel], data.outputs[0].channelBuffers32[channel], sizeof(float) * frames);
    } else if (data.numOutputs > 0 && data.outputs[0].numChannels == 1) {
      // A mono plug-in in a stereo rack: the one channel on both sides.
      std::memcpy(outputs[channel], data.outputs[0].channelBuffers32[0], sizeof(float) * frames);
    } else {
      std::memset(outputs[channel], 0, sizeof(float) * frames);
    }
  }
}

int32_t dbvst3_parameter_count(const DBVST3Plugin *plugin) {
  return plugin->controller ? plugin->controller->getParameterCount() : 0;
}

bool dbvst3_parameter(const DBVST3Plugin *plugin, int32_t index, DBVST3Parameter *parameter) {
  ParameterInfo info {};
  if (!plugin->controller || plugin->controller->getParameterInfo(index, info) != kResultOk) return false;
  parameter->id = info.id;
  write(utf8(info.title), parameter->title, sizeof(parameter->title));
  write(utf8(info.units), parameter->units, sizeof(parameter->units));
  parameter->stepCount = info.stepCount;
  parameter->defaultValue = info.defaultNormalizedValue;
  int32 unset = ParameterInfo::kIsReadOnly | ParameterInfo::kIsHidden | ParameterInfo::kIsProgramChange |
    ParameterInfo::kIsBypass;
  parameter->automatable = (info.flags & ParameterInfo::kCanAutomate) && !(info.flags & unset);
  return true;
}

double dbvst3_get_parameter(const DBVST3Plugin *plugin, uint32_t id) {
  return plugin->controller ? plugin->controller->getParamNormalized(id) : 0;
}

void dbvst3_set_parameter(DBVST3Plugin *plugin, uint32_t id, double value) {
  value = std::clamp(value, 0.0, 1.0);
  if (plugin->controller) plugin->controller->setParamNormalized(id, value);
  plugin->queue.push(id, value);
}

bool dbvst3_parameter_text(const DBVST3Plugin *plugin, uint32_t id, double value, char *text, size_t size) {
  String128 string {};
  if (!plugin->controller || plugin->controller->getParamStringByValue(id, value, string) != kResultOk) {
    return false;
  }
  write(utf8(string), text, size);
  return true;
}

// The state as one run of bytes: the processor's, its length first, then the controller's.
int64_t dbvst3_state(DBVST3Plugin *plugin, uint8_t *buffer, int64_t capacity) {
  MemoryStream component;
  if (plugin->component->getState(&component) != kResultOk) return -1;
  MemoryStream controller;
  if (plugin->controller && !plugin->single) plugin->controller->getState(&controller);
  int64_t componentSize = 0;
  component.tell(&componentSize);
  int64_t controllerSize = 0;
  controller.tell(&controllerSize);
  int64_t total = 8 + componentSize + controllerSize;
  if (!buffer || capacity < total) return total;
  for (int shift = 0; shift < 8; ++shift) buffer[shift] = static_cast<uint8_t>(componentSize >> (shift * 8));
  if (componentSize > 0) std::memcpy(buffer + 8, component.getData(), componentSize);
  if (controllerSize > 0) std::memcpy(buffer + 8 + componentSize, controller.getData(), controllerSize);
  return total;
}

bool dbvst3_set_state(DBVST3Plugin *plugin, const uint8_t *data, int64_t size) {
  if (!data || size < 8) return false;
  int64_t componentSize = 0;
  for (int shift = 0; shift < 8; ++shift) componentSize |= static_cast<int64_t>(data[shift]) << (shift * 8);
  if (componentSize < 0 || 8 + componentSize > size) return false;
  MemoryStream component(const_cast<uint8_t *>(data + 8), componentSize);
  if (plugin->component->setState(&component) != kResultOk) return false;
  if (plugin->controller && !plugin->single) {
    component.seek(0, IBStream::kIBSeekSet, nullptr);
    plugin->controller->setComponentState(&component);
    int64_t controllerSize = size - 8 - componentSize;
    if (controllerSize > 0) {
      MemoryStream controller(const_cast<uint8_t *>(data + 8 + componentSize), controllerSize);
      plugin->controller->setState(&controller);
    }
  }
  return true;
}

}  // extern "C"

#endif
