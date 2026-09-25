// Android's looper, the event loop of a thread with one, and eventfd, which libdispatch signals its
// main queue's work through: what draining Swift's main queue on Android's main thread takes.
#pragma once
#ifdef __ANDROID__
#include <android/looper.h>
#include <sys/eventfd.h>
#endif
