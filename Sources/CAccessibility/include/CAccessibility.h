// A window's controls for screen readers, in C so that Swift can call it: a UI Automation provider
// for a window whose controls are drawn rather than made of windows of their own. The app hands it
// what is on screen as a tree, whenever it changes, and hears back what a screen reader asks to be
// done. Windows only; elsewhere this is empty.
//
// It is safe from any thread: UI Automation calls it on threads of its own, so it keeps what it was
// last told under a lock, and hands what it is asked to do to the app's callback on whichever
// thread asked — the app takes it to its own.
#ifndef CACCESSIBILITY_H
#define CACCESSIBILITY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One control, as the tree is handed over: each before what it holds, the window's own first.
typedef struct DBAXNode {
  /// Lasting from one handing-over to the next, and unique.
  const char *id;
  const char *name;
  /// What it is set to, in words; null for nothing.
  const char *value;
  /// 0 a group, 1 a button, 2 a toggle, 3 a slider, 4 text.
  int32_t role;
  /// Where the node holding it is in the array; -1 for the first, the window's own.
  int32_t parent;
  /// Where it is, in pixels from the window's client area's top left.
  float x, y, width, height;
  /// A slider's range, where it is in it, and a notch.
  bool hasRange;
  double minimum, maximum, current, step;
  /// A toggle's state: 0 off, 1 on, -1 not a toggle.
  int32_t toggle;
} DBAXNode;

/// What a screen reader asked: 0 press, 1 set to `value`, 2 a notch up, 3 a notch down, 4 the
/// keyboard's focus moved to it.
typedef void (*DBAXAct)(void *context, const char *id, int32_t action, double value);

typedef struct DBAX DBAX;

/// The provider for `window` (an HWND), telling `act`, with `context`, what is asked.
DBAX *dbax_create(void *window, DBAXAct act, void *context);
/// Let go of, and every element a screen reader holds of it told it is gone.
void dbax_destroy(DBAX *ax);

/// What is on screen now: `count` nodes, as `DBAXNode` says. Screen readers listening are told
/// what changed since the last.
void dbax_update(DBAX *ax, const DBAXNode *nodes, int32_t count);

/// The control the keyboard is on, by its id; null for none. Screen readers are told when it moves.
void dbax_focus(DBAX *ax, const char *id);

/// The answer to `WM_GETOBJECT` with these parameters, when it asks for UI Automation's root; 0
/// otherwise, for the window's procedure to leave to Windows.
intptr_t dbax_get_object(DBAX *ax, uintptr_t wParam, intptr_t lParam);

/// Whether anything is reading the window: asked for it, or listening for UI Automation's events.
bool dbax_is_described(DBAX *ax);

#ifdef __cplusplus
}
#endif

#endif
