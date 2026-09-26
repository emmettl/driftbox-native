// A screen reader's view of a window, for the tests: Windows' own UI Automation client, reading the
// window's controls and acting on them as Narrator and NVDA do. DriftboxAXProbe calls it from a process
// of its own, as a screen reader is, while the window's process keeps taking its messages. Windows only.
#ifndef DRIFTBOXAXCLIENT_H
#define DRIFTBOXAXCLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The window's controls as UI Automation reads them, one to a line, each indented two spaces a
/// level under the window: `Button "Play" [transport.play] toggle=on range=0..1@0.5 value="…"`, with
/// what does not apply left out. False, with why in `out`, when it cannot be read.
bool axclient_describe(void *window, char *out, size_t size);

/// The control with `automationId` pressed, turned over, or set, through its pattern.
bool axclient_invoke(void *window, const char *automationId);
bool axclient_toggle(void *window, const char *automationId);
bool axclient_set(void *window, const char *automationId, double value);

#ifdef __cplusplus
}
#endif

#endif
