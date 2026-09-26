#if defined(__linux__) && !defined(__ANDROID__)
#include "DriftboxPipeWire.h"
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <errno.h>
#include <stdbool.h>

#define BLOCK 4096u
struct db_pw_output {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    db_pw_render render;
    void *context;
    atomic_bool enabled;
    atomic_uint in_render;
    atomic_uint_fast64_t frames;
    float left[BLOCK], right[BLOCK];
};
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { pw_init(NULL, NULL); }
static void message(char *dest, size_t size, const char *text) {
    if (dest && size) snprintf(dest, size, "%s", text);
}

static void process(void *context) {
    struct db_pw_output *out = context;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(out->stream);
    if (!buffer) return;
    struct spa_buffer *spa = buffer->buffer;
    if (spa->n_datas < 1 || !spa->datas[0].data || !spa->datas[0].chunk) {
        pw_stream_queue_buffer(out->stream, buffer);
        return;
    }
    struct spa_data *data = &spa->datas[0];
    float *samples = data->data;
    uint32_t frames = data->maxsize / (2 * sizeof(float));
    if (buffer->requested && buffer->requested < frames) frames = (uint32_t)buffer->requested;
    // Sequential consistency makes the pause barrier cover a callback that races with disable.
    // Once pause returns, later callbacks can only write silence until enable is called.
    atomic_fetch_add(&out->in_render, 1);
    if (atomic_load(&out->enabled)) {
        for (uint32_t offset = 0; offset < frames;) {
            uint32_t count = SPA_MIN(frames - offset, BLOCK);
            out->render(out->context, count, out->left, out->right);
            for (uint32_t i = 0; i < count; i++) {
                samples[2 * (offset + i)] = out->left[i];
                samples[2 * (offset + i) + 1] = out->right[i];
            }
            offset += count;
        }
        atomic_fetch_add_explicit(&out->frames, frames, memory_order_relaxed);
    } else {
        memset(samples, 0, frames * 2 * sizeof(float));
    }
    atomic_fetch_sub(&out->in_render, 1);
    data->chunk->offset = 0;
    data->chunk->stride = 2 * sizeof(float);
    data->chunk->size = frames * 2 * sizeof(float);
    buffer->size = frames;
    pw_stream_queue_buffer(out->stream, buffer);
}
static const struct pw_stream_events events = {
    PW_VERSION_STREAM_EVENTS, .process = process
};

db_pw_output *db_pw_open(db_pw_render render, void *context, uint32_t rate,
                        char *error, size_t error_size) {
    pthread_once(&initialized, initialize);
    struct db_pw_output *out = calloc(1, sizeof(*out));
    if (!out) { message(error, error_size, "out of memory"); return NULL; }
    atomic_init(&out->enabled, false);
    atomic_init(&out->in_render, 0);
    atomic_init(&out->frames, 0);
    if (!atomic_is_lock_free(&out->enabled) || !atomic_is_lock_free(&out->in_render) ||
        !atomic_is_lock_free(&out->frames)) {
        message(error, error_size, "this platform lacks lock-free audio atomics");
        free(out); return NULL;
    }
    out->render = render;
    out->context = context;
    out->loop = pw_thread_loop_new("driftbox-audio", NULL);
    if (!out->loop) goto failed;
    out->stream = pw_stream_new_simple(pw_thread_loop_get_loop(out->loop), "Driftbox",
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
            PW_KEY_MEDIA_ROLE, "Music", PW_KEY_NODE_NAME, "driftbox-play", NULL), &events, out);
    if (!out->stream) goto failed;
    uint8_t storage[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
    const struct spa_pod *params[] = { spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .rate = rate, .channels = 2,
            .position = { SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR })) };
    int result = pw_stream_connect(out->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
        params, 1);
    if (result < 0) {
        message(error, error_size, strerror(-result));
        goto cleanup;
    }
    result = pw_thread_loop_start(out->loop);
    if (result < 0) {
        message(error, error_size, strerror(-result));
        goto cleanup;
    }
    return out;
failed:
    message(error, error_size, strerror(errno));
cleanup:
    if (out->stream) pw_stream_destroy(out->stream);
    if (out->loop) pw_thread_loop_destroy(out->loop);
    free(out);
    return NULL;
}

void db_pw_pause(db_pw_output *out) {
    atomic_store(&out->enabled, false);
    while (atomic_load(&out->in_render)) {
        const struct timespec delay = { .tv_nsec = 1000000 };
        nanosleep(&delay, NULL);
    }
}
void db_pw_enable(db_pw_output *out) { atomic_store(&out->enabled, true); }
void db_pw_close(db_pw_output *out) {
    if (!out) return;
    db_pw_pause(out);
    pw_thread_loop_stop(out->loop);
    pw_stream_destroy(out->stream);
    pw_thread_loop_destroy(out->loop);
    free(out);
}
int db_pw_status(db_pw_output *out, char *error, size_t error_size) {
    pw_thread_loop_lock(out->loop);
    const char *reason = NULL;
    enum pw_stream_state state = pw_stream_get_state(out->stream, &reason);
    int result = 0;
    switch (state) {
    case PW_STREAM_STATE_ERROR:
    case PW_STREAM_STATE_UNCONNECTED:
        message(error, error_size, reason ? reason : "PipeWire disconnected");
        result = -1; break;
    case PW_STREAM_STATE_PAUSED: result = 1; break;
    case PW_STREAM_STATE_STREAMING: result = 2; break;
    default: break;
    }
    pw_thread_loop_unlock(out->loop);
    return result;
}
uint64_t db_pw_frames(db_pw_output *out) {
    return atomic_load_explicit(&out->frames, memory_order_relaxed);
}

static volatile sig_atomic_t interrupted;
static struct sigaction old_int, old_term;
static void interrupt_handler(int number) { (void)number; interrupted = 1; }
int db_linux_interrupt_begin(void) {
    struct sigaction action = { .sa_handler = interrupt_handler };
    sigemptyset(&action.sa_mask);
    interrupted = 0;
    if (sigaction(SIGINT, &action, &old_int) < 0) return -1;
    if (sigaction(SIGTERM, &action, &old_term) < 0) {
        sigaction(SIGINT, &old_int, NULL); return -1;
    }
    return 0;
}
int db_linux_interrupted(void) { return interrupted != 0; }
void db_linux_interrupt_end(void) {
    sigaction(SIGINT, &old_int, NULL);
    sigaction(SIGTERM, &old_term, NULL);
}
#endif
