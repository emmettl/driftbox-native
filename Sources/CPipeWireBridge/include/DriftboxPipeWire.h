#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct db_pw_output db_pw_output;
typedef void (*db_pw_render)(void *, intptr_t, float *, float *);
// Control calls are serialized by the owner; none may be made from render.
db_pw_output *db_pw_open(db_pw_render render, void *context, uint32_t rate,
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
