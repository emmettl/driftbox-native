// Driftbox's bridge to VST 3 plug-ins: CVST3.h, on the SDK's hosting classes. Windows only for now,
// where the SDK's module loader is compiled; elsewhere this is empty.
#ifdef _WIN32

// The SDK's headers pack their structs as they mean to, and use the C library as written.
#pragma clang diagnostic ignored "-Wpragma-pack"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "CVST3.h"

// Windows' own, for a plug-in's editor window: without its min and max, which the C++ library has.
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
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
#include <bitset>
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

/// Who is told when a plug-in changes itself.
struct Listener {
  std::atomic<DBVST3Listener> function {nullptr};
  std::atomic<void *> context {nullptr};

  void tell(int64_t id) const {
    if (auto told = function.load(std::memory_order_acquire)) told(context.load(std::memory_order_acquire), id);
  }
};

/// What a plug-in's own interface tells the host it is doing: its edits go to the processor as a
/// host's would, and the listener hears of each, and of anything else it changes.
class ComponentHandler : public IComponentHandler {
public:
  ComponentHandler(ParameterQueue &queue, Listener &listener) : queue(queue), listener(listener) {}

  tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
    queue.push(id, value);
    listener.tell(id);
    return kResultOk;
  }
  tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API restartComponent(int32) override {
    listener.tell(-1);
    return kResultOk;
  }

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
  Listener &listener;
};

bool isAudioModule(const VST3::Hosting::ClassInfo &info) { return info.category() == kVstAudioEffectClass; }

}  // namespace

struct EditorWindow;

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
  Listener listener;
  ComponentHandler handler {queue, listener};
  /// Values the audio thread gave the processor — a macro's, or the processor's own — for the
  /// controller, which the main thread tells.
  ParameterQueue toController;

  /// Each macro's mapping, written on the main thread and read whole on the audio thread: the
  /// param's ID in the low 32 bits, then whether it is mapped, then a count of mappings made, so a
  /// new one is sent at once whatever the macro was.
  std::atomic<uint64_t> macros[4] {};
  uint64_t sentMapping[4] {};
  float sentValue[4] {-1, -1, -1, -1};

  /// The params the plug-in takes the mod wheel, sustain and pitch bend on, where it does.
  ParamID midiParams[3] {};
  bool midiMapped[3] {};
  /// The notes sounding on each channel, for all notes off.
  std::bitset<128> held[16];

  HostProcessData data;
  ParameterChanges changes {256};
  ParameterChanges outputChanges {64};
  /// Its editor's window, while it is open.
  EditorWindow *editor = nullptr;
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
    data.outputParameterChanges = &outputChanges;
    data.inputEvents = takesNotes ? &events : nullptr;
    data.processContext = &context;
    context.sampleRate = sampleRate;
    processor->setProcessing(true);
    return true;
  }

  /// A param's value, 0...1, at `offset` into the block.
  void change(ParamID id, ParamValue value, int32 offset) {
    int32 index = 0;
    if (IParamValueQueue *queue = changes.addParameterData(id, index)) {
      int32 point = 0;
      queue->addPoint(offset, value, point);
    }
  }

  /// The params the plug-in takes MIDI controllers on, asked of its controller once it is made.
  void findMIDIParams() {
    FUnknownPtr<IMidiMapping> mapping(controller);
    if (!mapping || !takesNotes) return;
    const CtrlNumber numbers[3] = {
      ControllerNumbers::kCtrlModWheel, ControllerNumbers::kCtrlSustainOnOff, ControllerNumbers::kPitchBend};
    for (int index = 0; index < 3; ++index) {
      midiMapped[index] = mapping->getMidiControllerAssignment(0, 0, numbers[index], midiParams[index]) == kResultOk;
    }
  }

  /// The rack's MIDI as the plug-in's: notes as its notes; the mod wheel, sustain and bend on the
  /// params it takes them on; all notes off as a note off for each note sounding.
  void readEvents(const uint64_t *packed, int32_t count, int32_t frames) {
    events.clear();
    if (!takesNotes || !packed) return;
    for (int32_t index = 0; index < count; ++index) {
      uint64_t message = packed[index];
      int32 offset = std::clamp(static_cast<int32>(message >> 32), 0, std::max(0, frames - 1));
      uint8_t status = static_cast<uint8_t>(message >> 16);
      uint8_t data1 = static_cast<uint8_t>(message >> 8) & 0x7F;
      uint8_t data2 = static_cast<uint8_t>(message) & 0x7F;
      uint8_t kind = status & 0xF0;
      int16 channel = static_cast<int16>(status & 0x0F);
      Event event {};
      event.busIndex = 0;
      event.sampleOffset = offset;
      if (kind == 0x90 && data2 > 0) {
        event.type = Event::kNoteOnEvent;
        event.noteOn = {channel, static_cast<int16>(data1), 0, data2 / 127.f, 0, -1};
        held[channel].set(data1);
        events.addEvent(event);
      } else if (kind == 0x80 || kind == 0x90) {
        event.type = Event::kNoteOffEvent;
        event.noteOff = {channel, static_cast<int16>(data1), data2 / 127.f, -1, 0};
        held[channel].reset(data1);
        events.addEvent(event);
      } else if (kind == 0xB0 && data1 == ControllerNumbers::kCtrlAllNotesOff) {
        event.type = Event::kNoteOffEvent;
        for (int16 pitch = 0; pitch < 128; ++pitch) {
          if (!held[channel].test(pitch)) continue;
          event.noteOff = {channel, pitch, 0, -1, 0};
          events.addEvent(event);
        }
        held[channel].reset();
      } else if (kind == 0xB0 && data1 == ControllerNumbers::kCtrlModWheel && midiMapped[0]) {
        change(midiParams[0], data2 / 127.0, offset);
      } else if (kind == 0xB0 && data1 == ControllerNumbers::kCtrlSustainOnOff && midiMapped[1]) {
        change(midiParams[1], data2 >= 64 ? 1 : 0, offset);
      } else if (kind == 0xE0 && midiMapped[2]) {
        change(midiParams[2], (data1 | data2 << 7) / 16383.0, offset);
      }
    }
  }

  /// One block through it, on the audio thread.
  void process(
    const float *const *inputs, int32_t inputChannels, float *const *outputs, int32_t outputChannels,
    int32_t frames, double tempo, double beat, bool running, const uint64_t *packed, int32_t eventCount,
    const float *macroValues, int32_t macroCount) {
    frames = std::min(frames, maxFrames);
    data.numSamples = frames;

    // What the main thread set since the last block, at its start; then the macros that moved, or
    // were mapped anew, each onto its param; then the block's MIDI.
    changes.clearQueue();
    queue.drain([this](ParamID id, ParamValue value) { change(id, value, 0); });
    for (int32_t macro = 0; macro < std::min(macroCount, 4); ++macro) {
      uint64_t mapping = macros[macro].load(std::memory_order_acquire);
      float value = std::clamp(macroValues[macro], 0.f, 1.f);
      bool mapped = mapping & (uint64_t(1) << 32);
      if (!mapped || (mapping == sentMapping[macro] && value == sentValue[macro])) continue;
      ParamID id = static_cast<ParamID>(mapping);
      change(id, value, 0);
      toController.push(id, value);
      sentMapping[macro] = mapping;
      sentValue[macro] = value;
    }
    readEvents(packed, eventCount, frames);

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
    outputChanges.clearQueue();
    processor->process(data);
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
    // What the processor changed of its own params, as the block ends, for its controller.
    for (int32 index = 0; index < outputChanges.getParameterCount(); ++index) {
      IParamValueQueue *changed = outputChanges.getParameterData(index);
      int32 offset = 0;
      ParamValue value = 0;
      if (changed && changed->getPointCount() > 0 &&
          changed->getPoint(changed->getPointCount() - 1, offset, value) == kResultOk) {
        toController.push(changed->getParameterId(), value);
      }
    }
  }

  /// What the audio thread gave the processor, told to the controller on the main thread: how many
  /// values.
  int32_t settle() {
    int32_t count = 0;
    toController.drain([this, &count](ParamID id, ParamValue value) {
      if (controller) controller->setParamNormalized(id, value);
      ++count;
    });
    return count;
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

// MARK: - Editors

namespace {

const wchar_t *const editorClass = L"DriftboxPlugInEditor";
constexpr UINT_PTR idleTimer = 1;

std::wstring wide(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, 0, text ? text : "", -1, nullptr, 0);
  std::wstring out(count > 1 ? count - 1 : 0, L'\0');
  if (count > 1) MultiByteToWideChar(CP_UTF8, 0, text, -1, out.data(), count);
  return out;
}

}  // namespace

/// A plug-in's own editor, in a window of its own on the main thread: sized to the view, resized
/// when the view asks or, where it may be, by hand, and scaled with the monitor it is on. While it
/// is open, what the audio thread gave the processor is told to the controller a few times a
/// second, so the editor follows the macros.
struct EditorWindow : public IPlugFrame {
  DBVST3Plugin *plugin = nullptr;
  IPtr<IPlugView> view;
  HWND window = nullptr;
  DBVST3EditorClosed closed = nullptr;
  void *context = nullptr;
  /// Set while the host sizes the window to the view, so the size it lands on is not sent back.
  bool sizing = false;

  /// The window's outer size for a view of `size`, at the window's DPI.
  void fit(const ViewRect &size) {
    RECT frame {0, 0, size.getWidth(), size.getHeight()};
    AdjustWindowRectExForDpi(
      &frame, static_cast<DWORD>(GetWindowLongW(window, GWL_STYLE)), FALSE,
      static_cast<DWORD>(GetWindowLongW(window, GWL_EXSTYLE)), GetDpiForWindow(window));
    sizing = true;
    SetWindowPos(
      window, nullptr, 0, 0, frame.right - frame.left, frame.bottom - frame.top,
      SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    sizing = false;
  }

  /// Sized by hand: the view told, at the nearest size it takes.
  void sized() {
    if (sizing || !view) return;
    RECT client {};
    GetClientRect(window, &client);
    ViewRect size {0, 0, client.right, client.bottom};
    if (view->checkSizeConstraint(&size) == kResultTrue &&
        (size.getWidth() != client.right || size.getHeight() != client.bottom)) {
      fit(size);
    }
    view->onSize(&size);
  }

  /// The monitor's scale, where the view takes one.
  void scale() {
    if (FUnknownPtr<IPlugViewContentScaleSupport> scaling {view}) {
      scaling->setContentScaleFactor(static_cast<float>(GetDpiForWindow(window)) / USER_DEFAULT_SCREEN_DPI);
    }
  }

  /// Gone: the view let go of, the plug-in told it has no editor, and whoever asked told, unless
  /// the host closed it.
  void destroyed() {
    KillTimer(window, idleTimer);
    if (view) {
      view->removed();
      view->setFrame(nullptr);
      view = nullptr;
    }
    plugin->editor = nullptr;
    SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    DBVST3EditorClosed told = closed;
    void *with = context;
    delete this;
    if (told) told(with);
  }

  /// Closed by the host, as when its plug-in goes: nobody told.
  void close() {
    closed = nullptr;
    DestroyWindow(window);
  }

  tresult PLUGIN_API resizeView(IPlugView *resized, ViewRect *size) override {
    if (!size || !view || resized != view.get()) return kInvalidArgument;
    fit(*size);
    return view->onSize(size);
  }

  tresult PLUGIN_API queryInterface(const TUID iid, void **object) override {
    if (FUnknownPrivate::iidEqual(iid, IPlugFrame::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
      *object = static_cast<IPlugFrame *>(this);
      return kResultOk;
    }
    *object = nullptr;
    return kNoInterface;
  }
  // Owned by its window, which outlives everything the view is given.
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }
};

namespace {

LRESULT CALLBACK editorProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  if (message == WM_NCCREATE) {
    auto editor = static_cast<EditorWindow *>(reinterpret_cast<CREATESTRUCTW *>(lParam)->lpCreateParams);
    editor->window = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(editor));
  }
  auto editor = reinterpret_cast<EditorWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (editor) {
    switch (message) {
    case WM_SIZE:
      if (wParam != SIZE_MINIMIZED) editor->sized();
      return 0;
    case WM_TIMER:
      if (wParam == idleTimer) editor->plugin->settle();
      return 0;
    case WM_DPICHANGED: {
      editor->scale();
      const RECT *suggested = reinterpret_cast<const RECT *>(lParam);
      SetWindowPos(
        window, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
        suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_DESTROY:
      editor->destroyed();
      return 0;
    default:
      break;
    }
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

bool registerEditorClass() {
  static bool registered = [] {
    WNDCLASSEXW windowClass {};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = editorProcedure;
    windowClass.hInstance = GetModuleHandleW(nullptr);
    windowClass.hCursor = LoadCursorW(nullptr, reinterpret_cast<LPCWSTR>(IDC_ARROW));
    windowClass.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    windowClass.lpszClassName = editorClass;
    return RegisterClassExW(&windowClass) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }();
  return registered;
}

}  // namespace

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
  plugin->findMIDIParams();
  return plugin.release();
}

void dbvst3_close(DBVST3Plugin *plugin) {
  if (!plugin) return;
  if (plugin->editor) plugin->editor->close();
  plugin->listener.function.store(nullptr, std::memory_order_release);
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
  plugin->process(
    inputs, inputChannels, outputs, outputChannels, frames, tempo, beat, running, events, eventCount, nullptr, 0);
}

void dbvst3_render(
  DBVST3Plugin *plugin, float *const *inlets, float *const *outlets, int32_t frames, double tempo, double beat,
  bool running, const uint64_t *events, int32_t eventCount, const float *macros, int32_t macroCount) {
  if (frames > plugin->maxFrames) {
    for (int channel = 0; channel < 2; ++channel) std::memset(outlets[channel], 0, sizeof(float) * frames);
    return;
  }
  // An instrument module's inlets are its notes' voltages, not audio.
  plugin->process(
    events ? nullptr : inlets, events ? 0 : 2, outlets, 2, frames, tempo, beat, running, events, eventCount, macros,
    macroCount);
}

void dbvst3_map(DBVST3Plugin *plugin, int32_t slot, int64_t id) {
  if (slot < 0 || slot >= 4) return;
  uint64_t made = (plugin->macros[slot].load(std::memory_order_relaxed) >> 33) + 1;
  uint64_t mapping = made << 33 | (id >= 0 ? uint64_t(1) << 32 | uint32_t(id) : 0);
  plugin->macros[slot].store(mapping, std::memory_order_release);
}

int64_t dbvst3_mapping(const DBVST3Plugin *plugin, int32_t slot) {
  if (slot < 0 || slot >= 4) return -1;
  uint64_t mapping = plugin->macros[slot].load(std::memory_order_acquire);
  return mapping & uint64_t(1) << 32 ? int64_t(uint32_t(mapping)) : -1;
}

void dbvst3_listen(DBVST3Plugin *plugin, DBVST3Listener listener, void *context) {
  plugin->listener.function.store(nullptr, std::memory_order_release);
  plugin->listener.context.store(context, std::memory_order_release);
  plugin->listener.function.store(listener, std::memory_order_release);
}

int32_t dbvst3_idle(DBVST3Plugin *plugin) { return plugin->settle(); }

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

double dbvst3_get_parameter(DBVST3Plugin *plugin, uint32_t id) {
  plugin->settle();
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
  plugin->settle();
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

bool dbvst3_editor_open(
  DBVST3Plugin *plugin, const char *title, void *owner, bool show, DBVST3EditorClosed closed, void *context) {
  if (EditorWindow *open = plugin->editor) {
    if (show) {
      ShowWindow(open->window, IsIconic(open->window) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(open->window);
    }
    return true;
  }
  if (!plugin->controller || !registerEditorClass()) return false;
  IPtr<IPlugView> view = owned(plugin->controller->createView(ViewType::kEditor));
  if (!view || view->isPlatformTypeSupported(kPlatformTypeHWND) != kResultTrue) return false;

  auto editor = new EditorWindow;
  editor->plugin = plugin;
  editor->closed = closed;
  editor->context = context;
  DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
  if (view->canResize() == kResultTrue) style |= WS_THICKFRAME | WS_MAXIMIZEBOX;
  HWND window = CreateWindowExW(
    0, editorClass, wide(title).c_str(), style, CW_USEDEFAULT, CW_USEDEFAULT, 400, 300,
    static_cast<HWND>(owner), nullptr, GetModuleHandleW(nullptr), editor);
  if (!window) {
    delete editor;
    return false;
  }
  plugin->editor = editor;
  // The view is given its scale before it is asked its size, which the scale may change.
  editor->view = view;
  editor->scale();
  ViewRect size {0, 0, 400, 300};
  view->getSize(&size);
  editor->fit(size);
  view->setFrame(editor);
  if (view->attached(window, kPlatformTypeHWND) != kResultOk) {
    view->setFrame(nullptr);
    editor->view = nullptr;
    editor->close();
    return false;
  }
  SetTimer(window, idleTimer, 30, nullptr);
  if (show) ShowWindow(window, SW_SHOW);
  return true;
}

void dbvst3_editor_close(DBVST3Plugin *plugin) {
  if (plugin->editor) plugin->editor->close();
}

void *dbvst3_editor_window(const DBVST3Plugin *plugin) { return plugin->editor ? plugin->editor->window : nullptr; }

}  // extern "C"

#endif
