// Standalone GTK native-dialog lifetime diagnostic; see docs/LINUX.md.
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_8
#include <gtk/gtk.h>
static gboolean finish(gpointer loop) { g_main_loop_quit(loop); return G_SOURCE_REMOVE; }
int main(void) {
    gtk_init();
    for (int i=0;i<4;i++) {
        GtkWidget *parent=gtk_window_new();
        g_object_ref(parent);
        gtk_widget_realize(parent);
        GtkFileChooserNative *dialog=gtk_file_chooser_native_new("Probe",GTK_WINDOW(parent),
            i==3?GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER:
            i==2?GTK_FILE_CHOOSER_ACTION_SAVE:GTK_FILE_CHOOSER_ACTION_OPEN,NULL,NULL);
        gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog),TRUE);
        gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog),i==1);
        if(i==2) gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog),"Unsaved.driftbox");
        gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
        gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(dialog));
        g_object_unref(dialog);
        gtk_window_destroy(GTK_WINDOW(parent)); g_object_unref(parent);
    }
    GtkWidget *window=gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window),"GTK dialog lifetime diagnostic");
    gtk_window_set_child(GTK_WINDOW(window),gtk_label_new("Waiting for pending GTK events"));
    gtk_window_present(GTK_WINDOW(window));
    GMainLoop *loop=g_main_loop_new(NULL,FALSE);
    g_timeout_add_seconds(3,finish,loop);
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window)); g_main_loop_unref(loop);
    return 0;
}
