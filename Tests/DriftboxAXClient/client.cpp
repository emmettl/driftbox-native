// A screen reader's view of a window, for the tests: DriftboxAXClient.h, on IUIAutomation.
#ifdef _WIN32

#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include <ole2.h>
#include <uiautomation.h>

#include "DriftboxAXClient.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

template <typename T>
void release(T *&pointer) {
  if (pointer) pointer->Release();
  pointer = nullptr;
}

std::string narrow(BSTR text) {
  if (!text) return {};
  int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  std::string out(count > 1 ? count - 1 : 0, '\0');
  if (count > 1) WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), count, nullptr, nullptr);
  return out;
}

void write(const std::string &text, char *out, size_t size) {
  if (!out || size == 0) return;
  size_t count = text.size() < size - 1 ? text.size() : size - 1;
  std::memcpy(out, text.data(), count);
  out[count] = 0;
}

/// UI Automation, on this thread, for as long as it is held.
struct Client {
  bool com = false;
  IUIAutomation *automation = nullptr;
  IUIAutomationElement *window = nullptr;

  explicit Client(void *handle) {
    com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation),
          reinterpret_cast<void **>(&automation)))) {
      return;
    }
    automation->ElementFromHandle(static_cast<HWND>(handle), &window);
  }

  ~Client() {
    release(window);
    release(automation);
    if (com) CoUninitialize();
  }

  /// The element under the window with `id`, found by its automation id.
  IUIAutomationElement *find(const char *id) {
    if (!window) return nullptr;
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_BSTR;
    int count = MultiByteToWideChar(CP_UTF8, 0, id, -1, nullptr, 0);
    std::wstring wide(count > 1 ? count - 1 : 0, L'\0');
    if (count > 1) MultiByteToWideChar(CP_UTF8, 0, id, -1, wide.data(), count);
    value.bstrVal = SysAllocString(wide.c_str());
    IUIAutomationCondition *condition = nullptr;
    IUIAutomationElement *found = nullptr;
    if (SUCCEEDED(automation->CreatePropertyCondition(UIA_AutomationIdPropertyId, value, &condition))) {
      window->FindFirst(TreeScope_Descendants, condition, &found);
    }
    release(condition);
    VariantClear(&value);
    return found;
  }

  /// One element and what it holds, as lines.
  void describe(IUIAutomationElement *element, IUIAutomationTreeWalker *walker, int depth, std::string &out) {
    CONTROLTYPEID type = 0;
    element->get_CurrentControlType(&type);
    BSTR name = nullptr, id = nullptr;
    element->get_CurrentName(&name);
    element->get_CurrentAutomationId(&id);
    std::string line(static_cast<size_t>(depth) * 2, ' ');
    switch (type) {
    case UIA_ButtonControlTypeId: line += "Button"; break;
    case UIA_SliderControlTypeId: line += "Slider"; break;
    case UIA_TextControlTypeId: line += "Text"; break;
    case UIA_GroupControlTypeId: line += "Group"; break;
    case UIA_PaneControlTypeId: line += "Pane"; break;
    case UIA_WindowControlTypeId: line += "Window"; break;
    default: line += "Type" + std::to_string(type); break;
    }
    line += " \"" + narrow(name) + "\"";
    std::string automationId = narrow(id);
    if (!automationId.empty()) line += " [" + automationId + "]";
    SysFreeString(name);
    SysFreeString(id);

    IUIAutomationTogglePattern *toggle = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_TogglePatternId, __uuidof(IUIAutomationTogglePattern),
          reinterpret_cast<void **>(&toggle))) && toggle) {
      ToggleState state = ToggleState_Off;
      toggle->get_CurrentToggleState(&state);
      line += state == ToggleState_On ? " toggle=on" : " toggle=off";
      release(toggle);
    }
    IUIAutomationRangeValuePattern *range = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_RangeValuePatternId, __uuidof(IUIAutomationRangeValuePattern),
          reinterpret_cast<void **>(&range))) && range) {
      double minimum = 0, maximum = 0, current = 0;
      range->get_CurrentMinimum(&minimum);
      range->get_CurrentMaximum(&maximum);
      range->get_CurrentValue(&current);
      char text[96];
      std::snprintf(text, sizeof(text), " range=%g..%g@%g", minimum, maximum, current);
      line += text;
      release(range);
    }
    IUIAutomationValuePattern *value = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_ValuePatternId, __uuidof(IUIAutomationValuePattern),
          reinterpret_cast<void **>(&value))) && value) {
      BSTR said = nullptr;
      value->get_CurrentValue(&said);
      line += " value=\"" + narrow(said) + "\"";
      SysFreeString(said);
      release(value);
    }
    IUIAutomationInvokePattern *invoke = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
          reinterpret_cast<void **>(&invoke))) && invoke) {
      line += " invoke";
      release(invoke);
    }
    BOOL focused = FALSE;
    if (!automationId.empty() && SUCCEEDED(element->get_CurrentHasKeyboardFocus(&focused)) && focused) {
      line += " focused";
    }
    out += line + "\n";

    IUIAutomationElement *child = nullptr;
    walker->GetFirstChildElement(element, &child);
    while (child) {
      describe(child, walker, depth + 1, out);
      IUIAutomationElement *next = nullptr;
      walker->GetNextSiblingElement(child, &next);
      release(child);
      child = next;
    }
  }
};

}  // namespace

extern "C" {

bool axclient_describe(void *window, char *out, size_t size) {
  Client client(window);
  if (!client.window) {
    write("UI Automation found no window", out, size);
    return false;
  }
  IUIAutomationTreeWalker *walker = nullptr;
  client.automation->get_RawViewWalker(&walker);
  std::string text;
  if (walker) client.describe(client.window, walker, 0, text);
  release(walker);
  write(text, out, size);
  return !text.empty();
}

bool axclient_invoke(void *window, const char *automationId) {
  Client client(window);
  IUIAutomationElement *element = client.find(automationId);
  IUIAutomationInvokePattern *invoke = nullptr;
  bool done = element &&
    SUCCEEDED(element->GetCurrentPatternAs(UIA_InvokePatternId, __uuidof(IUIAutomationInvokePattern),
      reinterpret_cast<void **>(&invoke))) &&
    invoke && SUCCEEDED(invoke->Invoke());
  release(invoke);
  release(element);
  return done;
}

bool axclient_toggle(void *window, const char *automationId) {
  Client client(window);
  IUIAutomationElement *element = client.find(automationId);
  IUIAutomationTogglePattern *toggle = nullptr;
  bool done = element &&
    SUCCEEDED(element->GetCurrentPatternAs(UIA_TogglePatternId, __uuidof(IUIAutomationTogglePattern),
      reinterpret_cast<void **>(&toggle))) &&
    toggle && SUCCEEDED(toggle->Toggle());
  release(toggle);
  release(element);
  return done;
}

bool axclient_focus(void *window, const char *automationId) {
  Client client(window);
  IUIAutomationElement *element = client.find(automationId);
  bool done = element && SUCCEEDED(element->SetFocus());
  release(element);
  return done;
}

bool axclient_set(void *window, const char *automationId, double value) {
  Client client(window);
  IUIAutomationElement *element = client.find(automationId);
  IUIAutomationRangeValuePattern *range = nullptr;
  bool done = element &&
    SUCCEEDED(element->GetCurrentPatternAs(UIA_RangeValuePatternId, __uuidof(IUIAutomationRangeValuePattern),
      reinterpret_cast<void **>(&range))) &&
    range && SUCCEEDED(range->SetValue(value));
  release(range);
  release(element);
  return done;
}

}  // extern "C"

#endif
