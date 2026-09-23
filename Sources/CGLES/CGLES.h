// EGL and OpenGL ES 3.0, for the GPU layer's backend on Android and Linux, and on Android the
// window they draw in. Declarations only: every call is made from Swift. OpenGL ES itself is linked
// by whoever builds the target, since its library is libGLESv3 on Android and libGLESv2 on Linux,
// where it carries 3.0 as well; and the window's functions are libandroid's, linked by the app.
#pragma once
#if defined(__ANDROID__) || defined(__linux__)
// No X11: a display is EGL's default one, and nothing here opens a window through X.
#define EGL_NO_X11
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#endif
#if defined(__ANDROID__)
#include <android/native_window_jni.h>
#endif
