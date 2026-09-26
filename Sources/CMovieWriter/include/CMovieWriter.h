// Movies on Windows, in C so that Swift can call it: an H.264 and AAC MPEG-4 file written through
// Media Foundation's sink writer, which Windows 10 and 11 carry, from pictures and sound handed to it
// one frame at a time; and what a movie file holds, read back, for the tests.
//
// Everything is called from one thread, which it initializes COM on if nothing has yet.
#ifndef CMOVIEWRITER_H
#define CMOVIEWRITER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DBMovie DBMovie;

/// A movie at `path` (UTF-8), replacing what is there: `width` by `height` pixels, both even, at
/// `framesPerSecond`, with stereo sound at `sampleRate`, and the picture encoded at about
/// `videoBitRate` bits a second. Null, with why in `error`, when it cannot be.
DBMovie *dbmovie_open(
  const char *path, int32_t width, int32_t height, int32_t framesPerSecond, int32_t sampleRate,
  int32_t videoBitRate, char *error, size_t errorSize);

/// Frame `frame`'s picture: `width` by `height` BGRA pixels, rows from the top.
bool dbmovie_video(DBMovie *movie, const uint8_t *pixels, int64_t frame);

/// `frames` of stereo sound starting `start` samples in, each side a float from -1 to 1.
bool dbmovie_audio(DBMovie *movie, const float *left, const float *right, int32_t frames, int64_t start);

/// The movie finished and closed, and let go of: false, with why, when it could not be finished.
bool dbmovie_finish(DBMovie *movie, char *error, size_t errorSize);

/// Let go of, unfinished: what was written is left for the caller to take away.
void dbmovie_cancel(DBMovie *movie);

/// What a movie holds, as it reads back.
typedef struct DBMovieInfo {
  /// Its length, in seconds.
  double seconds;
  int32_t width;
  int32_t height;
  double framesPerSecond;
  int32_t sampleRate;
  int32_t channels;
  /// The loudest sample, and the root of the mean square, of its sound between `from` and `to`
  /// seconds, as `dbmovie_probe` was asked.
  float peak;
  float rms;
} DBMovieInfo;

/// Read the movie at `path`: what it holds into `info`, and, when `pixels` is given, its picture
/// at `at` seconds as `width` by `height` BGRA pixels, rows from the top. False, with why, when it
/// cannot be read.
bool dbmovie_probe(
  const char *path, double from, double to, double at, uint8_t *pixels, DBMovieInfo *info, char *error,
  size_t errorSize);

#ifdef __cplusplus
}
#endif

#endif
