// Embedded sign-in window on Linux: a GTK window with a WebKitGTK view that
// uses an ephemeral (in-memory, throwaway) web context per sign-in.
// libwebkit2gtk-4.1 (GTK 3, libsoup 3) is dlopen()ed so nothing about it is
// needed at build time and the app still works where it isn't installed.

#include "web_auth.h"

#include <cairo.h>
#include <dlfcn.h>
#include <gtk/gtk.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

typedef struct _WebKitWebView WebKitWebView;
typedef struct _WebKitWebContext WebKitWebContext;
typedef struct _WebKitUserContentManager WebKitUserContentManager;
typedef struct _WebKitUserScript WebKitUserScript;
typedef struct _WebKitSettings WebKitSettings;
typedef struct _WebKitCookieManager WebKitCookieManager;
typedef struct _WebKitWebsiteDataManager WebKitWebsiteDataManager;
typedef struct _WebKitPolicyDecision WebKitPolicyDecision;
typedef struct _WebKitNavigationAction WebKitNavigationAction;
typedef struct _WebKitURIRequest WebKitURIRequest;
typedef struct _WebKitJavascriptResult WebKitJavascriptResult;
typedef struct _JSCValue JSCValue;
typedef struct _SoupCookie SoupCookie;

struct Api {
  GType (*web_view_get_type)();
  WebKitWebContext* (*web_context_new_ephemeral)();
  WebKitWebsiteDataManager* (*web_context_get_website_data_manager)(WebKitWebContext*);
  WebKitCookieManager* (*website_data_manager_get_cookie_manager)(WebKitWebsiteDataManager*);
  WebKitUserContentManager* (*user_content_manager_new)();
  gboolean (*register_script_message_handler)(WebKitUserContentManager*, const char*);
  WebKitUserScript* (*user_script_new)(const char*, int, int, const char* const*, const char* const*);
  void (*add_script)(WebKitUserContentManager*, WebKitUserScript*);
  void (*user_script_unref)(WebKitUserScript*);
  WebKitSettings* (*get_settings)(WebKitWebView*);
  void (*settings_set_user_agent)(WebKitSettings*, const char*);
  const char* (*settings_get_user_agent)(WebKitSettings*);
  void (*settings_set_js_can_open_windows)(WebKitSettings*, gboolean);
  void (*load_uri)(WebKitWebView*, const char*);
  const char* (*get_uri)(WebKitWebView*);
  void (*stop_loading)(WebKitWebView*);
  // Cookies (get_all_cookies is 2.42+; older versions are asked per URI).
  void (*get_all_cookies)(WebKitCookieManager*, GCancellable*, GAsyncReadyCallback, gpointer);
  GList* (*get_all_cookies_finish)(WebKitCookieManager*, GAsyncResult*, GError**);
  void (*get_cookies)(WebKitCookieManager*, const char*, GCancellable*, GAsyncReadyCallback, gpointer);
  GList* (*get_cookies_finish)(WebKitCookieManager*, GAsyncResult*, GError**);
  void (*add_cookie)(WebKitCookieManager*, SoupCookie*, GCancellable*, GAsyncReadyCallback, gpointer);
  gboolean (*add_cookie_finish)(WebKitCookieManager*, GAsyncResult*, GError**);
  // JavaScript (evaluate_javascript is 2.40+, run_javascript before).
  void (*evaluate_javascript)(WebKitWebView*, const char*, gssize, const char*, const char*, GCancellable*,
                              GAsyncReadyCallback, gpointer);
  JSCValue* (*evaluate_javascript_finish)(WebKitWebView*, GAsyncResult*, GError**);
  void (*run_javascript)(WebKitWebView*, const char*, GCancellable*, GAsyncReadyCallback, gpointer);
  WebKitJavascriptResult* (*run_javascript_finish)(WebKitWebView*, GAsyncResult*, GError**);
  JSCValue* (*javascript_result_get_js_value)(WebKitJavascriptResult*);
  void (*javascript_result_unref)(WebKitJavascriptResult*);
  gboolean (*jsc_value_is_string)(JSCValue*);
  gboolean (*jsc_value_is_number)(JSCValue*);
  gboolean (*jsc_value_is_boolean)(JSCValue*);
  char* (*jsc_value_to_string)(JSCValue*);
  double (*jsc_value_to_double)(JSCValue*);
  gboolean (*jsc_value_to_boolean)(JSCValue*);
  // Navigation policy.
  WebKitNavigationAction* (*nav_decision_get_action)(WebKitPolicyDecision*);
  WebKitURIRequest* (*nav_action_get_request)(WebKitNavigationAction*);
  int (*nav_action_get_type)(WebKitNavigationAction*);
  const char* (*uri_request_get_uri)(WebKitURIRequest*);
  void (*policy_use)(WebKitPolicyDecision*);
  void (*policy_ignore)(WebKitPolicyDecision*);
  // Snapshots.
  void (*get_snapshot)(WebKitWebView*, int, int, GCancellable*, GAsyncReadyCallback, gpointer);
  cairo_surface_t* (*get_snapshot_finish)(WebKitWebView*, GAsyncResult*, GError**);
  // libsoup 3.
  const char* (*cookie_get_name)(SoupCookie*);
  const char* (*cookie_get_value)(SoupCookie*);
  const char* (*cookie_get_domain)(SoupCookie*);
  const char* (*cookie_get_path)(SoupCookie*);
  gboolean (*cookie_get_http_only)(SoupCookie*);
  gboolean (*cookie_get_secure)(SoupCookie*);
  SoupCookie* (*cookie_new)(const char*, const char*, const char*, const char*, int);
  void (*cookie_set_secure)(SoupCookie*, gboolean);
  void (*cookie_set_http_only)(SoupCookie*, gboolean);
  void (*cookie_free)(SoupCookie*);
};

Api api;
int api_state = 0;  // 0 = not tried, 1 = loaded, -1 = unavailable

template <typename T>
bool sym(void* lib, const char* name, T* out, bool required = true) {
  *out = reinterpret_cast<T>(dlsym(lib, name));
  if (*out == nullptr && required) g_warning("webauth: %s missing", name);
  return *out != nullptr || !required;
}

bool load_api() {
  if (api_state != 0) return api_state == 1;
  api_state = -1;
  if (getenv("CROSSCHAT_NO_WEBKIT") != nullptr) return false;
  void* wk = dlopen("libwebkit2gtk-4.1.so.0", RTLD_NOW | RTLD_GLOBAL);
  if (wk == nullptr) return false;
  void* soup = dlopen("libsoup-3.0.so.0", RTLD_NOW | RTLD_GLOBAL);
  void* jsc = dlopen("libjavascriptcoregtk-4.1.so.0", RTLD_NOW | RTLD_GLOBAL);
  if (soup == nullptr || jsc == nullptr) return false;
  bool ok = true;
  ok &= sym(wk, "webkit_web_view_get_type", &api.web_view_get_type);
  ok &= sym(wk, "webkit_web_context_new_ephemeral", &api.web_context_new_ephemeral);
  ok &= sym(wk, "webkit_web_context_get_website_data_manager", &api.web_context_get_website_data_manager);
  ok &= sym(wk, "webkit_website_data_manager_get_cookie_manager", &api.website_data_manager_get_cookie_manager);
  ok &= sym(wk, "webkit_user_content_manager_new", &api.user_content_manager_new);
  ok &= sym(wk, "webkit_user_content_manager_register_script_message_handler", &api.register_script_message_handler);
  ok &= sym(wk, "webkit_user_script_new", &api.user_script_new);
  ok &= sym(wk, "webkit_user_content_manager_add_script", &api.add_script);
  ok &= sym(wk, "webkit_user_script_unref", &api.user_script_unref);
  ok &= sym(wk, "webkit_web_view_get_settings", &api.get_settings);
  ok &= sym(wk, "webkit_settings_set_user_agent", &api.settings_set_user_agent);
  ok &= sym(wk, "webkit_settings_get_user_agent", &api.settings_get_user_agent);
  ok &= sym(wk, "webkit_settings_set_javascript_can_open_windows_automatically", &api.settings_set_js_can_open_windows);
  ok &= sym(wk, "webkit_web_view_load_uri", &api.load_uri);
  ok &= sym(wk, "webkit_web_view_get_uri", &api.get_uri);
  ok &= sym(wk, "webkit_web_view_stop_loading", &api.stop_loading);
  sym(wk, "webkit_cookie_manager_get_all_cookies", &api.get_all_cookies, false);
  sym(wk, "webkit_cookie_manager_get_all_cookies_finish", &api.get_all_cookies_finish, false);
  ok &= sym(wk, "webkit_cookie_manager_get_cookies", &api.get_cookies);
  ok &= sym(wk, "webkit_cookie_manager_get_cookies_finish", &api.get_cookies_finish);
  ok &= sym(wk, "webkit_cookie_manager_add_cookie", &api.add_cookie);
  ok &= sym(wk, "webkit_cookie_manager_add_cookie_finish", &api.add_cookie_finish);
  sym(wk, "webkit_web_view_evaluate_javascript", &api.evaluate_javascript, false);
  sym(wk, "webkit_web_view_evaluate_javascript_finish", &api.evaluate_javascript_finish, false);
  sym(wk, "webkit_web_view_run_javascript", &api.run_javascript, false);
  sym(wk, "webkit_web_view_run_javascript_finish", &api.run_javascript_finish, false);
  ok &= sym(wk, "webkit_javascript_result_get_js_value", &api.javascript_result_get_js_value);
  sym(wk, "webkit_javascript_result_unref", &api.javascript_result_unref, false);
  ok &= sym(jsc, "jsc_value_is_string", &api.jsc_value_is_string);
  ok &= sym(jsc, "jsc_value_is_number", &api.jsc_value_is_number);
  ok &= sym(jsc, "jsc_value_is_boolean", &api.jsc_value_is_boolean);
  ok &= sym(jsc, "jsc_value_to_string", &api.jsc_value_to_string);
  ok &= sym(jsc, "jsc_value_to_double", &api.jsc_value_to_double);
  ok &= sym(jsc, "jsc_value_to_boolean", &api.jsc_value_to_boolean);
  ok &= sym(wk, "webkit_navigation_policy_decision_get_navigation_action", &api.nav_decision_get_action);
  ok &= sym(wk, "webkit_navigation_action_get_request", &api.nav_action_get_request);
  ok &= sym(wk, "webkit_navigation_action_get_navigation_type", &api.nav_action_get_type);
  ok &= sym(wk, "webkit_uri_request_get_uri", &api.uri_request_get_uri);
  ok &= sym(wk, "webkit_policy_decision_use", &api.policy_use);
  ok &= sym(wk, "webkit_policy_decision_ignore", &api.policy_ignore);
  ok &= sym(wk, "webkit_web_view_get_snapshot", &api.get_snapshot);
  ok &= sym(wk, "webkit_web_view_get_snapshot_finish", &api.get_snapshot_finish);
  ok &= sym(soup, "soup_cookie_get_name", &api.cookie_get_name);
  ok &= sym(soup, "soup_cookie_get_value", &api.cookie_get_value);
  ok &= sym(soup, "soup_cookie_get_domain", &api.cookie_get_domain);
  ok &= sym(soup, "soup_cookie_get_path", &api.cookie_get_path);
  ok &= sym(soup, "soup_cookie_get_http_only", &api.cookie_get_http_only);
  ok &= sym(soup, "soup_cookie_get_secure", &api.cookie_get_secure);
  ok &= sym(soup, "soup_cookie_new", &api.cookie_new);
  ok &= sym(soup, "soup_cookie_set_secure", &api.cookie_set_secure);
  ok &= sym(soup, "soup_cookie_set_http_only", &api.cookie_set_http_only);
  ok &= sym(soup, "soup_cookie_free", &api.cookie_free);
  ok &= (api.evaluate_javascript && api.evaluate_javascript_finish) || (api.run_javascript && api.run_javascript_finish);
  if (!ok) return false;
  api_state = 1;
  return true;
}

struct State {
  FlMethodChannel* channel = nullptr;
  GtkWindow* parent = nullptr;
  GtkWidget* window = nullptr;
  WebKitWebView* view = nullptr;
  WebKitWebContext* context = nullptr;
  WebKitUserContentManager* content = nullptr;
  std::vector<std::string> allowed;
  bool closing = false;
  // Increments per window so late callbacks from a closed one are ignored.
  unsigned generation = 0;
};

State state;

void send_event(FlValue* event) {
  fl_method_channel_invoke_method(state.channel, "event", event, nullptr, nullptr, nullptr);
  fl_value_unref(event);
}

FlValue* event(const char* type) {
  FlValue* e = fl_value_new_map();
  fl_value_set_string_take(e, "type", fl_value_new_string(type));
  return e;
}

const char* arg_string(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* v = fl_value_lookup_string(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING ? fl_value_get_string(v) : nullptr;
}

std::vector<std::string> arg_strings(FlValue* args, const char* key) {
  std::vector<std::string> out;
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return out;
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_LIST) return out;
  for (size_t i = 0; i < fl_value_get_length(v); i++) {
    FlValue* s = fl_value_get_list_value(v, i);
    if (fl_value_get_type(s) == FL_VALUE_TYPE_STRING) out.emplace_back(fl_value_get_string(s));
  }
  return out;
}

std::string strip_dots(std::string s) {
  while (!s.empty() && s[0] == '.') s.erase(0, 1);
  for (auto& c : s) c = g_ascii_tolower(c);
  return s;
}

bool ends_with_label(const std::string& host, const std::string& domain) {
  return host == domain ||
         (host.size() > domain.size() && host.compare(host.size() - domain.size(), domain.size(), domain) == 0 &&
          host[host.size() - domain.size() - 1] == '.');
}

std::string uri_scheme(const char* uri) {
  g_autofree char* s = g_uri_parse_scheme(uri);
  if (s == nullptr) return "";
  g_autofree char* lower = g_ascii_strdown(s, -1);
  return lower;
}

bool is_allowed(const char* uri) {
  if (state.allowed.empty()) return true;
  g_autoptr(GUri) u = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
  if (u == nullptr || g_uri_get_host(u) == nullptr) return false;
  std::string host = strip_dots(g_uri_get_host(u));
  for (const auto& d : state.allowed) {
    if (ends_with_label(host, d)) return true;
  }
  return false;
}

void teardown() {
  state.generation++;
  if (state.view != nullptr) api.stop_loading(state.view);
  // Dropping the ephemeral context discards every cookie and cache entry.
  g_clear_object(&state.content);
  g_clear_object(&state.context);
  state.view = nullptr;
  state.window = nullptr;
  state.allowed.clear();
}

void close_window() {
  if (state.window == nullptr) return;
  state.closing = true;
  gtk_widget_destroy(state.window);
  state.closing = false;
}

void on_destroy(GtkWidget* w, gpointer) {
  if (w != state.window) return;
  bool by_user = !state.closing;
  teardown();
  if (by_user) send_event(event("closed"));
}

void on_uri(GObject*, GParamSpec*, gpointer) {
  if (state.view == nullptr) return;
  const char* uri = api.get_uri(state.view);
  FlValue* e = event("url");
  fl_value_set_string_take(e, "url", fl_value_new_string(uri ? uri : ""));
  send_event(e);
}

void on_load_changed(WebKitWebView* view, int load_event, gpointer) {
  if (load_event != 3 /* WEBKIT_LOAD_FINISHED */ || view != state.view) return;
  const char* uri = api.get_uri(view);
  FlValue* e = event("loaded");
  fl_value_set_string_take(e, "url", fl_value_new_string(uri ? uri : ""));
  send_event(e);
}

gboolean on_decide_policy(WebKitWebView* view, WebKitPolicyDecision* decision, int type, gpointer) {
  if (type != 0 && type != 1) return FALSE;  // responses: default handling
  WebKitNavigationAction* action = api.nav_decision_get_action(decision);
  const char* uri = api.uri_request_get_uri(api.nav_action_get_request(action));
  std::string scheme = uri ? uri_scheme(uri) : "";
  bool web = scheme == "http" || scheme == "https";
  if (!web && scheme != "about" && scheme != "blob" && scheme != "data") {
    api.policy_ignore(decision);  // app hand-offs such as slack://
    return TRUE;
  }
  if (type == 1) {
    // Pop-ups load in the same window.
    api.policy_ignore(decision);
    if (web && is_allowed(uri)) api.load_uri(view, uri);
    return TRUE;
  }
  if (web && api.nav_action_get_type(action) == 0 /* LINK_CLICKED */ && !is_allowed(uri)) {
    api.policy_ignore(decision);
    return TRUE;
  }
  api.policy_use(decision);
  return TRUE;
}

void deliver_message(JSCValue* value) {
  if (value == nullptr || !api.jsc_value_is_string(value)) return;
  g_autofree char* s = api.jsc_value_to_string(value);
  FlValue* e = event("message");
  fl_value_set_string_take(e, "data", fl_value_new_string(s));
  send_event(e);
}

// In the 4.1 API the signal passes a WebKitJavascriptResult (only the GTK 4
// "6.0" API passes a JSCValue directly).
void on_script_message(WebKitUserContentManager*, WebKitJavascriptResult* result, gpointer) {
  deliver_message(api.javascript_result_get_js_value(result));
}

FlValue* jsc_to_fl(JSCValue* v) {
  if (v == nullptr) return fl_value_new_null();
  if (api.jsc_value_is_string(v)) {
    g_autofree char* s = api.jsc_value_to_string(v);
    return fl_value_new_string(s);
  }
  if (api.jsc_value_is_number(v)) return fl_value_new_float(api.jsc_value_to_double(v));
  if (api.jsc_value_is_boolean(v)) return fl_value_new_bool(api.jsc_value_to_boolean(v));
  return fl_value_new_null();
}

struct Pending {
  FlMethodCall* call;
  unsigned generation;
  int remaining = 0;
  FlValue* list = nullptr;
  std::vector<std::string> wanted;
};

void respond(FlMethodCall* call, FlValue* value) {
  fl_method_call_respond_success(call, value, nullptr);
  if (value != nullptr) fl_value_unref(value);
}

void on_evaluated(GObject* source, GAsyncResult* res, gpointer data) {
  auto* p = static_cast<Pending*>(data);
  FlValue* out = nullptr;
  if (api.evaluate_javascript_finish != nullptr) {
    JSCValue* v = api.evaluate_javascript_finish(reinterpret_cast<WebKitWebView*>(source), res, nullptr);
    out = jsc_to_fl(v);
    if (v != nullptr) g_object_unref(v);
  } else {
    WebKitJavascriptResult* r = api.run_javascript_finish(reinterpret_cast<WebKitWebView*>(source), res, nullptr);
    out = jsc_to_fl(r ? api.javascript_result_get_js_value(r) : nullptr);
    if (r != nullptr && api.javascript_result_unref != nullptr) api.javascript_result_unref(r);
  }
  respond(p->call, out);
  g_object_unref(p->call);
  delete p;
}

void add_cookies(Pending* p, GList* cookies) {
  for (GList* l = cookies; l != nullptr; l = l->next) {
    auto* c = static_cast<SoupCookie*>(l->data);
    std::string domain = strip_dots(api.cookie_get_domain(c) ? api.cookie_get_domain(c) : "");
    bool related = p->wanted.empty();
    for (const auto& w : p->wanted) related = related || ends_with_label(domain, w) || ends_with_label(w, domain);
    if (related) {
      FlValue* m = fl_value_new_map();
      fl_value_set_string_take(m, "name", fl_value_new_string(api.cookie_get_name(c)));
      fl_value_set_string_take(m, "value", fl_value_new_string(api.cookie_get_value(c)));
      fl_value_set_string_take(m, "domain", fl_value_new_string(api.cookie_get_domain(c)));
      fl_value_set_string_take(m, "path", fl_value_new_string(api.cookie_get_path(c) ? api.cookie_get_path(c) : "/"));
      fl_value_set_string_take(m, "secure", fl_value_new_bool(api.cookie_get_secure(c)));
      fl_value_set_string_take(m, "http_only", fl_value_new_bool(api.cookie_get_http_only(c)));
      fl_value_append_take(p->list, m);
    }
    api.cookie_free(c);
  }
  g_list_free(cookies);
}

void finish_cookies(Pending* p) {
  if (--p->remaining > 0) return;
  respond(p->call, p->list);
  g_object_unref(p->call);
  delete p;
}

void on_all_cookies(GObject* source, GAsyncResult* res, gpointer data) {
  auto* p = static_cast<Pending*>(data);
  add_cookies(p, api.get_all_cookies_finish(reinterpret_cast<WebKitCookieManager*>(source), res, nullptr));
  finish_cookies(p);
}

void on_uri_cookies(GObject* source, GAsyncResult* res, gpointer data) {
  auto* p = static_cast<Pending*>(data);
  add_cookies(p, api.get_cookies_finish(reinterpret_cast<WebKitCookieManager*>(source), res, nullptr));
  finish_cookies(p);
}

void on_snapshot(GObject* source, GAsyncResult* res, gpointer data) {
  auto* p = static_cast<Pending*>(data);
  cairo_surface_t* s = api.get_snapshot_finish(reinterpret_cast<WebKitWebView*>(source), res, nullptr);
  const char* path = static_cast<const char*>(g_object_get_data(G_OBJECT(p->call), "path"));
  bool ok = s != nullptr && path != nullptr && cairo_surface_write_to_png(s, path) == CAIRO_STATUS_SUCCESS;
  if (s != nullptr) cairo_surface_destroy(s);
  respond(p->call, fl_value_new_bool(ok));
  g_object_unref(p->call);
  delete p;
}

WebKitCookieManager* cookie_manager() {
  return api.website_data_manager_get_cookie_manager(api.web_context_get_website_data_manager(state.context));
}

void load_when_ready(int* remaining, unsigned generation, std::string* uri) {
  if (--*remaining > 0) return;
  if (generation == state.generation && state.view != nullptr) api.load_uri(state.view, uri->c_str());
  delete remaining;
  delete uri;
}

struct CookieAdd {
  int* remaining;
  unsigned generation;
  std::string* uri;
};

void on_cookie_added(GObject* source, GAsyncResult* res, gpointer data) {
  auto* a = static_cast<CookieAdd*>(data);
  api.add_cookie_finish(reinterpret_cast<WebKitCookieManager*>(source), res, nullptr);
  load_when_ready(a->remaining, a->generation, a->uri);
  delete a;
}

/// WebKitGTK's own UA ("... (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML,
/// like Gecko) Version/x Safari/605.1.15") already reads as Safari.
void open_window(FlValue* args) {
  close_window();
  const char* url = arg_string(args, "url");
  if (url == nullptr) {
    FlValue* e = event("error");
    fl_value_set_string_take(e, "message", fl_value_new_string("invalid sign-in URL"));
    send_event(e);
    return;
  }
  state.allowed.clear();
  for (const auto& d : arg_strings(args, "allowedDomains")) state.allowed.push_back(strip_dots(d));

  state.context = api.web_context_new_ephemeral();
  state.content = api.user_content_manager_new();
  g_signal_connect(state.content, "script-message-received::crosschat", G_CALLBACK(on_script_message), nullptr);
  api.register_script_message_handler(state.content, "crosschat");
  const char* script = arg_string(args, "documentStartScript");
  if (script != nullptr && *script) {
    // WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES = 0, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START = 0
    WebKitUserScript* us = api.user_script_new(script, 0, 0, nullptr, nullptr);
    api.add_script(state.content, us);
    api.user_script_unref(us);
  }
  GtkWidget* view = GTK_WIDGET(
      g_object_new(api.web_view_get_type(), "web-context", state.context, "user-content-manager", state.content, nullptr));
  state.view = reinterpret_cast<WebKitWebView*>(view);
  WebKitSettings* settings = api.get_settings(state.view);
  const char* ua = arg_string(args, "userAgent");
  if (ua != nullptr && *ua) api.settings_set_user_agent(settings, ua);
  api.settings_set_js_can_open_windows(settings, FALSE);
  g_signal_connect(view, "notify::uri", G_CALLBACK(on_uri), nullptr);
  g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), nullptr);
  g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), nullptr);

  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  const char* title = arg_string(args, "title");
  gtk_window_set_title(GTK_WINDOW(window), title ? title : "Sign in");
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 720);
  if (state.parent != nullptr) {
    gtk_window_set_transient_for(GTK_WINDOW(window), state.parent);
    gtk_window_set_position(GTK_WINDOW(window), GTK_WIN_POS_CENTER_ON_PARENT);
  }
  gtk_container_add(GTK_CONTAINER(window), view);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), nullptr);
  state.window = window;
  state.generation++;

  // Initial cookies first, then the page.
  FlValue* initial = args ? fl_value_lookup_string(args, "initialCookies") : nullptr;
  auto* remaining = new int(1);
  auto* uri = new std::string(url);
  if (initial != nullptr && fl_value_get_type(initial) == FL_VALUE_TYPE_LIST) {
    for (size_t i = 0; i < fl_value_get_length(initial); i++) {
      FlValue* c = fl_value_get_list_value(initial, i);
      const char* name = arg_string(c, "name");
      const char* value = arg_string(c, "value");
      if (name == nullptr || value == nullptr) continue;
      const char* domain = arg_string(c, "domain");
      const char* path = arg_string(c, "path");
      g_autoptr(GUri) u = g_uri_parse(url, G_URI_FLAGS_NONE, nullptr);
      SoupCookie* sc = api.cookie_new(name, value, domain ? domain : (u ? g_uri_get_host(u) : ""), path ? path : "/", -1);
      FlValue* secure = fl_value_lookup_string(c, "secure");
      FlValue* http_only = fl_value_lookup_string(c, "http_only");
      if (secure && fl_value_get_type(secure) == FL_VALUE_TYPE_BOOL) api.cookie_set_secure(sc, fl_value_get_bool(secure));
      if (http_only && fl_value_get_type(http_only) == FL_VALUE_TYPE_BOOL)
        api.cookie_set_http_only(sc, fl_value_get_bool(http_only));
      ++*remaining;
      api.add_cookie(cookie_manager(), sc, nullptr, on_cookie_added, new CookieAdd{remaining, state.generation, uri});
      api.cookie_free(sc);
    }
  }
  load_when_ready(remaining, state.generation, uri);

  FlValue* hidden = args ? fl_value_lookup_string(args, "hidden") : nullptr;
  if (hidden == nullptr || fl_value_get_type(hidden) != FL_VALUE_TYPE_BOOL || !fl_value_get_bool(hidden)) {
    gtk_widget_show_all(window);
    gtk_window_present(GTK_WINDOW(window));
  } else {
    gtk_widget_show(view);
  }
}

void handle(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const char* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (strcmp(method, "isAvailable") == 0) {
    respond(call, fl_value_new_bool(load_api()));
    return;
  }
  if (!load_api()) {
    fl_method_call_respond_error(call, "unavailable", "WebKitGTK 4.1 is not installed", nullptr, nullptr);
    return;
  }
  if (strcmp(method, "open") == 0) {
    open_window(args);
    respond(call, nullptr);
  } else if (strcmp(method, "close") == 0) {
    close_window();
    respond(call, nullptr);
  } else if (strcmp(method, "getCookies") == 0) {
    if (state.context == nullptr) {
      respond(call, fl_value_new_list());
      return;
    }
    auto* p = new Pending{FL_METHOD_CALL(g_object_ref(call)), state.generation};
    p->list = fl_value_new_list();
    for (const auto& d : arg_strings(args, "domains")) p->wanted.push_back(strip_dots(d));
    if (api.get_all_cookies != nullptr && api.get_all_cookies_finish != nullptr) {
      p->remaining = 1;
      api.get_all_cookies(cookie_manager(), nullptr, on_all_cookies, p);
    } else if (p->wanted.empty()) {
      respond(call, p->list);
      g_object_unref(p->call);
      delete p;
    } else {
      // Older WebKitGTK: ask per site (includes HttpOnly cookies).
      p->remaining = static_cast<int>(p->wanted.size());
      std::vector<std::string> wanted = p->wanted;
      for (const auto& d : wanted) {
        std::string u = "https://" + d + "/";
        api.get_cookies(cookie_manager(), u.c_str(), nullptr, on_uri_cookies, p);
      }
    }
  } else if (strcmp(method, "evaluate") == 0) {
    const char* script = arg_string(args, "script");
    if (state.view == nullptr || script == nullptr) {
      respond(call, nullptr);
      return;
    }
    auto* p = new Pending{FL_METHOD_CALL(g_object_ref(call)), state.generation};
    if (api.evaluate_javascript != nullptr) {
      api.evaluate_javascript(state.view, script, -1, nullptr, nullptr, nullptr, on_evaluated, p);
    } else {
      api.run_javascript(state.view, script, nullptr, on_evaluated, p);
    }
  } else if (strcmp(method, "snapshot") == 0) {
    const char* path = arg_string(args, "path");
    if (state.view == nullptr || path == nullptr) {
      respond(call, fl_value_new_bool(false));
      return;
    }
    auto* p = new Pending{FL_METHOD_CALL(g_object_ref(call)), state.generation};
    g_object_set_data_full(G_OBJECT(p->call), "path", g_strdup(path), g_free);
    // WEBKIT_SNAPSHOT_REGION_VISIBLE = 0, WEBKIT_SNAPSHOT_OPTIONS_NONE = 0
    api.get_snapshot(state.view, 0, 0, nullptr, on_snapshot, p);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

}  // namespace

void web_auth_register(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  state.channel = fl_method_channel_new(messenger, "app.crosschat/webauth", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(state.channel, handle, nullptr, nullptr);
  GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(view));
  state.parent = GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : nullptr;
}
