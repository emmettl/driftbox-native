// A VST 3 module that crashes when it is asked for its factory, the first thing a host asks of one,
// for the tests to hold the scanner to: whatever asks it what it holds goes down with it. The crash
// is not in DllMain, where Windows would catch it and only fail the load. Windows only, as the
// scanner is for now.
#ifdef _WIN32
__declspec(dllexport) void *GetPluginFactory(void) {
  *(volatile int *)0 = 0;
  return 0;
}
#endif
