#include "clipboard_channel.h"

#include <gtk/gtk.h>

#include <cstring>

namespace {

constexpr char kClipboardChannel[] = "immuch360/clipboard";

enum Target : guint {
  kGnomeCopiedFiles = 0,
  kUriList = 1,
  kPng = 2,
};

// What the clipboard serves for one write, freed when another write or
// another program replaces it
struct Content {
  gchar** uris;
  GBytes* png;
  gint64 generation;
};

// The number of the last write, and whether the app still owns the selection
// with it
gint64 generation = 0;
gboolean owned = FALSE;

void content_free(Content* content) {
  g_strfreev(content->uris);
  if (content->png != nullptr) {
    g_bytes_unref(content->png);
  }
  g_free(content);
}

void get_cb(GtkClipboard* clipboard, GtkSelectionData* selection, guint info,
            gpointer data) {
  auto* content = static_cast<Content*>(data);
  switch (info) {
    case kGnomeCopiedFiles: {
      g_autofree gchar* text = clipboard_gnome_copied_files(content->uris);
      gtk_selection_data_set(
          selection, gdk_atom_intern_static_string("x-special/gnome-copied-files"),
          8, reinterpret_cast<const guchar*>(text),
          static_cast<gint>(strlen(text)));
      break;
    }
    case kUriList:
      gtk_selection_data_set_uris(selection, content->uris);
      break;
    case kPng:
      if (content->png != nullptr) {
        gsize size = 0;
        const auto* bytes =
            static_cast<const guchar*>(g_bytes_get_data(content->png, &size));
        gtk_selection_data_set(selection,
                               gdk_atom_intern_static_string("image/png"), 8,
                               bytes, static_cast<gint>(size));
      }
      break;
    default:
      break;
  }
}

// Called when the selection goes to another write or another program
void clear_cb(GtkClipboard* clipboard, gpointer data) {
  auto* content = static_cast<Content*>(data);
  if (content->generation == generation) {
    owned = FALSE;
  }
  content_free(content);
}

FlMethodResponse* error_response(const gchar* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("clipboard", message, nullptr));
}

FlMethodResponse* write_files(FlValue* arguments) {
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return error_response("no arguments");
  }
  FlValue* paths = fl_value_lookup_string(arguments, "paths");
  if (paths == nullptr || fl_value_get_type(paths) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(paths) == 0) {
    return error_response("no paths");
  }
  const size_t count = fl_value_get_length(paths);
  g_auto(GStrv) uris = g_new0(gchar*, count + 1);
  for (size_t index = 0; index < count; index++) {
    FlValue* path = fl_value_get_list_value(paths, index);
    if (fl_value_get_type(path) != FL_VALUE_TYPE_STRING) {
      return error_response("a path is not text");
    }
    g_autoptr(GError) error = nullptr;
    uris[index] =
        g_filename_to_uri(fl_value_get_string(path), nullptr, &error);
    if (uris[index] == nullptr) {
      return error_response(error != nullptr ? error->message
                                             : "a path is not absolute");
    }
  }

  auto* content = g_new0(Content, 1);
  content->uris = static_cast<gchar**>(g_steal_pointer(&uris));
  FlValue* png = fl_value_lookup_string(arguments, "png");
  if (png != nullptr && fl_value_get_type(png) == FL_VALUE_TYPE_UINT8_LIST &&
      fl_value_get_length(png) > 0) {
    content->png = g_bytes_new(fl_value_get_uint8_list(png),
                               fl_value_get_length(png));
  }
  content->generation = ++generation;

  GtkTargetEntry targets[] = {
      {const_cast<gchar*>("x-special/gnome-copied-files"), 0,
       kGnomeCopiedFiles},
      {const_cast<gchar*>("text/uri-list"), 0, kUriList},
      {const_cast<gchar*>("image/png"), 0, kPng},
  };
  const guint target_count = content->png != nullptr ? 3 : 2;
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  // The previous write of the app is cleared here (clear_cb), with its number
  if (!gtk_clipboard_set_with_data(clipboard, targets, target_count, get_cb,
                                   clear_cb, content)) {
    content_free(content);
    owned = FALSE;
    return error_response("GTK refused the clipboard");
  }
  owned = TRUE;
  g_autoptr(FlValue) token = fl_value_new_int(content->generation);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(token));
}

FlMethodResponse* holds(FlValue* arguments) {
  FlValue* token = arguments != nullptr &&
                           fl_value_get_type(arguments) == FL_VALUE_TYPE_MAP
                       ? fl_value_lookup_string(arguments, "token")
                       : nullptr;
  if (token == nullptr || fl_value_get_type(token) != FL_VALUE_TYPE_INT) {
    return error_response("no token");
  }
  g_autoptr(FlValue) answer =
      fl_value_new_bool(owned && fl_value_get_int(token) == generation);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(answer));
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* arguments = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "writeFiles") == 0) {
    response = write_files(arguments);
  } else if (strcmp(method, "holds") == 0) {
    response = holds(arguments);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("The clipboard channel could not answer: %s", error->message);
  }
}

}  // namespace

gchar* clipboard_gnome_copied_files(const gchar* const* uris) {
  GString* text = g_string_new("copy");
  for (const gchar* const* uri = uris; uri != nullptr && *uri != nullptr;
       uri++) {
    g_string_append_c(text, '\n');
    g_string_append(text, *uri);
  }
  return g_string_free(text, FALSE);
}

FlMethodChannel* clipboard_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kClipboardChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
  return channel;
}
