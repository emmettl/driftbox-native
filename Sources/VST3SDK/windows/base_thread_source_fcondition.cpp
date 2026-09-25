// The SDK's `base/thread/source/fcondition.cpp`, which a host and a plug-in share.
// Compiled only on Windows, where Driftbox hosts VST 3 plug-ins for now; elsewhere, nothing.
#ifdef _WIN32
// The SDK as Steinberg wrote it: its headers pack their structs as they mean to, and it uses the C
// library in ways a Windows compiler would sooner it did not.
#pragma clang diagnostic ignored "-Wpragma-pack"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wformat"
#pragma clang diagnostic ignored "-Wimplicit-const-int-float-conversion"
#include "../sdk/base/thread/source/fcondition.cpp"
#endif
