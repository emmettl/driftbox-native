// AAudio, which the Swift SDK's Android module does not bring in. Declarations only: every call is
// made from Swift. What is newer than the API level Driftbox builds for, or hidden behind
// `_GNU_SOURCE`, is looked up at run time instead (see DriftboxHostAndroid's `Bionic.swift`).
#pragma once
#ifdef __ANDROID__
#include <aaudio/AAudio.h>
#endif
