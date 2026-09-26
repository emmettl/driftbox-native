// Exercise the real GTK response bridge on a private Xvfb display, without UTM
// input or the Swift renderer. Including the implementation keeps test-only
// dialog inspection out of the public C API.
#include "../Sources/CLinuxUI/Desktop.c"

typedef struct { int calls, answer; } Result;
static void received(void *context, int answer, const char *value) {
    Result *result=context;
    result->calls++; result->answer=answer;
    g_assert_cmpstr(value,==,"");
}
static gboolean idle(gpointer context) { (void)context; return G_SOURCE_CONTINUE; }
static db_desktop *fixture(void) {
    db_desktop *w=g_new0(db_desktop,1);
    w->window=gtk_window_new(); g_object_ref(w->window);
    w->area=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    gtk_window_set_child(GTK_WINDOW(w->window),w->area);
    w->loop=g_main_loop_new(NULL,FALSE);
    w->actions=g_simple_action_group_new();
    w->source=g_timeout_add_seconds(60,idle,NULL);
    gtk_window_present(GTK_WINDOW(w->window));
    return w;
}
static void empty(db_desktop *w) {
    g_assert_null(w->dialog); g_assert_null(w->reply); g_assert_null(w->reply_context);
}
static void question_answers(void) {
    db_desktop *w=fixture();
    const int responses[]={1,2,GTK_RESPONSE_CANCEL,GTK_RESPONSE_DELETE_EVENT};
    const int answers[]={1,2,0,0};
    for (guint i=0;i<G_N_ELEMENTS(responses);i++) {
        Result result={0};
        db_desktop_save_question(w,"Unsaved café",&result,received);
        g_assert_true(GTK_IS_MESSAGE_DIALOG(w->dialog));
        g_assert_true(gtk_window_get_modal(GTK_WINDOW(w->dialog)));
        g_assert_true(gtk_window_get_transient_for(GTK_WINDOW(w->dialog))==GTK_WINDOW(w->window));
        g_assert_cmpint(result.calls,==,0);
        gtk_dialog_response(GTK_DIALOG(w->dialog),responses[i]);
        g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,answers[i]);
        empty(w);
    }
    db_desktop_free(w);
}
static void concurrent_requests(void) {
    db_desktop *w=fixture(); Result first={0}, second={0}, third={0};
    db_desktop_save_question(w,"First",&first,received);
    GObject *dialog=w->dialog;
    db_desktop_save_question(w,"Second",&second,received);
    db_desktop_files(w,0,0,"wav;wave","",&third,received);
    g_assert_true(w->dialog==dialog);
    g_assert_cmpint(first.calls,==,0);
    g_assert_cmpint(second.calls,==,1); g_assert_cmpint(second.answer,==,0);
    g_assert_cmpint(third.calls,==,1); g_assert_cmpint(third.answer,==,0);
    gtk_dialog_response(GTK_DIALOG(dialog),GTK_RESPONSE_CANCEL);
    g_assert_cmpint(first.calls,==,1); empty(w);
    db_desktop_free(w);
}
typedef struct { db_desktop *window; Result question, file; } Chain;
static void save_chosen(void *context,int answer,const char *value) {
    Chain *chain=context;
    received(&chain->question,answer,value);
    empty(chain->window);
    if (answer==1) db_desktop_files(chain->window,1,0,"driftbox","Unsaved.driftbox",&chain->file,received);
}
static void save_then_chooser(void) {
    db_desktop *w=fixture(); Chain chain={.window=w};
    db_desktop_save_question(w,"Unsaved",&chain,save_chosen);
    gtk_dialog_response(GTK_DIALOG(w->dialog),1);
    g_assert_cmpint(chain.question.calls,==,1); g_assert_cmpint(chain.question.answer,==,1);
    g_assert_true(GTK_IS_FILE_CHOOSER_NATIVE(w->dialog));
    g_assert_cmpint(gtk_file_chooser_get_action(GTK_FILE_CHOOSER(w->dialog)),==,GTK_FILE_CHOOSER_ACTION_SAVE);
    char *name=gtk_file_chooser_get_current_name(GTK_FILE_CHOOSER(w->dialog));
    g_assert_cmpstr(name,==,"Unsaved.driftbox"); g_free(name);
    g_assert_cmpint(chain.file.calls,==,0);
    g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_CANCEL);
    g_assert_cmpint(chain.file.calls,==,1); g_assert_cmpint(chain.file.answer,==,0);
    empty(w); db_desktop_free(w);
}
static void open_cancel_and_retry(void) {
    db_desktop *w=fixture();
    for (int multiple=0;multiple<=1;multiple++) {
        Result result={0};
        db_desktop_files(w,0,multiple,"wav;wave","",&result,received);
        g_assert_cmpint(result.calls,==,0);
        GtkFileChooser *chooser=GTK_FILE_CHOOSER(w->dialog);
        g_assert_cmpint(gtk_file_chooser_get_action(chooser),==,GTK_FILE_CHOOSER_ACTION_OPEN);
        g_assert_cmpint(gtk_file_chooser_get_select_multiple(chooser),==,multiple);
        g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_CANCEL);
        g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,0); empty(w);
    }
    db_desktop_free(w);
}
typedef struct { db_desktop *window; Result result; int commands; } Command;
static void new_document(void *context,int id) {
    Command *command=context; g_assert_cmpint(id,==,0); command->commands++;
    db_desktop_save_question(command->window,"Edited song",&command->result,received);
}
static void menu_to_question(void) {
    db_desktop *w=fixture(); Command command={.window=w};
    w->context=&command; w->command=new_document;
    db_desktop_action(w,0,1,0);
    g_action_group_activate_action(G_ACTION_GROUP(w->actions),"c0",NULL);
    g_assert_cmpint(command.commands,==,1);
    g_assert_true(GTK_IS_MESSAGE_DIALOG(w->dialog));
    g_assert_cmpint(command.result.calls,==,0);
    gtk_dialog_response(GTK_DIALOG(w->dialog),2);
    g_assert_cmpint(command.result.calls,==,1); g_assert_cmpint(command.result.answer,==,2);
    empty(w); db_desktop_free(w);
}
static void teardown_cancels(void) {
    for (int file=0;file<=1;file++) {
        db_desktop *w=fixture(); Result result={0};
        if (file) db_desktop_files(w,0,0,"driftbox","",&result,received);
        else db_desktop_save_question(w,"Unsaved",&result,received);
        db_desktop_free(w);
        g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,0);
    }
}
typedef struct { int calls, answer; char *uris; } FileResult;
static void file_received(void *context,int answer,const char *uris) {
    FileResult *result=context;
    result->calls++; result->answer=answer; result->uris=g_strdup(uris);
}
static void wait_for_file(GtkFileChooser *chooser,GFile *expected,gboolean folder) {
    gint64 deadline=g_get_monotonic_time()+10*G_TIME_SPAN_SECOND;
    do {
        while (g_main_context_iteration(NULL,FALSE)) {}
        GFile *actual=folder ? gtk_file_chooser_get_current_folder(chooser) : gtk_file_chooser_get_file(chooser);
        gboolean matches=actual && g_file_equal(actual,expected);
        g_clear_object(&actual);
        if (matches) return;
        g_usleep(1000);
    } while (g_get_monotonic_time()<deadline);
    g_error("File chooser did not load the expected %s",folder?"folder":"file");
}
static void accepted_files_and_folder(void) {
    GError *error=NULL;
    char *directory=g_dir_make_tmp("driftbox-dialog-files-XXXXXX",&error); g_assert_no_error(error);
    char *path=g_build_filename(directory,"café loop\none.wav",NULL);
    g_assert_true(g_file_set_contents(path,"test fixture",-1,&error)); g_assert_no_error(error);
    GFile *file=g_file_new_for_path(path), *folder=g_file_new_for_path(directory);
    char *uri=g_file_get_uri(file);
    db_desktop *w=fixture(); FileResult result={0};
    db_desktop_files(w,0,0,"wav;wave","",&result,file_received);
    g_assert_true(gtk_file_chooser_set_file(GTK_FILE_CHOOSER(w->dialog),file,&error)); g_assert_no_error(error);
    wait_for_file(GTK_FILE_CHOOSER(w->dialog),file,FALSE);
    g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_ACCEPT);
    g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,1);
    g_assert_cmpstr(result.uris,==,uri); g_free(result.uris);
    g_assert_true(g_file_equal(w->folder,folder)); empty(w);
    // The next chooser inherits the accepted folder and returns a new save path.
    result=(FileResult){0};
    db_desktop_files(w,1,0,"driftbox","copy.driftbox",&result,file_received);
    wait_for_file(GTK_FILE_CHOOSER(w->dialog),folder,TRUE);
    GFile *saved=g_file_get_child(folder,"copy.driftbox");
    wait_for_file(GTK_FILE_CHOOSER(w->dialog),saved,FALSE);
    char *save_uri=g_file_get_uri(saved);
    g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_ACCEPT);
    g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,1);
    g_assert_cmpstr(result.uris,==,save_uri); empty(w);
    // The bridge chooses a location; only the document layer writes the song.
    g_assert_false(g_file_query_exists(saved,NULL));
    g_free(result.uris); g_free(save_uri); g_object_unref(saved); db_desktop_free(w);
    g_assert_cmpint(unlink(path),==,0); g_assert_cmpint(rmdir(directory),==,0);
    g_free(uri); g_object_unref(file); g_object_unref(folder); g_free(path); g_free(directory);
}
static void folder_selection(void) {
    db_desktop *w=fixture(); FileResult result={0};
    char *directory=g_dir_make_tmp("driftbox-folder-XXXXXX",NULL);
    GFile *folder=g_file_new_for_path(directory); char *uri=g_file_get_uri(folder);
    db_desktop_folder(w,"Export Stems","Export Here",&result,file_received);
    GtkFileChooser *chooser=GTK_FILE_CHOOSER(w->dialog);
    g_assert_cmpint(gtk_file_chooser_get_action(chooser),==,GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
    g_assert_true(gtk_file_chooser_set_file(chooser,folder,NULL));
    wait_for_file(chooser,folder,FALSE);
    g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_ACCEPT);
    g_assert_cmpint(result.calls,==,1); g_assert_cmpstr(result.uris,==,uri); empty(w);
    g_free(result.uris); result=(FileResult){0};
    db_desktop_folder(w,"Export Stems","Export Here",&result,file_received);
    g_signal_emit_by_name(w->dialog,"response",GTK_RESPONSE_CANCEL);
    g_assert_cmpint(result.calls,==,1); g_assert_cmpint(result.answer,==,0); empty(w);
    g_free(result.uris); db_desktop_free(w);
    g_assert_cmpint(rmdir(directory),==,0); g_free(directory); g_free(uri); g_object_unref(folder);
}
int main(int argc,char **argv) {
    g_test_init(&argc,&argv,NULL);
    // A minimal CI container may lack a session bus; critical GTK errors still fail.
    g_log_set_always_fatal(G_LOG_LEVEL_ERROR|G_LOG_LEVEL_CRITICAL);
    gtk_init();
    g_test_add_func("/dialogs/question-answers",question_answers);
    g_test_add_func("/dialogs/concurrent-requests",concurrent_requests);
    g_test_add_func("/dialogs/save-then-chooser",save_then_chooser);
    g_test_add_func("/dialogs/open-cancel-and-retry",open_cancel_and_retry);
    g_test_add_func("/dialogs/menu-to-question",menu_to_question);
    g_test_add_func("/dialogs/teardown-cancels",teardown_cancels);
    g_test_add_func("/dialogs/accepted-files-and-folder",accepted_files_and_folder);
    g_test_add_func("/dialogs/folder-selection",folder_selection);
    return g_test_run();
}
