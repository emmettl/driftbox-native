// The Windows audio headers Swift's WinSDK module leaves out: the device enumerator, the audio
// client and the thread priority service. Only the declarations; every call is made from Swift.
#pragma once
#ifdef _WIN32
// What these headers build on is inside Swift's WinSDK module, where an #include of it again is a
// no-op; importing the module is what makes it visible here.
#pragma clang module import WinSDK
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>

// A PROPVARIANT's string, if it holds one. Its unions import too deep to reach from Swift.
static inline const wchar_t *cwasapi_string(const PROPVARIANT *value) {
  return value->vt == VT_LPWSTR ? value->pwszVal : 0;
}
#endif
