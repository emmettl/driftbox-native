#if defined(__linux__) && !defined(__ANDROID__)
#include "DriftboxLinuxUI.h"
#include <gtk/gtk.h>
#include <glib-unix.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

struct db_window {
    GtkWidget *window, *area;
    GMainLoop *loop;
    guint dispatch_source;
    void (*drain_dispatch)(void *);
    void *context;
    db_draw draw;
    db_event event;
    db_cleanup cleanup;
    gboolean pressed, closed;
    char error[512];
};
static gboolean main_ready(gint fd, GIOCondition condition, gpointer context) {
    db_window *window = context;
    // CoreFoundation acknowledges this eventfd before draining the main queue. The callback
    // itself does not read it: leaving it signalled starves GTK's lower-priority frame sources.
    uint64_t value;
    ssize_t count;
    do { count = read(fd, &value, sizeof(value)); } while (count < 0 && errno == EINTR);
    if (count < 0 && errno == EAGAIN && !(condition & (G_IO_ERR | G_IO_HUP)))
        return G_SOURCE_CONTINUE;
    if (count != (ssize_t)sizeof(value)) {
        g_strlcpy(window->error, "Swift main-queue wakeup failed", sizeof(window->error));
        db_window_close(window);
        return G_SOURCE_CONTINUE;
    }
    window->drain_dispatch(NULL);
    return G_SOURCE_CONTINUE;
}
static gboolean draw(GtkGLArea *area, GdkGLContext *gl, gpointer context) {
    (void)gl;
    db_window *window = context;
    GError *error = gtk_gl_area_get_error(area);
    if (error) {
        g_strlcpy(window->error, error->message, sizeof(window->error));
        db_window_close(window);
        return TRUE;
    }
    window->draw(window->context, gtk_widget_get_width(GTK_WIDGET(area)),
                 gtk_widget_get_height(GTK_WIDGET(area)), gtk_widget_get_scale_factor(GTK_WIDGET(area)));
    return TRUE;
}
static void realized(GtkGLArea *area, gpointer context) {
    db_window *window = context;
    gtk_gl_area_make_current(area);
    GError *error = gtk_gl_area_get_error(area);
    if (error) {
        g_strlcpy(window->error, error->message, sizeof(window->error));
        db_window_close(window);
    }
}
static void unrealized(GtkGLArea *area, gpointer context) {
    db_window *window = context;
    gtk_gl_area_make_current(area);
    window->cleanup(window->context);
}
static gboolean tick(GtkWidget *widget, GdkFrameClock *clock, gpointer context) {
    (void)clock; (void)context;
    gtk_gl_area_queue_render(GTK_GL_AREA(widget));
    return G_SOURCE_CONTINUE;
}
static gboolean closing(GtkWindow *gtk_window, gpointer context) {
    (void)gtk_window;
    db_window *window = context;
    window->closed = TRUE;
    g_main_loop_quit(window->loop);
    return FALSE;
}
static void pressed(GtkGestureClick *gesture, int count, double x, double y, gpointer context) {
    (void)gesture; (void)count;
    db_window *window = context;
    window->pressed = TRUE;
    gtk_widget_grab_focus(window->area);
    window->event(window->context, 1, x, y);
}
static void released(GtkGestureClick *gesture, int count, double x, double y, gpointer context) {
    (void)gesture; (void)count;
    db_window *window = context;
    window->pressed = FALSE;
    window->event(window->context, 2, x, y);
}
static void cancelled(GtkGesture *gesture, GdkEventSequence *sequence, gpointer context) {
    (void)gesture; (void)sequence;
    db_window *window = context;
    window->pressed = FALSE;
    window->event(window->context, 2, 0, 0);
}
static void motion(GtkEventControllerMotion *controller, double x, double y, gpointer context) {
    (void)controller;
    db_window *window = context;
    if (window->pressed) window->event(window->context, 1, x, y);
}
static void focus_lost(GtkEventControllerFocus *controller, gpointer context) {
    (void)controller;
    db_window *window = context;
    window->pressed = FALSE;
    window->event(window->context, 4, 0, 0);
}
static gboolean key(GtkEventControllerKey *controller, guint keyval, guint keycode,
                    GdkModifierType state, gpointer context) {
    (void)controller; (void)keycode; (void)state;
    db_window *window = context;
    if (keyval == GDK_KEY_Escape) { db_window_close(window); return TRUE; }
    if (keyval == GDK_KEY_space) { window->event(window->context, 3, 0, 0); return TRUE; }
    return FALSE;
}
db_window *db_window_new(void *context, db_draw render, db_event event, db_cleanup cleanup,
                         char *error, size_t size) {
    if (!gtk_init_check()) { snprintf(error, size, "GTK could not open the desktop display"); return NULL; }
    // Swift's CoreFoundation/libdispatch integration ABI. Pin and test it with the toolchain.
    // The Linux handle is a borrowed eventfd. Acknowledge wakeups, but never close the handle.
    int (*main_handle)(void) = dlsym(RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
    void (*drain)(void *) = dlsym(RTLD_DEFAULT, "_dispatch_main_queue_callback_4CF");
    if (!main_handle || !drain) {
        snprintf(error, size, "Swift main-queue integration symbols are unavailable"); return NULL;
    }
    int fd = main_handle();
    if (fd < 0) { snprintf(error, size, "Swift main-queue handle is unavailable"); return NULL; }
    db_window *window = g_new0(db_window, 1);
    window->context = context; window->draw = render; window->event = event; window->cleanup = cleanup;
    window->drain_dispatch = drain;
    window->loop = g_main_loop_new(NULL, FALSE);
    window->window = gtk_window_new();
    g_object_ref(window->window);
    gtk_window_set_title(GTK_WINDOW(window->window), "Driftbox · Linux window experiment");
    gtk_window_set_default_size(GTK_WINDOW(window->window), 900, 600);
    window->area = gtk_gl_area_new();
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_gl_area_set_allowed_apis(GTK_GL_AREA(window->area), GDK_GL_API_GLES);
#else
    gtk_gl_area_set_use_es(GTK_GL_AREA(window->area), TRUE);
#endif
    gtk_gl_area_set_required_version(GTK_GL_AREA(window->area), 3, 0);
    gtk_widget_set_focusable(window->area, TRUE);
    gtk_window_set_child(GTK_WINDOW(window->window), window->area);
    g_signal_connect(window->area, "realize", G_CALLBACK(realized), window);
    g_signal_connect(window->area, "unrealize", G_CALLBACK(unrealized), window);
    g_signal_connect(window->area, "render", G_CALLBACK(draw), window);
    g_signal_connect(window->window, "close-request", G_CALLBACK(closing), window);
    gtk_widget_add_tick_callback(window->area, tick, window, NULL);
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    g_signal_connect(click, "pressed", G_CALLBACK(pressed), window);
    g_signal_connect(click, "released", G_CALLBACK(released), window);
    g_signal_connect(click, "cancel", G_CALLBACK(cancelled), window);
    gtk_widget_add_controller(window->area, GTK_EVENT_CONTROLLER(click));
    GtkEventController *move = gtk_event_controller_motion_new();
    g_signal_connect(move, "motion", G_CALLBACK(motion), window);
    gtk_widget_add_controller(window->area, move);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(focus_lost), window);
    gtk_widget_add_controller(window->area, focus);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key), window);
    gtk_widget_add_controller(window->area, keys);
    window->dispatch_source = g_unix_fd_add(fd, G_IO_IN, main_ready, window);
    return window;
}
void db_window_run(db_window *window) {
    gtk_window_present(GTK_WINDOW(window->window));
    gtk_widget_grab_focus(window->area);
    if (!window->closed) g_main_loop_run(window->loop);
}
void db_window_close(db_window *window) {
    if (!window->closed) gtk_window_close(GTK_WINDOW(window->window));
}
void db_window_free(db_window *window) {
    g_source_remove(window->dispatch_source);
    gtk_window_destroy(GTK_WINDOW(window->window));
    g_object_unref(window->window);
    g_main_loop_unref(window->loop);
    g_free(window);
}
void db_window_title(db_window *window, const char *title) {
    gtk_window_set_title(GTK_WINDOW(window->window), title);
}
void db_window_resize(db_window *window, int width, int height) {
    gtk_window_set_default_size(GTK_WINDOW(window->window), width, height);
}
void db_window_visible(db_window *window, int visible) {
    gtk_widget_set_visible(window->window, visible);
}
const char *db_window_error(db_window *window) { return window->error; }
#endif
