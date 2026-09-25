// Android's media codecs, which the Swift SDK's Android module does not bring in: the extractor
// that finds a file's audio, the codecs that decode it, and the muxer the phone's check writes an
// encoded file with. Declarations only: every call is made from Swift.
#pragma once
#ifdef __ANDROID__
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>
#endif
