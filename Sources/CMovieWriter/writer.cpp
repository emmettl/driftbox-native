// Movies on Windows: CMovieWriter.h, on Media Foundation's sink writer and source reader. Windows
// only; elsewhere this is empty.
#ifdef _WIN32

// Windows' own: without its min and max, which the C++ library has.
#define NOMINMAX
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include "CMovieWriter.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr LONGLONG second = 10'000'000;  // Media Foundation's time: a hundred nanoseconds.

template <typename T>
void release(T *&pointer) {
  if (pointer) pointer->Release();
  pointer = nullptr;
}

std::wstring wide(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, 0, text ? text : "", -1, nullptr, 0);
  std::wstring out(count > 1 ? count - 1 : 0, L'\0');
  if (count > 1) MultiByteToWideChar(CP_UTF8, 0, text, -1, out.data(), count);
  return out;
}

void write(const std::string &text, char *out, size_t size) {
  if (!out || size == 0) return;
  size_t count = std::min(text.size(), size - 1);
  std::memcpy(out, text.data(), count);
  out[count] = 0;
}

/// Why, in Windows' words where it has some, with the step that failed.
std::string why(const char *step, HRESULT result) {
  char *message = nullptr;
  FormatMessageA(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
    static_cast<DWORD>(result), 0, reinterpret_cast<LPSTR>(&message), 0, nullptr);
  std::string text = std::string(step) + ": ";
  if (message) {
    text += message;
    LocalFree(message);
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r' || text.back() == '.')) text.pop_back();
  } else {
    char code[16];
    std::snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(result));
    text += code;
  }
  return text;
}

/// COM and Media Foundation for as long as a movie is open or read: COM on this thread as it has
/// it, or single-threaded if it has none yet; Media Foundation counted, so each start is ended.
struct Started {
  bool com = false;
  bool media = false;

  HRESULT start() {
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    com = SUCCEEDED(result);
    result = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    media = SUCCEEDED(result);
    return result;
  }

  void stop() {
    if (media) MFShutdown();
    if (com) CoUninitialize();
    media = com = false;
  }
};

/// A media type from its attributes, set in order; the first failure is kept.
struct Type {
  IMFMediaType *type = nullptr;
  HRESULT result = S_OK;

  Type() { result = MFCreateMediaType(&type); }
  ~Type() { release(type); }

  Type &guid(const GUID &key, const GUID &value) {
    if (SUCCEEDED(result)) result = type->SetGUID(key, value);
    return *this;
  }
  Type &number(const GUID &key, UINT32 value) {
    if (SUCCEEDED(result)) result = type->SetUINT32(key, value);
    return *this;
  }
  Type &size(const GUID &key, UINT32 width, UINT32 height) {
    if (SUCCEEDED(result)) result = MFSetAttributeSize(type, key, width, height);
    return *this;
  }
  Type &ratio(const GUID &key, UINT32 numerator, UINT32 denominator) {
    if (SUCCEEDED(result)) result = MFSetAttributeRatio(type, key, numerator, denominator);
    return *this;
  }
};

/// A sample of `bytes` bytes from `fill`, at `time` for `duration`.
template <typename Fill>
HRESULT sample(DWORD bytes, LONGLONG time, LONGLONG duration, Fill fill, IMFSample **made) {
  IMFMediaBuffer *buffer = nullptr;
  HRESULT result = MFCreateMemoryBuffer(bytes, &buffer);
  BYTE *data = nullptr;
  if (SUCCEEDED(result)) result = buffer->Lock(&data, nullptr, nullptr);
  if (SUCCEEDED(result)) {
    fill(data);
    buffer->Unlock();
    result = buffer->SetCurrentLength(bytes);
  }
  IMFSample *out = nullptr;
  if (SUCCEEDED(result)) result = MFCreateSample(&out);
  if (SUCCEEDED(result)) result = out->AddBuffer(buffer);
  if (SUCCEEDED(result)) result = out->SetSampleTime(time);
  if (SUCCEEDED(result)) result = out->SetSampleDuration(duration);
  release(buffer);
  if (FAILED(result)) {
    release(out);
    return result;
  }
  *made = out;
  return S_OK;
}

}  // namespace

struct DBMovie {
  Started started;
  IMFSinkWriter *writer = nullptr;
  DWORD video = 0;
  DWORD audio = 0;
  int32_t width = 0;
  int32_t height = 0;
  int32_t framesPerSecond = 0;
  int32_t sampleRate = 0;
  std::vector<int16_t> pcm;

  ~DBMovie() {
    release(writer);
    started.stop();
  }

  LONGLONG frameTime(int64_t frame) const { return frame * second / framesPerSecond; }
};

extern "C" {

DBMovie *dbmovie_open(
  const char *path, int32_t width, int32_t height, int32_t framesPerSecond, int32_t sampleRate,
  int32_t videoBitRate, char *error, size_t errorSize) {
  if (width <= 0 || height <= 0 || width % 2 || height % 2 || framesPerSecond <= 0 || sampleRate <= 0) {
    write("the picture must be a positive, even size, and the rates positive", error, errorSize);
    return nullptr;
  }
  auto movie = new DBMovie;
  movie->width = width;
  movie->height = height;
  movie->framesPerSecond = framesPerSecond;
  movie->sampleRate = sampleRate;
  auto fail = [&](const char *step, HRESULT result) -> DBMovie * {
    write(why(step, result), error, errorSize);
    delete movie;
    return nullptr;
  };
  HRESULT result = movie->started.start();
  if (FAILED(result)) return fail("Media Foundation would not start", result);

  // An MPEG-4 file whatever it is called; the hardware's encoder where there is one; and every
  // sample taken as it is given, since nothing here is live.
  IMFAttributes *attributes = nullptr;
  result = MFCreateAttributes(&attributes, 3);
  if (SUCCEEDED(result)) result = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
  if (SUCCEEDED(result)) result = attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  if (SUCCEEDED(result)) result = attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
  if (SUCCEEDED(result)) result = MFCreateSinkWriterFromURL(wide(path).c_str(), nullptr, attributes, &movie->writer);
  release(attributes);
  if (FAILED(result)) return fail("the file could not be made", result);

  // The picture: H.264, High profile, in; BGRA rows from the top, which the writer converts.
  Type video;
  video.guid(MF_MT_MAJOR_TYPE, MFMediaType_Video)
    .guid(MF_MT_SUBTYPE, MFVideoFormat_H264)
    .number(MF_MT_AVG_BITRATE, static_cast<UINT32>(videoBitRate))
    .number(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    .number(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High)
    .size(MF_MT_FRAME_SIZE, width, height)
    .ratio(MF_MT_FRAME_RATE, framesPerSecond, 1)
    .ratio(MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(video.result)) return fail("the picture's format", video.result);
  result = movie->writer->AddStream(video.type, &movie->video);
  if (FAILED(result)) return fail("the picture's track", result);
  Type pixels;
  pixels.guid(MF_MT_MAJOR_TYPE, MFMediaType_Video)
    .guid(MF_MT_SUBTYPE, MFVideoFormat_RGB32)
    .number(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    .number(MF_MT_DEFAULT_STRIDE, static_cast<UINT32>(width * 4))
    .size(MF_MT_FRAME_SIZE, width, height)
    .ratio(MF_MT_FRAME_RATE, framesPerSecond, 1)
    .ratio(MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (SUCCEEDED(pixels.result)) pixels.result = movie->writer->SetInputMediaType(movie->video, pixels.type, nullptr);
  if (FAILED(pixels.result)) return fail("the picture's encoder", pixels.result);

  // The sound: AAC at 192 kbit/s, the most Windows' encoder makes, from 16-bit stereo.
  Type sound;
  sound.guid(MF_MT_MAJOR_TYPE, MFMediaType_Audio)
    .guid(MF_MT_SUBTYPE, MFAudioFormat_AAC)
    .number(MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
    .number(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(sampleRate))
    .number(MF_MT_AUDIO_NUM_CHANNELS, 2)
    .number(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24000);
  if (FAILED(sound.result)) return fail("the sound's format", sound.result);
  result = movie->writer->AddStream(sound.type, &movie->audio);
  if (FAILED(result)) return fail("the sound's track", result);
  Type samples;
  samples.guid(MF_MT_MAJOR_TYPE, MFMediaType_Audio)
    .guid(MF_MT_SUBTYPE, MFAudioFormat_PCM)
    .number(MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
    .number(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(sampleRate))
    .number(MF_MT_AUDIO_NUM_CHANNELS, 2)
    .number(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4)
    .number(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, static_cast<UINT32>(sampleRate * 4));
  if (SUCCEEDED(samples.result)) samples.result = movie->writer->SetInputMediaType(movie->audio, samples.type, nullptr);
  if (FAILED(samples.result)) return fail("the sound's encoder, which takes 44.1 or 48 kHz", samples.result);

  result = movie->writer->BeginWriting();
  if (FAILED(result)) return fail("writing could not begin", result);
  return movie;
}

bool dbmovie_video(DBMovie *movie, const uint8_t *pixels, int64_t frame) {
  DWORD bytes = static_cast<DWORD>(movie->width) * movie->height * 4;
  IMFSample *made = nullptr;
  LONGLONG time = movie->frameTime(frame);
  HRESULT result = sample(bytes, time, movie->frameTime(frame + 1) - time, [&](BYTE *data) {
    std::memcpy(data, pixels, bytes);
  }, &made);
  if (SUCCEEDED(result)) result = movie->writer->WriteSample(movie->video, made);
  release(made);
  return SUCCEEDED(result);
}

bool dbmovie_audio(DBMovie *movie, const float *left, const float *right, int32_t frames, int64_t start) {
  if (frames <= 0) return true;
  movie->pcm.resize(static_cast<size_t>(frames) * 2);
  for (int32_t index = 0; index < frames; ++index) {
    for (int channel = 0; channel < 2; ++channel) {
      float value = (channel == 0 ? left : right)[index];
      value = std::isfinite(value) ? std::clamp(value, -1.f, 1.f) : 0.f;
      movie->pcm[index * 2 + channel] = static_cast<int16_t>(std::lrint(value * 32767.f));
    }
  }
  IMFSample *made = nullptr;
  LONGLONG time = start * second / movie->sampleRate;
  LONGLONG end = (start + frames) * second / movie->sampleRate;
  HRESULT result = sample(static_cast<DWORD>(frames) * 4, time, end - time, [&](BYTE *data) {
    std::memcpy(data, movie->pcm.data(), static_cast<size_t>(frames) * 4);
  }, &made);
  if (SUCCEEDED(result)) result = movie->writer->WriteSample(movie->audio, made);
  release(made);
  return SUCCEEDED(result);
}

bool dbmovie_finish(DBMovie *movie, char *error, size_t errorSize) {
  HRESULT result = movie->writer->Finalize();
  if (FAILED(result)) write(why("the movie could not be finished", result), error, errorSize);
  delete movie;
  return SUCCEEDED(result);
}

void dbmovie_cancel(DBMovie *movie) { delete movie; }

bool dbmovie_probe(
  const char *path, double from, double to, double at, uint8_t *pixels, DBMovieInfo *info, char *error,
  size_t errorSize) {
  *info = {};
  Started started;
  IMFSourceReader *reader = nullptr;
  auto fail = [&](const char *step, HRESULT result) {
    write(why(step, result), error, errorSize);
    release(reader);
    started.stop();
    return false;
  };
  HRESULT result = started.start();
  if (FAILED(result)) return fail("Media Foundation would not start", result);
  IMFAttributes *attributes = nullptr;
  result = MFCreateAttributes(&attributes, 1);
  if (SUCCEEDED(result)) result = attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  if (SUCCEEDED(result)) result = MFCreateSourceReaderFromURL(wide(path).c_str(), attributes, &reader);
  release(attributes);
  if (FAILED(result)) return fail("the file could not be read", result);

  PROPVARIANT duration;
  PropVariantInit(&duration);
  if (SUCCEEDED(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &duration))) {
    info->seconds = static_cast<double>(duration.uhVal.QuadPart) / second;
  }
  PropVariantClear(&duration);

  // The picture as it is shown: the frame's size, or the part of it the encoder says is seen.
  IMFMediaType *native = nullptr;
  const DWORD videoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
  const DWORD audioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  if (SUCCEEDED(reader->GetNativeMediaType(videoStream, 0, &native))) {
    UINT32 width = 0, height = 0, numerator = 0, denominator = 1;
    MFGetAttributeSize(native, MF_MT_FRAME_SIZE, &width, &height);
    MFVideoArea area {};
    if (SUCCEEDED(native->GetBlob(
          MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof(area), nullptr))) {
      width = static_cast<UINT32>(area.Area.cx);
      height = static_cast<UINT32>(area.Area.cy);
    }
    MFGetAttributeRatio(native, MF_MT_FRAME_RATE, &numerator, &denominator);
    info->width = static_cast<int32_t>(width);
    info->height = static_cast<int32_t>(height);
    info->framesPerSecond = denominator ? static_cast<double>(numerator) / denominator : 0;
    release(native);
  }
  if (SUCCEEDED(reader->GetNativeMediaType(audioStream, 0, &native))) {
    info->sampleRate = static_cast<int32_t>(MFGetAttributeUINT32(native, MF_MT_AUDIO_SAMPLES_PER_SECOND, 0));
    info->channels = static_cast<int32_t>(MFGetAttributeUINT32(native, MF_MT_AUDIO_NUM_CHANNELS, 0));
    release(native);
  }

  // The sound between `from` and `to`, decoded to floats: its peak and its level.
  {
    Type floats;
    floats.guid(MF_MT_MAJOR_TYPE, MFMediaType_Audio).guid(MF_MT_SUBTYPE, MFAudioFormat_Float);
    result = floats.result;
    if (SUCCEEDED(result)) result = reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    if (SUCCEEDED(result)) result = reader->SetStreamSelection(audioStream, TRUE);
    if (SUCCEEDED(result)) result = reader->SetCurrentMediaType(audioStream, nullptr, floats.type);
    if (FAILED(result)) return fail("the sound could not be decoded", result);
    double sum = 0;
    size_t count = 0;
    float peak = 0;
    int channels = std::max(1, info->channels);
    int rate = std::max(1, info->sampleRate);
    for (;;) {
      DWORD flags = 0;
      LONGLONG time = 0;
      IMFSample *read = nullptr;
      result = reader->ReadSample(audioStream, 0, nullptr, &flags, &time, &read);
      if (FAILED(result)) return fail("the sound could not be read", result);
      if (read) {
        IMFMediaBuffer *buffer = nullptr;
        BYTE *data = nullptr;
        DWORD length = 0;
        if (SUCCEEDED(read->ConvertToContiguousBuffer(&buffer)) && SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
          const float *values = reinterpret_cast<const float *>(data);
          size_t frames = length / sizeof(float) / channels;
          for (size_t frame = 0; frame < frames; ++frame) {
            double seconds = static_cast<double>(time) / second + static_cast<double>(frame) / rate;
            if (seconds < from || seconds >= to) continue;
            for (int channel = 0; channel < channels; ++channel) {
              float value = values[frame * channels + channel];
              peak = std::max(peak, std::fabs(value));
              sum += static_cast<double>(value) * value;
              ++count;
            }
          }
          buffer->Unlock();
        }
        release(buffer);
        release(read);
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    info->peak = peak;
    info->rms = count ? static_cast<float>(std::sqrt(sum / count)) : 0;
  }

  // The picture at `at`, as BGRA rows from the top: the frame showing then.
  if (pixels && info->width > 0 && info->height > 0) {
    Type bgra;
    bgra.guid(MF_MT_MAJOR_TYPE, MFMediaType_Video).guid(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    result = bgra.result;
    if (SUCCEEDED(result)) result = reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    if (SUCCEEDED(result)) result = reader->SetStreamSelection(videoStream, TRUE);
    if (SUCCEEDED(result)) result = reader->SetCurrentMediaType(videoStream, nullptr, bgra.type);
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = 0;
    if (SUCCEEDED(result)) result = reader->SetCurrentPosition(GUID_NULL, position);
    if (FAILED(result)) return fail("the picture could not be decoded", result);
    IMFMediaType *current = nullptr;
    reader->GetCurrentMediaType(videoStream, &current);
    UINT32 frameWidth = 0, frameHeight = 0;
    MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &frameWidth, &frameHeight);
    INT32 stride = static_cast<INT32>(MFGetAttributeUINT32(current, MF_MT_DEFAULT_STRIDE, frameWidth * 4));
    release(current);
    LONGLONG wanted = static_cast<LONGLONG>(at * second);
    LONGLONG half = info->framesPerSecond > 0 ? static_cast<LONGLONG>(second / info->framesPerSecond / 2) : 0;
    bool found = false;
    while (!found) {
      DWORD flags = 0;
      LONGLONG time = 0;
      IMFSample *read = nullptr;
      result = reader->ReadSample(videoStream, 0, nullptr, &flags, &time, &read);
      if (FAILED(result)) return fail("the picture could not be read", result);
      if (read && time + half >= wanted) {
        IMFMediaBuffer *buffer = nullptr;
        BYTE *data = nullptr;
        if (SUCCEEDED(read->ConvertToContiguousBuffer(&buffer)) && SUCCEEDED(buffer->Lock(&data, nullptr, nullptr))) {
          // Rows from the top, whichever way the frame holds them.
          size_t row = static_cast<size_t>(std::abs(stride));
          for (int32_t y = 0; y < info->height && y < static_cast<int32_t>(frameHeight); ++y) {
            const BYTE *source = stride >= 0 ? data + y * row : data + (frameHeight - 1 - y) * row;
            std::memcpy(pixels + static_cast<size_t>(y) * info->width * 4, source,
              static_cast<size_t>(std::min<UINT32>(info->width, frameWidth)) * 4);
          }
          buffer->Unlock();
          found = true;
        }
        release(buffer);
      }
      release(read);
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (!found) return fail("the picture had no frame then", E_FAIL);
  }
  release(reader);
  started.stop();
  return true;
}

}  // extern "C"

#endif
