#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct db_midi db_midi;
typedef void (*db_midi_port_callback)(void *, int, int, const char *, const char *, int);
// All sequencer operations belong to one worker. Only wake is called from other threads.
db_midi *db_midi_open(const char *name, char *error, size_t size);
void db_midi_close(db_midi *);
int db_midi_ports(db_midi *, void *, db_midi_port_callback);
int db_midi_connect(db_midi *, int client, int port, int connect);
// 1: short MIDI message, 2: topology change, 0: no more input, negative: ALSA error.
int db_midi_receive(db_midi *, int *client, int *port, uint8_t bytes[3], int *length);
int db_midi_send(db_midi *, int client, int port, const uint8_t *, int length);
void db_midi_wake(db_midi *);
int db_midi_wait(db_midi *, int64_t nanoseconds);
