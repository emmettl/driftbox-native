#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct db_pw_output db_pw_output;
typedef void (*db_pw_render)(void *, intptr_t, float *, float *);
// Control calls are serialized by the owner; none may be made from render.
db_pw_output *db_pw_open(db_pw_render render, void *context, uint32_t rate, const char *target,
                        char *error, size_t error_size);
void db_pw_enable(db_pw_output *output);
// Disables source rendering and waits for any in-flight source callback to return.
void db_pw_pause(db_pw_output *output);
void db_pw_close(db_pw_output *output);
// -1: failed/disconnected, 0: connecting, 1: paused, 2: streaming.
int db_pw_status(db_pw_output *output, char *error, size_t error_size);
uint64_t db_pw_frames(db_pw_output *output);
// CLI-only, process-global signal handling; restores the previous handlers at end.
int db_linux_interrupt_begin(void);
int db_linux_interrupted(void);
void db_linux_interrupt_end(void);

// Registry snapshots run synchronously on the caller, under the discovery loop lock.
// A NULL name carries the default.audio.sink JSON in description; other names are node.name IDs.
typedef struct db_pw_discovery db_pw_discovery;
typedef void (*db_pw_device)(void *, const char *name, const char *description);
db_pw_discovery *db_pw_discovery_open(char *error, size_t error_size);
// -1 failed, 0 initial enumeration pending, 1 ready. Strings are borrowed during callback only.
int db_pw_discovery_snapshot(db_pw_discovery *, db_pw_device, void *, char *, size_t);
void db_pw_discovery_close(db_pw_discovery *);
