// Android's native MIDI, which the Swift SDK's Android module does not bring in. Declarations
// only: every call is made from Swift. It is Android 10's, which is why Driftbox builds for API 29.
#pragma once
#ifdef __ANDROID__
#include <amidi/AMidi.h>
#endif
