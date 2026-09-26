// A window's drawn controls for screen readers: CAccessibility.h, as a UI Automation provider.
// Windows only; elsewhere this is empty.
#ifdef _WIN32

// Windows' own: without its min and max, which the C++ library has.
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include <ole2.h>
#include <uiautomation.h>

#include "CAccessibility.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

std::wstring wide(const char *text) {
  if (!text) return {};
  int count = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
  std::wstring out(count > 1 ? count - 1 : 0, L'\0');
  if (count > 1) MultiByteToWideChar(CP_UTF8, 0, text, -1, out.data(), count);
  return out;
}

enum Role { group = 0, button = 1, toggle = 2, slider = 3, text = 4 };

/// One control as it was last handed over.
struct Node {
  std::string id;
  std::wstring name;
  std::wstring value;
  bool hasValue = false;
  int32_t role = group;
  int parent = -1;
  std::vector<int> children;
  float x = 0, y = 0, width = 0, height = 0;
  bool hasRange = false;
  double minimum = 0, maximum = 0, current = 0, step = 0;
  int32_t toggle = -1;
};

class Element;

/// Everything a provider knows, shared by the window's provider and every element a screen reader
/// holds, which may outlive it.
struct State {
  std::mutex lock;
  /// What is to be told to screen readers, told on a thread of the provider's own: telling one a
  /// control changed can have it ask the window about it before the telling returns, and the window's
  /// thread must be free to answer.
  std::mutex jobsLock;
  std::condition_variable wake;
  std::deque<std::function<void()>> jobs;
  bool stopping = false;
  HWND window = nullptr;
  DBAXAct act = nullptr;
  void *context = nullptr;
  bool alive = true;
  bool asked = false;
  std::vector<Node> nodes;
  std::map<std::string, int> index;
  /// Each id's number for UI Automation, lasting as long as the provider.
  std::map<std::string, int> runtimeIds;
  int nextRuntimeId = 1;
  /// The elements made, by id, so a control answers as the same object each time it is asked.
  std::map<std::string, Element *> elements;
  /// The control the keyboard is on; empty for none.
  std::string focus;

  /// Where `id` is now, or -1 where it has gone. Called with the lock held.
  int find(const std::string &id) const {
    auto found = index.find(id);
    return found == index.end() ? -1 : found->second;
  }

  /// The element for `id`, with a reference for the caller.
  Element *element(const std::string &id, const std::shared_ptr<State> &self);
};

/// One control, as UI Automation sees it: the window's own is the fragment root, hosted by the
/// window; every other is a fragment under it. Each asks the state for where it is now, so one a
/// screen reader holds after its control has gone says so.
class Element final : public IRawElementProviderSimple,
                      public IRawElementProviderFragment,
                      public IRawElementProviderFragmentRoot,
                      public IInvokeProvider,
                      public IToggleProvider,
                      public IRangeValueProvider,
                      public IValueProvider {
public:
  Element(std::shared_ptr<State> state, std::string id) : state(std::move(state)), id(std::move(id)) {}

  // MARK: IUnknown

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG left = --references;
    if (left == 0) delete this;
    return left;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IRawElementProviderSimple)) {
      *object = static_cast<IRawElementProviderSimple *>(this);
    } else if (iid == __uuidof(IRawElementProviderFragment)) {
      *object = static_cast<IRawElementProviderFragment *>(this);
    } else if (iid == __uuidof(IRawElementProviderFragmentRoot) && isRoot()) {
      *object = static_cast<IRawElementProviderFragmentRoot *>(this);
    } else if (iid == __uuidof(IInvokeProvider) && has(UIA_InvokePatternId)) {
      *object = static_cast<IInvokeProvider *>(this);
    } else if (iid == __uuidof(IToggleProvider) && has(UIA_TogglePatternId)) {
      *object = static_cast<IToggleProvider *>(this);
    } else if (iid == __uuidof(IRangeValueProvider) && has(UIA_RangeValuePatternId)) {
      *object = static_cast<IRangeValueProvider *>(this);
    } else if (iid == __uuidof(IValueProvider) && has(UIA_ValuePatternId)) {
      *object = static_cast<IValueProvider *>(this);
    } else {
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }

  // MARK: IRawElementProviderSimple

  HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *options) override {
    if (!options) return E_POINTER;
    *options = ProviderOptions_ServerSideProvider;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown **provider) override {
    if (!provider) return E_POINTER;
    *provider = nullptr;
    if (!has(pattern)) return S_OK;
    *provider = static_cast<IRawElementProviderSimple *>(this);
    AddRef();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
    if (!out) return E_POINTER;
    VariantInit(out);
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    const Node &node = state->nodes[at];
    bool root = at == 0;
    switch (property) {
    case UIA_NamePropertyId:
      // The window's own is named by its title, which the window's host provider gives.
      if (!root) string(node.name, out);
      break;
    case UIA_AutomationIdPropertyId:
      if (!root) string(wide(node.id.c_str()), out);
      break;
    case UIA_ControlTypePropertyId:
      out->vt = VT_I4;
      out->lVal = root ? UIA_PaneControlTypeId : controlType(node.role);
      break;
    case UIA_LocalizedControlTypePropertyId:
      // "toggle button" rather than "button" for one that is on or off.
      if (node.role == toggle) string(L"toggle button", out);
      break;
    case UIA_IsEnabledPropertyId:
    case UIA_IsControlElementPropertyId:
    case UIA_IsContentElementPropertyId:
      out->vt = VT_BOOL;
      out->boolVal = VARIANT_TRUE;
      break;
    case UIA_IsKeyboardFocusablePropertyId:
      // What the keyboard moves between: what can be pressed or set.
      out->vt = VT_BOOL;
      out->boolVal = focusable(node.role) && !root ? VARIANT_TRUE : VARIANT_FALSE;
      break;
    case UIA_HasKeyboardFocusPropertyId:
      out->vt = VT_BOOL;
      out->boolVal = !root && node.id == state->focus ? VARIANT_TRUE : VARIANT_FALSE;
      break;
    case UIA_FrameworkIdPropertyId:
      string(L"Driftbox", out);
      break;
    default:
      break;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **host) override {
    if (!host) return E_POINTER;
    *host = nullptr;
    if (!isRoot()) return S_OK;
    return UiaHostProviderFromHwnd(state->window, host);
  }

  // MARK: IRawElementProviderFragment

  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    std::string next;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      int at = state->find(id);
      if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
      const Node &node = state->nodes[at];
      auto siblings = [&]() -> const std::vector<int> * {
        return node.parent >= 0 ? &state->nodes[node.parent].children : nullptr;
      };
      int target = -1;
      switch (direction) {
      case NavigateDirection_Parent:
        target = node.parent;
        break;
      case NavigateDirection_FirstChild:
        if (!node.children.empty()) target = node.children.front();
        break;
      case NavigateDirection_LastChild:
        if (!node.children.empty()) target = node.children.back();
        break;
      case NavigateDirection_NextSibling:
      case NavigateDirection_PreviousSibling:
        if (auto list = siblings()) {
          auto place = std::find(list->begin(), list->end(), at);
          if (place != list->end()) {
            if (direction == NavigateDirection_NextSibling && place + 1 != list->end()) target = *(place + 1);
            if (direction == NavigateDirection_PreviousSibling && place != list->begin()) target = *(place - 1);
          }
        }
        break;
      }
      if (target < 0) return S_OK;
      next = state->nodes[target].id;
    }
    Element *found = state->element(next, state);
    *out = found ? static_cast<IRawElementProviderFragment *>(found) : nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    int number = 0;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      int at = state->find(id);
      if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
      // The window's own is known by its window's.
      if (at == 0) return S_OK;
      number = state->runtimeIds[id];
    }
    int parts[2] = {UiaAppendRuntimeId, number};
    *out = SafeArrayCreateVector(VT_I4, 0, 2);
    if (!*out) return E_OUTOFMEMORY;
    for (LONG place = 0; place < 2; ++place) SafeArrayPutElement(*out, &place, &parts[place]);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
    if (!out) return E_POINTER;
    *out = {};
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    // The window's own is where its window is, which the host says.
    if (at == 0) return S_OK;
    const Node &node = state->nodes[at];
    POINT origin {0, 0};
    ClientToScreen(state->window, &origin);
    *out = {origin.x + node.x, origin.y + node.y, node.width, node.height};
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    return S_OK;
  }

  // The app moves the keyboard there, and says so when it has.
  HRESULT STDMETHODCALLTYPE SetFocus() override { return ask(4, 0); }

  HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    std::string root;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      if (!state->alive || state->nodes.empty()) return UIA_E_ELEMENTNOTAVAILABLE;
      root = state->nodes[0].id;
    }
    Element *found = state->element(root, state);
    *out = found ? static_cast<IRawElementProviderFragmentRoot *>(found) : nullptr;
    return S_OK;
  }

  // MARK: IRawElementProviderFragmentRoot

  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    std::string hit;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      if (!state->alive || state->nodes.empty()) return UIA_E_ELEMENTNOTAVAILABLE;
      POINT point {static_cast<LONG>(x), static_cast<LONG>(y)};
      ScreenToClient(state->window, &point);
      // The deepest control there: the last that holds the point, since each comes before what it
      // holds.
      hit = state->nodes[0].id;
      for (const Node &node : state->nodes) {
        if (node.parent < 0) continue;
        if (point.x >= node.x && point.y >= node.y && point.x < node.x + node.width && point.y < node.y + node.height) {
          hit = node.id;
        }
      }
    }
    Element *found = state->element(hit, state);
    *out = found ? static_cast<IRawElementProviderFragment *>(found) : nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    std::string focus;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      if (!state->alive) return UIA_E_ELEMENTNOTAVAILABLE;
      if (state->find(state->focus) <= 0) return S_OK;
      focus = state->focus;
    }
    Element *found = state->element(focus, state);
    *out = found ? static_cast<IRawElementProviderFragment *>(found) : nullptr;
    return S_OK;
  }

  // MARK: The patterns

  HRESULT STDMETHODCALLTYPE Invoke() override { return ask(0, 0); }

  HRESULT STDMETHODCALLTYPE Toggle() override { return ask(0, 0); }

  HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *out) override {
    if (!out) return E_POINTER;
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = state->nodes[at].toggle == 1 ? ToggleState_On : ToggleState_Off;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetValue(double value) override { return ask(1, value); }

  HRESULT STDMETHODCALLTYPE get_Value(double *out) override { return number(out, &Node::current); }
  HRESULT STDMETHODCALLTYPE get_Minimum(double *out) override { return number(out, &Node::minimum); }
  HRESULT STDMETHODCALLTYPE get_Maximum(double *out) override { return number(out, &Node::maximum); }
  HRESULT STDMETHODCALLTYPE get_SmallChange(double *out) override { return number(out, &Node::step); }

  HRESULT STDMETHODCALLTYPE get_LargeChange(double *out) override {
    HRESULT result = number(out, &Node::step);
    if (SUCCEEDED(result)) *out *= 10;
    return result;
  }

  // The value in words is read, not written: a slider is set through its range.
  HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR) override { return UIA_E_NOTSUPPORTED; }

  HRESULT STDMETHODCALLTYPE get_Value(BSTR *out) override {
    if (!out) return E_POINTER;
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = SysAllocString(state->nodes[at].value.c_str());
    return S_OK;
  }

  // Both patterns ask it: the range can be set, the words cannot.
  HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
    if (!out) return E_POINTER;
    *out = FALSE;
    return S_OK;
  }

private:
  std::atomic<ULONG> references {1};
  std::shared_ptr<State> state;
  std::string id;

  bool isRoot() {
    std::lock_guard<std::mutex> hold(state->lock);
    return state->find(id) == 0;
  }

  /// Whether its control has `pattern`, as its role gives it.
  bool has(PATTERNID pattern) {
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (at <= 0) return false;
    const Node &node = state->nodes[at];
    switch (pattern) {
    case UIA_InvokePatternId: return node.role == button;
    case UIA_TogglePatternId: return node.role == toggle;
    case UIA_RangeValuePatternId: return node.role == slider && node.hasRange;
    // Words for what it is set to, on anything that has some: a knob's, a step's "accent".
    case UIA_ValuePatternId: return node.hasValue && node.role != group;
    default: return false;
    }
  }

  static bool focusable(int32_t role) { return role == button || role == toggle || role == slider; }

  static int controlType(int32_t role) {
    switch (role) {
    case button:
    case toggle: return UIA_ButtonControlTypeId;
    case slider: return UIA_SliderControlTypeId;
    case text: return UIA_TextControlTypeId;
    default: return UIA_GroupControlTypeId;
    }
  }

  static void string(const std::wstring &text, VARIANT *out) {
    out->vt = VT_BSTR;
    out->bstrVal = SysAllocString(text.c_str());
  }

  HRESULT number(double *out, double Node::*field) {
    if (!out) return E_POINTER;
    std::lock_guard<std::mutex> hold(state->lock);
    int at = state->find(id);
    if (!state->alive || at < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = state->nodes[at].*field;
    return S_OK;
  }

  /// The app told what is asked, from whichever thread asked it.
  HRESULT ask(int32_t action, double value) {
    DBAXAct act = nullptr;
    void *context = nullptr;
    {
      std::lock_guard<std::mutex> hold(state->lock);
      if (!state->alive || state->find(id) < 0) return UIA_E_ELEMENTNOTAVAILABLE;
      act = state->act;
      context = state->context;
    }
    if (act) act(context, id.c_str(), action, value);
    return S_OK;
  }
};

Element *State::element(const std::string &id, const std::shared_ptr<State> &self) {
  std::lock_guard<std::mutex> hold(lock);
  if (!alive || find(id) < 0) return nullptr;
  auto &made = elements[id];
  if (!made) made = new Element(self, id);
  if (!runtimeIds.count(id)) runtimeIds[id] = nextRuntimeId++;
  made->AddRef();
  return made;
}

/// A property that changed, to be told once the lock is let go: raising an event asks the provider
/// again, from this thread.
struct Change {
  std::string id;
  PROPERTYID property;
  VARIANT before;
  VARIANT after;
};

VARIANT words(const std::wstring &value) {
  VARIANT out;
  VariantInit(&out);
  out.vt = VT_BSTR;
  out.bstrVal = SysAllocString(value.c_str());
  return out;
}

VARIANT integer(int value) {
  VARIANT out;
  VariantInit(&out);
  out.vt = VT_I4;
  out.lVal = value;
  return out;
}

VARIANT real(double value) {
  VARIANT out;
  VariantInit(&out);
  out.vt = VT_R8;
  out.dblVal = value;
  return out;
}

}  // namespace

struct DBAX {
  std::shared_ptr<State> state;
};

extern "C" {

DBAX *dbax_create(void *window, DBAXAct act, void *context) {
  auto ax = new DBAX;
  ax->state = std::make_shared<State>();
  ax->state->window = static_cast<HWND>(window);
  ax->state->act = act;
  ax->state->context = context;
  // Until told otherwise, the window alone.
  Node root;
  root.id = "window";
  ax->state->nodes.push_back(root);
  ax->state->index[root.id] = 0;
  // The telling thread: what is queued, told in order, until the provider goes. It keeps the state
  // alive for as long as it runs, so it may finish after the window has gone.
  std::thread([state = ax->state] {
    HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    for (;;) {
      std::deque<std::function<void()>> now;
      bool stop = false;
      {
        std::unique_lock<std::mutex> hold(state->jobsLock);
        state->wake.wait(hold, [&] { return !state->jobs.empty() || state->stopping; });
        now.swap(state->jobs);
        stop = state->stopping;
      }
      for (auto &job : now) job();
      if (stop) break;
    }
    if (SUCCEEDED(com)) CoUninitialize();
  }).detach();
  return ax;
}

void dbax_destroy(DBAX *ax) {
  if (!ax) return;
  std::vector<Element *> elements;
  {
    std::lock_guard<std::mutex> hold(ax->state->lock);
    ax->state->alive = false;
    ax->state->act = nullptr;
    for (auto &made : ax->state->elements) elements.push_back(made.second);
    ax->state->elements.clear();
  }
  // Nothing more from this window: its root taken back from UI Automation here, as the window goes;
  // and every element a screen reader holds told it is gone on the telling thread, which then ends.
  UiaReturnRawElementProvider(ax->state->window, 0, 0, nullptr);
  {
    std::lock_guard<std::mutex> hold(ax->state->jobsLock);
    ax->state->jobs.push_back([elements] {
      for (Element *element : elements) {
        UiaDisconnectProvider(static_cast<IRawElementProviderSimple *>(element));
        element->Release();
      }
    });
    ax->state->stopping = true;
  }
  ax->state->wake.notify_one();
  delete ax;
}

void dbax_update(DBAX *ax, const DBAXNode *nodes, int32_t count) {
  if (!ax || count <= 0) return;
  std::vector<Node> fresh(static_cast<size_t>(count));
  std::map<std::string, int> index;
  for (int32_t at = 0; at < count; ++at) {
    const DBAXNode &given = nodes[at];
    Node &node = fresh[at];
    node.id = given.id ? given.id : "";
    node.name = wide(given.name);
    node.hasValue = given.value != nullptr;
    node.value = wide(given.value);
    node.role = given.role;
    node.parent = at == 0 ? -1 : std::clamp(given.parent, 0, at - 1);
    node.x = given.x;
    node.y = given.y;
    node.width = given.width;
    node.height = given.height;
    node.hasRange = given.hasRange;
    node.minimum = given.minimum;
    node.maximum = given.maximum;
    node.current = given.current;
    node.step = given.step;
    node.toggle = given.toggle;
    index[node.id] = at;
    if (at > 0) fresh[node.parent].children.push_back(at);
  }

  std::vector<Change> changes;
  bool structure = false;
  std::string rootId;
  {
    std::lock_guard<std::mutex> hold(ax->state->lock);
    State &state = *ax->state;
    // What changed of the controls that were there and still are; and whether the tree's shape did.
    structure = fresh.size() != state.nodes.size();
    for (const Node &node : fresh) {
      int was = state.find(node.id);
      if (was < 0) {
        structure = true;
        continue;
      }
      const Node &old = state.nodes[was];
      if (old.parent < 0 != node.parent < 0 || (old.parent >= 0 && state.nodes[old.parent].id != fresh[node.parent].id)) {
        structure = true;
      }
      if (!state.elements.count(node.id)) continue;
      if (old.name != node.name) changes.push_back({node.id, UIA_NamePropertyId, words(old.name), words(node.name)});
      if (old.value != node.value) {
        changes.push_back({node.id, UIA_ValueValuePropertyId, words(old.value), words(node.value)});
      }
      if (old.toggle != node.toggle && node.toggle >= 0) {
        changes.push_back({node.id, UIA_ToggleToggleStatePropertyId, integer(old.toggle == 1), integer(node.toggle == 1)});
      }
      if (old.current != node.current && node.hasRange) {
        changes.push_back({node.id, UIA_RangeValueValuePropertyId, real(old.current), real(node.current)});
      }
    }
    state.nodes = std::move(fresh);
    state.index = std::move(index);
    rootId = state.nodes[0].id;
  }

  if (changes.empty() && !structure) return;
  // Told on the telling thread, so the window's goes on taking its messages.
  auto state = ax->state;
  auto told = std::make_shared<std::vector<Change>>(std::move(changes));
  {
    std::lock_guard<std::mutex> hold(state->jobsLock);
    state->jobs.push_back([state, told, structure, rootId] {
      bool listening = UiaClientsAreListening();
      for (Change &change : *told) {
        if (listening) {
          if (Element *element = state->element(change.id, state)) {
            UiaRaiseAutomationPropertyChangedEvent(element, change.property, change.before, change.after);
            element->Release();
          }
        }
        VariantClear(&change.before);
        VariantClear(&change.after);
      }
      if (structure && listening) {
        if (Element *root = state->element(rootId, state)) {
          UiaRaiseStructureChangedEvent(root, StructureChangeType_ChildrenInvalidated, nullptr, 0);
          root->Release();
        }
      }
    });
  }
  state->wake.notify_one();
}

void dbax_focus(DBAX *ax, const char *id) {
  if (!ax) return;
  std::string focus = id ? id : "";
  {
    std::lock_guard<std::mutex> hold(ax->state->lock);
    if (ax->state->focus == focus) return;
    ax->state->focus = focus;
  }
  if (focus.empty()) return;
  // Told on the telling thread, as a change is: a screen reader asks about where the keyboard went
  // before the telling returns.
  auto state = ax->state;
  {
    std::lock_guard<std::mutex> hold(state->jobsLock);
    state->jobs.push_back([state, focus] {
      if (!UiaClientsAreListening()) return;
      if (Element *element = state->element(focus, state)) {
        UiaRaiseAutomationEvent(element, UIA_AutomationFocusChangedEventId);
        element->Release();
      }
    });
  }
  state->wake.notify_one();
}

intptr_t dbax_get_object(DBAX *ax, uintptr_t wParam, intptr_t lParam) {
  if (!ax || static_cast<LONG>(lParam) != static_cast<LONG>(UiaRootObjectId)) return 0;
  std::string root;
  {
    std::lock_guard<std::mutex> hold(ax->state->lock);
    ax->state->asked = true;
    root = ax->state->nodes[0].id;
  }
  Element *element = ax->state->element(root, ax->state);
  if (!element) return 0;
  LRESULT result = UiaReturnRawElementProvider(ax->state->window, static_cast<WPARAM>(wParam), static_cast<LPARAM>(lParam), element);
  element->Release();
  return static_cast<intptr_t>(result);
}

bool dbax_is_described(DBAX *ax) {
  if (!ax) return false;
  {
    std::lock_guard<std::mutex> hold(ax->state->lock);
    if (ax->state->asked) return true;
  }
  return UiaClientsAreListening();
}

}  // extern "C"

#endif
