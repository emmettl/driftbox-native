// Standalone GTK popup diagnostic; see docs/LINUX.md for reproduction steps.
#include <gtk/gtk.h>

static gboolean close_window(GtkWindow *window, gpointer context) {
    (void)window;
    g_main_loop_quit(context);
    return TRUE;
}

int main(void) {
    if (!gtk_init_check()) return 1;
    GtkWidget *window = gtk_window_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_window_set_title(GTK_WINDOW(window), "GTK popup diagnostic");
    gtk_window_set_default_size(GTK_WINDOW(window), 600, 300);
    gtk_window_set_child(GTK_WINDOW(window), box);

    GSimpleActionGroup *actions = g_simple_action_group_new();
    GSimpleAction *action = g_simple_action_new("test", NULL);
    g_action_map_add_action(G_ACTION_MAP(actions), G_ACTION(action));
    gtk_widget_insert_action_group(window, "win", G_ACTION_GROUP(actions));
    g_object_unref(action);
    g_object_unref(actions);

    GMenu *root = g_menu_new();
    GMenu *child = g_menu_new();
    g_menu_append(child, "Test item", "win.test");
    g_menu_append_submenu(root, "File", G_MENU_MODEL(child));
    g_menu_append_submenu(root, "Audio", G_MENU_MODEL(child));
    g_menu_append_submenu(root, "MIDI", G_MENU_MODEL(child));
    gtk_box_append(GTK_BOX(box), gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(root)));
    g_object_unref(child);
    g_object_unref(root);

    GtkWidget *entry = gtk_entry_new();
    gtk_box_append(GTK_BOX(box), entry);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_signal_connect(window, "close-request", G_CALLBACK(close_window), loop);
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(entry);
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window));
    g_main_loop_unref(loop);
    return 0;
}
