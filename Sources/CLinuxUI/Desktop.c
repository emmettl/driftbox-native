#if defined(__linux__) && !defined(__ANDROID__)
#include "DriftboxLinuxUI.h"
// Keep the response-based APIs available on the GTK 4.8 CI baseline. They remain
// asynchronous; no gtk_dialog_run or nested main loop is used.
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_8
#include <gtk/gtk.h>
#include <glib-unix.h>
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

struct db_desktop {
    GtkWidget *window, *area, *bar, *popover;
    GObject *dialog;
    GFile *folder;
    GMainLoop *loop;
    GSimpleActionGroup *actions;
    guint source;
    void (*drain)(void *);
    void *context, *reply_context;
    db_reply reply;
    db_draw draw;
    db_input_callback input;
    db_command command;
    db_can_close can_close;
    db_drop_callback dropped;
    gboolean closed;
    double x, y;
    int button;
    char error[512];
};
static int modifiers(GdkModifierType state) {
    return ((state & GDK_SHIFT_MASK) ? 1 : 0) | ((state & GDK_CONTROL_MASK) ? 2 : 0)
        | ((state & GDK_ALT_MASK) ? 4 : 0) | ((state & GDK_SUPER_MASK) ? 8 : 0);
}
static void input(db_desktop *w, db_input event) { w->input(w->context, &event); }
static gboolean ready(gint fd, GIOCondition condition, gpointer context) {
    db_desktop *w = context;
    uint64_t value;
    ssize_t n;
    do { n = read(fd, &value, sizeof(value)); } while (n < 0 && errno == EINTR);
    if (n < 0 && errno == EAGAIN && !(condition & (G_IO_ERR | G_IO_HUP))) return G_SOURCE_CONTINUE;
    if (n != (ssize_t)sizeof(value)) {
        g_strlcpy(w->error, "Swift main-queue wakeup failed", sizeof(w->error));
        db_desktop_close(w);
    } else w->drain(NULL);
    return G_SOURCE_CONTINUE;
}
static gboolean render(GtkGLArea *area, GdkGLContext *gl, gpointer context) {
    (void)gl;
    db_desktop *w = context;
    GError *error = gtk_gl_area_get_error(area);
    if (error) {
        g_strlcpy(w->error, error->message, sizeof(w->error));
        db_desktop_close(w);
    } else w->draw(w->context, gtk_widget_get_width(GTK_WIDGET(area)),
                    gtk_widget_get_height(GTK_WIDGET(area)), gtk_widget_get_scale_factor(GTK_WIDGET(area)));
    return TRUE;
}
static gboolean tick(GtkWidget *area, GdkFrameClock *clock, gpointer context) {
    (void)clock; (void)context;
    gtk_gl_area_queue_render(GTK_GL_AREA(area));
    return G_SOURCE_CONTINUE;
}
static gboolean closing(GtkWindow *window, gpointer context) {
    (void)window;
    db_desktop *w = context;
    if (w->can_close(w->context)) db_desktop_close(w);
    // Retain the context until Swift has released Desktop and all its GPU resources.
    return TRUE;
}
static void pressed(GtkGestureClick *gesture, int count, double x, double y, gpointer context) {
    (void)count;
    db_desktop *w = context;
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    if (button != 1 && button != 3) return;
    w->x=x; w->y=y;
    w->button = button == 3 ? 1 : 0;
    gtk_widget_grab_focus(w->area);
    input(w, (db_input){.kind=1, .x=x, .y=y, .button=w->button,
        .modifiers=modifiers(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)))});
}
static void released(GtkGestureClick *gesture, int count, double x, double y, gpointer context) {
    (void)count;
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    if (button != 1 && button != 3) return;
    db_desktop *w = context;
    input(w, (db_input){.kind=3, .x=x, .y=y, .button=w->button});
}
static void cancelled(GtkGesture *gesture, GdkEventSequence *sequence, gpointer context) {
    (void)gesture; (void)sequence;
    db_desktop *w = context;
    input(w, (db_input){.kind=8, .x=w->x, .y=w->y, .button=w->button});
}
static void motion(GtkEventControllerMotion *controller, double x, double y, gpointer context) {
    db_desktop *w = context; w->x=x; w->y=y;
    input(w, (db_input){.kind=2, .x=x, .y=y, .button=w->button,
        .modifiers=modifiers(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller)))});
}
static gboolean scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer context) {
    db_desktop *w = context;
    input(w, (db_input){.kind=4, .x=w->x, .y=w->y, .dx=dx*32, .dy=dy*32,
        .modifiers=modifiers(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller)))});
    return TRUE;
}
static void focus_lost(GtkEventControllerFocus *controller, gpointer context) {
    (void)controller; input(context, (db_input){.kind=5});
}
static int key_value(guint key) {
    switch(key) {
        case GDK_KEY_space: return -1; case GDK_KEY_Return: case GDK_KEY_KP_Enter: return -2;
        case GDK_KEY_Escape: return -3; case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return -4;
        case GDK_KEY_BackSpace: return -5; case GDK_KEY_Delete: return -6;
        case GDK_KEY_Left: return -7; case GDK_KEY_Right: return -8;
        case GDK_KEY_Up: return -9; case GDK_KEY_Down: return -10;
        case GDK_KEY_Home: return -11; case GDK_KEY_End: return -12;
        case GDK_KEY_Page_Up: return -13; case GDK_KEY_Page_Down: return -14;
        default: if (key >= GDK_KEY_F1 && key <= GDK_KEY_F24) return -101-(key-GDK_KEY_F1);
            return gdk_keyval_to_unicode(key);
    }
}
static gboolean key_down(GtkEventControllerKey *controller, guint key, guint code,
                         GdkModifierType state, gpointer context) {
    (void)controller;
    input(context, (db_input){.kind=6, .key=key_value(key), .code=code, .modifiers=modifiers(state)});
    return TRUE;
}
static void key_up(GtkEventControllerKey *controller, guint key, guint code,
                    GdkModifierType state, gpointer context) {
    (void)controller;
    input(context, (db_input){.kind=7, .key=key_value(key), .code=code, .modifiers=modifiers(state)});
}
static gboolean dropped(GtkDropTarget *target, const GValue *value, double x, double y, gpointer context) {
    (void)target;
    db_desktop *w=context;
    if (w->reply || !G_VALUE_HOLDS(value,GDK_TYPE_FILE_LIST)) return FALSE;
    GdkFileList *list=g_value_get_boxed(value);
    if (!list) return FALSE;
    GString *uris=g_string_new("");
    for (GSList *item=gdk_file_list_get_files(list); item; item=item->next) {
        GFile *file=item->data;
        if (!g_file_is_native(file)) continue;
        char *uri=g_file_get_uri(file);
        if (uris->len) g_string_append_c(uris,'\n');
        g_string_append(uris,uri); g_free(uri);
    }
    gboolean accepted=uris->len>0;
    if (accepted) {
        gtk_widget_grab_focus(w->area);
        w->dropped(w->context,uris->str,x,y);
    }
    g_string_free(uris,TRUE);
    return accepted;
}
db_desktop *db_desktop_new(void *context, db_draw draw, db_input_callback events,
                          db_command command, db_can_close can_close, db_drop_callback files, char *error, size_t size) {
    if (!gtk_init_check()) { snprintf(error,size,"GTK could not open the desktop display"); return NULL; }
    int (*handle)(void) = dlsym(RTLD_DEFAULT,"_dispatch_get_main_queue_handle_4CF");
    void (*drain)(void *) = dlsym(RTLD_DEFAULT,"_dispatch_main_queue_callback_4CF");
    if (!handle || !drain) { snprintf(error,size,"Swift main-queue integration unavailable"); return NULL; }
    int fd = handle();
    if (fd < 0) { snprintf(error,size,"Swift main-queue handle unavailable"); return NULL; }
    db_desktop *w = g_new0(db_desktop,1);
    w->context=context; w->draw=draw; w->input=events; w->command=command; w->can_close=can_close; w->drain=drain; w->dropped=files;
    w->loop=g_main_loop_new(NULL,FALSE);
    w->window=gtk_window_new(); g_object_ref(w->window);
    gtk_window_set_title(GTK_WINDOW(w->window),"Driftbox · Linux preview");
    gtk_window_set_default_size(GTK_WINDOW(w->window),1000,650);
    GtkWidget *box=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    gtk_window_set_child(GTK_WINDOW(w->window),box);
    GMenu *empty=g_menu_new();
    w->bar=gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(empty)); g_object_unref(empty);
    gtk_box_append(GTK_BOX(box),w->bar);
    w->area=gtk_gl_area_new();
    gtk_widget_set_vexpand(w->area,TRUE); gtk_widget_set_hexpand(w->area,TRUE);
    gtk_widget_set_focusable(w->area,TRUE);
#if GTK_CHECK_VERSION(4,12,0)
    gtk_gl_area_set_allowed_apis(GTK_GL_AREA(w->area),GDK_GL_API_GLES);
#else
    gtk_gl_area_set_use_es(GTK_GL_AREA(w->area),TRUE);
#endif
    gtk_gl_area_set_required_version(GTK_GL_AREA(w->area),3,0);
    gtk_box_append(GTK_BOX(box),w->area);
    w->actions=g_simple_action_group_new();
    gtk_widget_insert_action_group(w->window,"win",G_ACTION_GROUP(w->actions));
    g_signal_connect(w->area,"render",G_CALLBACK(render),w);
    g_signal_connect(w->window,"close-request",G_CALLBACK(closing),w);
    gtk_widget_add_tick_callback(w->area,tick,w,NULL);
    GtkGesture *click=gtk_gesture_click_new(); gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click),0);
    g_signal_connect(click,"pressed",G_CALLBACK(pressed),w); g_signal_connect(click,"released",G_CALLBACK(released),w);
    g_signal_connect(click,"cancel",G_CALLBACK(cancelled),w);
    gtk_widget_add_controller(w->area,GTK_EVENT_CONTROLLER(click));
    GtkEventController *move=gtk_event_controller_motion_new();
    g_signal_connect(move,"motion",G_CALLBACK(motion),w); gtk_widget_add_controller(w->area,move);
    GtkEventController *wheel=gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(wheel,"scroll",G_CALLBACK(scroll),w); gtk_widget_add_controller(w->area,wheel);
    GtkEventController *focus=gtk_event_controller_focus_new();
    g_signal_connect(focus,"leave",G_CALLBACK(focus_lost),w); gtk_widget_add_controller(w->area,focus);
    GtkEventController *keys=gtk_event_controller_key_new();
    g_signal_connect(keys,"key-pressed",G_CALLBACK(key_down),w); g_signal_connect(keys,"key-released",G_CALLBACK(key_up),w);
    gtk_widget_add_controller(w->area,keys);
    GtkDropTarget *drop=gtk_drop_target_new(GDK_TYPE_FILE_LIST,GDK_ACTION_COPY);
    g_signal_connect(drop,"drop",G_CALLBACK(dropped),w);
    gtk_widget_add_controller(w->area,GTK_EVENT_CONTROLLER(drop));
    w->source=g_unix_fd_add(fd,G_IO_IN,ready,w);
    return w;
}
int db_desktop_prepare(db_desktop *w) {
    gtk_widget_realize(w->window); gtk_widget_realize(w->area);
    db_desktop_current(w);
    GError *error=gtk_gl_area_get_error(GTK_GL_AREA(w->area));
    if (error) { g_strlcpy(w->error,error->message,sizeof(w->error)); return 0; }
    return 1;
}
void db_desktop_current(db_desktop *w) { gtk_gl_area_make_current(GTK_GL_AREA(w->area)); }
void db_desktop_run(db_desktop *w) {
    gtk_window_present(GTK_WINDOW(w->window)); gtk_widget_grab_focus(w->area);
    if (!w->closed) g_main_loop_run(w->loop);
}
void db_desktop_close(db_desktop *w) { w->closed=TRUE; g_main_loop_quit(w->loop); }
void db_desktop_title(db_desktop *w,const char *title) { gtk_window_set_title(GTK_WINDOW(w->window),title); }
const char *db_desktop_error(db_desktop *w) { return w->error; }
static void reply(db_desktop *w,int answer,const char *value) {
    db_reply callback=w->reply; void *context=w->reply_context;
    w->reply=NULL; w->reply_context=NULL;
    if (callback) callback(context,answer,value);
}
// Disconnect before unparenting: an animated popdown must not later cancel a new
// dialog's reply or call back into a freed desktop.
static void dismiss_popup(db_desktop *w) {
    if (!w->popover) return;
    GtkWidget *popover=w->popover; w->popover=NULL;
    g_signal_handlers_disconnect_by_data(popover,w);
    gtk_popover_popdown(GTK_POPOVER(popover));
    gtk_widget_unparent(popover);
}
void db_desktop_free(db_desktop *w) {
    if (w->dialog) g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_CANCEL);
    dismiss_popup(w);
    reply(w,0,"");
    g_source_remove(w->source);
    gtk_window_destroy(GTK_WINDOW(w->window)); g_object_unref(w->window);
    g_clear_object(&w->folder);
    g_object_unref(w->actions); g_main_loop_unref(w->loop); g_free(w);
}
// Menus stay native; only command IDs cross the bridge.
db_menu *db_menu_new(void) { return (db_menu *)g_menu_new(); }
void db_menu_free(db_menu *m) { g_object_unref(m); }
void db_menu_submenu(db_menu *m,const char *title,db_menu *child) { g_menu_append_submenu((GMenu *)m,title,(GMenuModel *)child); }
void db_menu_section(db_menu *m,db_menu *child) { g_menu_append_section((GMenu *)m,NULL,(GMenuModel *)child); }
void db_menu_item(db_menu *m,const char *title,int id) {
    char action[40]; snprintf(action,sizeof(action),"win.c%d",id); g_menu_append((GMenu *)m,title,action);
}
static void activated(GSimpleAction *action,GVariant *parameter,gpointer context) {
    (void)parameter;
    db_desktop *w=context;
    int id=atoi(g_action_get_name(G_ACTION(action))+1);
    if (w->popover) {
        db_reply callback=w->reply; void *reply_context=w->reply_context;
        w->reply=NULL; w->reply_context=NULL;
        dismiss_popup(w);
        if (callback) callback(reply_context,id+1,"");
    }
    else w->command(w->context,id);
}
void db_desktop_action(db_desktop *w,int id,int enabled,int checked) {
    char name[32]; snprintf(name,sizeof(name),"c%d",id);
    GSimpleAction *action=(GSimpleAction *)g_action_map_lookup_action(G_ACTION_MAP(w->actions),name);
    if (!action) {
        action=g_simple_action_new_stateful(name,NULL,g_variant_new_boolean(checked));
        g_signal_connect(action,"activate",G_CALLBACK(activated),w);
        g_action_map_add_action(G_ACTION_MAP(w->actions),G_ACTION(action)); g_object_unref(action);
    }
    g_simple_action_set_enabled(action,enabled); g_simple_action_set_state(action,g_variant_new_boolean(checked));
}
void db_desktop_menu(db_desktop *w,db_menu *menu) { gtk_popover_menu_bar_set_menu_model(GTK_POPOVER_MENU_BAR(w->bar),(GMenuModel *)menu); }
static void file_response(GtkNativeDialog *dialog,int response,gpointer context) {
    db_desktop *w=context;
    GString *uris=g_string_new("");
    if (response==GTK_RESPONSE_ACCEPT) {
        GFile *folder=gtk_file_chooser_get_current_folder(GTK_FILE_CHOOSER(dialog));
        if (folder) { g_set_object(&w->folder,folder); g_object_unref(folder); }
        GListModel *files=gtk_file_chooser_get_files(GTK_FILE_CHOOSER(dialog));
        for (guint i=0;i<g_list_model_get_n_items(files);i++) {
            GFile *file=g_list_model_get_item(files,i); char *uri=g_file_get_uri(file);
            if (i) g_string_append_c(uris,'\n');
            g_string_append(uris,uri); g_free(uri); g_object_unref(file);
        }
        g_object_unref(files);
    }
    w->dialog=NULL; gtk_native_dialog_destroy(dialog); g_object_unref(dialog);
    reply(w,response==GTK_RESPONSE_ACCEPT,uris->str); g_string_free(uris,TRUE);
}
void db_desktop_files(db_desktop *w,int save,int multiple,const char *extensions,const char *name,void *context,db_reply callback) {
    if (w->reply) { callback(context,0,""); return; }
    w->reply=callback; w->reply_context=context;
    GtkFileChooserNative *dialog=gtk_file_chooser_native_new(save?"Save song":"Open file",GTK_WINDOW(w->window),
        save?GTK_FILE_CHOOSER_ACTION_SAVE:GTK_FILE_CHOOSER_ACTION_OPEN,save?"Save":"Open","Cancel");
    w->dialog=G_OBJECT(dialog);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog),TRUE);
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog),multiple);
    if (w->folder) gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog),w->folder,NULL);
    if (save) gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog),name);
    GtkFileFilter *filter=gtk_file_filter_new(); g_object_ref_sink(filter); gtk_file_filter_set_name(filter,extensions);
    char **parts=g_strsplit(extensions,";",-1);
    for (int i=0;parts[i];i++) { char *pattern=g_strconcat("*.",parts[i],NULL); gtk_file_filter_add_pattern(filter,pattern); g_free(pattern); }
    g_strfreev(parts); gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog),filter); g_object_unref(filter);
    g_signal_connect(dialog,"response",G_CALLBACK(file_response),w); gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}
static void question_response(GtkDialog *dialog,int response,gpointer context) {
    db_desktop *w=context; w->dialog=NULL;
    gtk_window_destroy(GTK_WINDOW(dialog));
    reply(w,response==1?1:response==2?2:0,"");
}
void db_desktop_save_question(db_desktop *w,const char *name,void *context,db_reply callback) {
    if (w->reply) { callback(context,0,""); return; }
    w->reply=callback; w->reply_context=context;
    GtkWidget *dialog=gtk_message_dialog_new(GTK_WINDOW(w->window),GTK_DIALOG_MODAL,GTK_MESSAGE_QUESTION,GTK_BUTTONS_NONE,
        "Save changes to “%s”?",name);
    gtk_dialog_add_buttons(GTK_DIALOG(dialog),"Cancel",GTK_RESPONSE_CANCEL,"Discard",2,"Save",1,NULL);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog),GTK_RESPONSE_CANCEL);
    w->dialog=G_OBJECT(dialog); g_signal_connect(dialog,"response",G_CALLBACK(question_response),w);
    gtk_window_present(GTK_WINDOW(dialog));
}
static void popup_closed(GtkPopover *popover,gpointer context) {
    db_desktop *w=context; w->popover=NULL; reply(w,0,""); gtk_widget_unparent(GTK_WIDGET(popover));
}
void db_desktop_popup(db_desktop *w,db_menu *menu,double x,double y,void *context,db_reply callback) {
    if (w->reply) { callback(context,0,""); return; }
    w->reply=callback; w->reply_context=context;
    w->popover=gtk_popover_menu_new_from_model((GMenuModel *)menu); gtk_widget_set_parent(w->popover,w->area);
    GdkRectangle point={(int)x,(int)y,1,1}; gtk_popover_set_pointing_to(GTK_POPOVER(w->popover),&point);
    g_signal_connect(w->popover,"closed",G_CALLBACK(popup_closed),w); gtk_popover_popup(GTK_POPOVER(w->popover));
}
#endif
