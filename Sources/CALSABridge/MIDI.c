#if defined(__linux__) && !defined(__ANDROID__)
#define _GNU_SOURCE
#include "DriftboxALSA.h"
#include <alsa/asoundlib.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>

struct db_midi {
    snd_seq_t *seq;
    snd_midi_event_t *encoder, *decoder;
    int client, input, output, wake;
    struct pollfd *fds;
    int count;
};
db_midi *db_midi_open(const char *name, char *error, size_t size) {
    db_midi *m=calloc(1,sizeof(*m));
    if (!m) { snprintf(error,size,"MIDI allocation failed"); return NULL; }
    m->wake=-1;
    int result=snd_seq_open(&m->seq,"default",SND_SEQ_OPEN_DUPLEX,SND_SEQ_NONBLOCK);
    if (result<0) goto fail;
    m->client=snd_seq_client_id(m->seq);
    result=snd_seq_set_client_name(m->seq,name);
    if (result<0) goto fail;
    m->input=snd_seq_create_simple_port(m->seq,"Input",
        SND_SEQ_PORT_CAP_WRITE|SND_SEQ_PORT_CAP_SUBS_WRITE,
        SND_SEQ_PORT_TYPE_MIDI_GENERIC|SND_SEQ_PORT_TYPE_APPLICATION);
    if (m->input<0) { result=m->input; goto fail; }
    m->output=snd_seq_create_simple_port(m->seq,"Output",
        SND_SEQ_PORT_CAP_READ|SND_SEQ_PORT_CAP_SUBS_READ,
        SND_SEQ_PORT_TYPE_MIDI_GENERIC|SND_SEQ_PORT_TYPE_APPLICATION);
    if (m->output<0) { result=m->output; goto fail; }
    result=snd_midi_event_new(32,&m->encoder); if (result<0) goto fail;
    result=snd_midi_event_new(32,&m->decoder); if (result<0) goto fail;
    snd_midi_event_no_status(m->decoder,1);
    result=snd_seq_connect_from(m->seq,m->input,SND_SEQ_CLIENT_SYSTEM,SND_SEQ_PORT_SYSTEM_ANNOUNCE);
    if (result<0) goto fail;
    m->wake=eventfd(0,EFD_NONBLOCK|EFD_CLOEXEC);
    if (m->wake<0) { result=-errno; goto fail; }
    m->count=snd_seq_poll_descriptors_count(m->seq,POLLIN);
    if (m->count<=0) { result=-EIO; goto fail; }
    m->fds=calloc((size_t)m->count+1,sizeof(struct pollfd));
    if (!m->fds) { result=-ENOMEM; goto fail; }
    result=snd_seq_poll_descriptors(m->seq,m->fds,(unsigned)m->count,POLLIN);
    if (result<0) goto fail;
    m->fds[m->count]=(struct pollfd){.fd=m->wake,.events=POLLIN};
    return m;
fail:
    snprintf(error,size,"ALSA MIDI: %s",snd_strerror(result));
    db_midi_close(m); return NULL;
}
void db_midi_close(db_midi *m) {
    if (!m) return;
    if (m->seq) snd_seq_close(m->seq);
    if (m->encoder) snd_midi_event_free(m->encoder);
    if (m->decoder) snd_midi_event_free(m->decoder);
    if (m->wake>=0) close(m->wake);
    free(m->fds); free(m);
}
int db_midi_ports(db_midi *m,void *context,db_midi_port_callback callback) {
    snd_seq_client_info_t *client; snd_seq_port_info_t *port;
    snd_seq_client_info_alloca(&client); snd_seq_port_info_alloca(&port);
    snd_seq_client_info_set_client(client,-1);
    int result;
    while ((result=snd_seq_query_next_client(m->seq,client))>=0) {
        int id=snd_seq_client_info_get_client(client);
        if (id==m->client || id==SND_SEQ_CLIENT_SYSTEM) continue;
        snd_seq_port_info_set_client(port,id); snd_seq_port_info_set_port(port,-1);
        while (snd_seq_query_next_port(m->seq,port)>=0) {
            unsigned cap=snd_seq_port_info_get_capability(port);
            if (cap&SND_SEQ_PORT_CAP_NO_EXPORT) continue;
            int flags=0;
            if ((cap&(SND_SEQ_PORT_CAP_READ|SND_SEQ_PORT_CAP_SUBS_READ)) ==
                (SND_SEQ_PORT_CAP_READ|SND_SEQ_PORT_CAP_SUBS_READ)) flags|=1;
            if ((cap&(SND_SEQ_PORT_CAP_WRITE|SND_SEQ_PORT_CAP_SUBS_WRITE)) ==
                (SND_SEQ_PORT_CAP_WRITE|SND_SEQ_PORT_CAP_SUBS_WRITE)) flags|=2;
            if (flags) callback(context,id,snd_seq_port_info_get_port(port),
                snd_seq_client_info_get_name(client),snd_seq_port_info_get_name(port),flags);
        }
    }
    return result==-ENOENT ? 0 : result;
}
int db_midi_connect(db_midi *m,int client,int port,int connect) {
    return connect ? snd_seq_connect_from(m->seq,m->input,client,port)
        : snd_seq_disconnect_from(m->seq,m->input,client,port);
}
int db_midi_receive(db_midi *m,int *client,int *port,uint8_t bytes[3],int *length) {
    snd_seq_event_t *event=NULL;
    int result=snd_seq_event_input(m->seq,&event);
    if (result==-EAGAIN) return 0;
    if (result<0) return result;
    *client=event->source.client; *port=event->source.port;
    if (event->source.client==SND_SEQ_CLIENT_SYSTEM) {
        *client=-1; *port=-1;
        if (event->type==SND_SEQ_EVENT_CLIENT_EXIT || event->type==SND_SEQ_EVENT_PORT_EXIT) {
            *client=event->data.addr.client;
            if (event->type==SND_SEQ_EVENT_PORT_EXIT) *port=event->data.addr.port;
        }
        snd_seq_free_event(event); return 2;
    }
    // SysEx is outside the shared short-message port contract for this first backend.
    if (event->type==SND_SEQ_EVENT_SYSEX) {
        snd_seq_free_event(event); *length=0; return 1;
    }
    snd_midi_event_reset_decode(m->decoder);
    long count=snd_midi_event_decode(m->decoder,bytes,3,event);
    snd_seq_free_event(event);
    *length=count>0 ? (int)count : 0;
    return 1;
}
int db_midi_send(db_midi *m,int client,int port,const uint8_t *bytes,int length) {
    snd_seq_event_t event; snd_seq_ev_clear(&event);
    snd_midi_event_reset_encode(m->encoder);
    long used=snd_midi_event_encode(m->encoder,bytes,length,&event);
    if (used!=length || event.type==SND_SEQ_EVENT_NONE) return -EINVAL;
    snd_seq_ev_set_source(&event,m->output); snd_seq_ev_set_direct(&event);
    if (client<0) snd_seq_ev_set_subs(&event);
    else snd_seq_ev_set_dest(&event,client,port);
    return snd_seq_event_output_direct(m->seq,&event);
}
void db_midi_wake(db_midi *m) {
    uint64_t one=1; ssize_t result;
    do { result=write(m->wake,&one,sizeof(one)); } while (result<0 && errno==EINTR);
}
int db_midi_wait(db_midi *m,int64_t nanoseconds) {
    if (nanoseconds<0) nanoseconds=0;
    struct timespec time={.tv_sec=nanoseconds/1000000000,.tv_nsec=nanoseconds%1000000000};
    int result=ppoll(m->fds,(nfds_t)m->count+1,&time,NULL);
    if (result<0) return errno==EINTR ? 0 : -errno;
    uint64_t value;
    while (read(m->wake,&value,sizeof(value))<0 && errno==EINTR) {}
    for (int i=0;i<m->count;i++)
        if (m->fds[i].revents&(POLLERR|POLLHUP|POLLNVAL)) return -EIO;
    return 0;
}
#endif
