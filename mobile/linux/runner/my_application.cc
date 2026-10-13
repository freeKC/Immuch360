#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The window of the app once activated, null before and after it
  GtkWindow* window;
  // Brings to Dart the files of later starts and of drops on the window
  // (lib/desktop/window/single_instance.dart)
  FlMethodChannel* instance_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The method channel of the files to open, as on Windows (app_identity.h).
static constexpr char kInstanceChannel[] = "immuch360/instance";

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Hands [paths], a list of strings, to Dart as a later start's files.
static void open_paths(MyApplication* self, FlValue* paths) {
  if (self->instance_channel == nullptr || fl_value_get_length(paths) == 0) {
    return;
  }
  fl_method_channel_invoke_method(self->instance_channel, "openFiles", paths,
                                  nullptr, nullptr, nullptr);
}

// The files and folders dropped on the window, given as URIs.
static void drag_data_received_cb(GtkWidget* widget, GdkDragContext* context,
                                  gint x, gint y, GtkSelectionData* data,
                                  guint info, guint time,
                                  MyApplication* self) {
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  g_autoptr(FlValue) paths = fl_value_new_list();
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; uri++) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr) {
      fl_value_append_take(paths, fl_value_new_string(path));
    }
  }
  open_paths(self, paths);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // A later start without files: the window that runs comes to the front
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Immuch360 Desktop");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Immuch360 Desktop");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->instance_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kInstanceChannel, FL_METHOD_CODEC(codec));

  // Files dropped anywhere on the window: GTK hands a drop on the Flutter view,
  // which takes none itself, to the window
  static const GtkTargetEntry kDropTargets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0}};
  gtk_drag_dest_set(GTK_WIDGET(window), GTK_DEST_DEFAULT_ALL, kDropTargets,
                    G_N_ELEMENTS(kDropTargets), GDK_ACTION_COPY);
  g_signal_connect(window, "drag-data-received",
                   G_CALLBACK(drag_data_received_cb), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open: the files of a later start, which the
// session bus brought from it (my_application_local_command_line).
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window == nullptr) {
    g_application_activate(application);
  }
  g_autoptr(FlValue) paths = fl_value_new_list();
  for (gint i = 0; i < n_files; i++) {
    g_autofree gchar* path = g_file_get_path(files[i]);
    if (path != nullptr) {
      fl_value_append_take(paths, fl_value_new_string(path));
    }
  }
  open_paths(self, paths);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
  }
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // One copy of the app runs per user, with one database: a later start hands
  // its files to the running one, over the session bus, and quits. Without a
  // session bus every start runs on its own.
  if (g_application_get_is_remote(application)) {
    g_autoptr(GPtrArray) files = g_ptr_array_new_with_free_func(g_object_unref);
    for (gchar** argument = *arguments + 1;
         argument != nullptr && *argument != nullptr; argument++) {
      if ((*argument)[0] != '\0' && (*argument)[0] != '-') {
        g_ptr_array_add(files, g_file_new_for_commandline_arg(*argument));
      }
    }
    if (files->len > 0) {
      g_application_open(application,
                         reinterpret_cast<GFile**>(files->pdata),
                         static_cast<gint>(files->len), "");
    } else {
      g_application_activate(application);
    }
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->instance_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // A debug build (flutter run) runs next to the app in daily use rather than
  // handing its files over and quitting, as on Windows (app_identity.h)
#ifdef NDEBUG
  const GApplicationFlags flags = G_APPLICATION_HANDLES_OPEN;
#else
  const GApplicationFlags flags = G_APPLICATION_NON_UNIQUE;
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
