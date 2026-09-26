#if defined(__linux__) && !defined(__ANDROID__)
#include "DriftboxPipeWire.h"
#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void db_pw_initialize(void);
struct sink {
    struct sink *next;
    uint32_t id;
    char *name, *description;
};
struct db_pw_discovery {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct pw_metadata *metadata;
    struct spa_hook core_listener, registry_listener, metadata_listener;
    struct sink *sinks;
    char *default_sink;
    char error[512];
    uint32_t metadata_id;
    int sequence;
    bool ready, started;
};
static void core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    (void)seq;
    db_pw_discovery *d=data;
    if (id==PW_ID_CORE || res==-EPIPE)
        snprintf(d->error,sizeof(d->error),"%s",message ? message : "PipeWire disconnected");
}
static void core_done(void *data, uint32_t id, int seq) {
    db_pw_discovery *d=data;
    if (id==PW_ID_CORE && seq==d->sequence) d->ready=true;
}
static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS, .done=core_done, .error=core_error
};
static int property(void *data,uint32_t subject,const char *key,const char *type,const char *value) {
    (void)type;
    db_pw_discovery *d=data;
    if (subject==PW_ID_CORE && (!key || strcmp(key,"default.audio.sink")==0)) {
        free(d->default_sink);
        d->default_sink=value ? strdup(value) : NULL;
    }
    return 0;
}
static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS, .property=property
};
static void global(void *data,uint32_t id,uint32_t permissions,const char *type,
                   uint32_t version,const struct spa_dict *props) {
    (void)permissions;
    db_pw_discovery *d=data;
    if (!props) return;
    if (strcmp(type,PW_TYPE_INTERFACE_Node)==0) {
        const char *media=spa_dict_lookup(props,PW_KEY_MEDIA_CLASS);
        const char *name=spa_dict_lookup(props,PW_KEY_NODE_NAME);
        if (!media || strcmp(media,"Audio/Sink") || !name) return;
        const char *description=spa_dict_lookup(props,PW_KEY_NODE_DESCRIPTION);
        if (!description) description=spa_dict_lookup(props,PW_KEY_NODE_NICK);
        struct sink *sink=calloc(1,sizeof(*sink));
        if (!sink) return;
        sink->id=id; sink->name=strdup(name); sink->description=strdup(description ? description : name);
        if (!sink->name || !sink->description) { free(sink->name); free(sink->description); free(sink); return; }
        sink->next=d->sinks; d->sinks=sink;
    } else if (!d->metadata && strcmp(type,PW_TYPE_INTERFACE_Metadata)==0) {
        const char *name=spa_dict_lookup(props,PW_KEY_METADATA_NAME);
        if (!name || strcmp(name,"default")) return;
        d->metadata=pw_registry_bind(d->registry,id,type,SPA_MIN(version,(uint32_t)PW_VERSION_METADATA),0);
        if (d->metadata) {
            d->metadata_id=id;
            pw_metadata_add_listener(d->metadata,&d->metadata_listener,&metadata_events,d);
            // Wait for metadata's initial properties as well as the registry round trip.
            d->ready=false;
            d->sequence=pw_core_sync(d->core,PW_ID_CORE,0);
        }
    }
}
static void global_remove(void *data,uint32_t id) {
    db_pw_discovery *d=data;
    for (struct sink **at=&d->sinks; *at;) {
        struct sink *sink=*at;
        if (sink->id!=id) { at=&sink->next; continue; }
        *at=sink->next; free(sink->name); free(sink->description); free(sink);
    }
    if (d->metadata && d->metadata_id==id) {
        spa_hook_remove(&d->metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)d->metadata); d->metadata=NULL;
        free(d->default_sink); d->default_sink=NULL;
    }
}
static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS, .global=global, .global_remove=global_remove
};
db_pw_discovery *db_pw_discovery_open(char *error,size_t size) {
    db_pw_initialize();
    db_pw_discovery *d=calloc(1,sizeof(*d));
    if (!d) { snprintf(error,size,"out of memory"); return NULL; }
    d->loop=pw_thread_loop_new("driftbox-devices",NULL);
    if (!d->loop) goto failed;
    d->context=pw_context_new(pw_thread_loop_get_loop(d->loop),NULL,0);
    if (!d->context) goto failed;
    d->core=pw_context_connect(d->context,NULL,0);
    if (!d->core) goto failed;
    pw_core_add_listener(d->core,&d->core_listener,&core_events,d);
    d->registry=pw_core_get_registry(d->core,PW_VERSION_REGISTRY,0);
    if (!d->registry) goto failed;
    pw_registry_add_listener(d->registry,&d->registry_listener,&registry_events,d);
    d->sequence=pw_core_sync(d->core,PW_ID_CORE,0);
    int result=pw_thread_loop_start(d->loop);
    if (result<0) { errno=-result; goto failed; }
    d->started=true;
    return d;
failed:
    snprintf(error,size,"%s",strerror(errno));
    db_pw_discovery_close(d);
    return NULL;
}
int db_pw_discovery_snapshot(db_pw_discovery *d,db_pw_device emit,void *data,char *error,size_t size) {
    pw_thread_loop_lock(d->loop);
    int result=d->error[0] ? -1 : d->ready ? 1 : 0;
    if (result<0) snprintf(error,size,"%s",d->error);
    if (result==1) {
        emit(data,NULL,d->default_sink ? d->default_sink : "");
        for (struct sink *sink=d->sinks;sink;sink=sink->next) emit(data,sink->name,sink->description);
    }
    pw_thread_loop_unlock(d->loop);
    return result;
}
void db_pw_discovery_close(db_pw_discovery *d) {
    if (!d) return;
    if (d->started) pw_thread_loop_stop(d->loop);
    if (d->metadata) { spa_hook_remove(&d->metadata_listener); pw_proxy_destroy((struct pw_proxy *)d->metadata); }
    if (d->registry) { spa_hook_remove(&d->registry_listener); pw_proxy_destroy((struct pw_proxy *)d->registry); }
    if (d->core) { spa_hook_remove(&d->core_listener); pw_core_disconnect(d->core); }
    if (d->context) pw_context_destroy(d->context);
    if (d->loop) pw_thread_loop_destroy(d->loop);
    while (d->sinks) {
        struct sink *sink=d->sinks; d->sinks=sink->next;
        free(sink->name); free(sink->description); free(sink);
    }
    free(d->default_sink); free(d);
}
#endif
