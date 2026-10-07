#ifndef RUNNER_WEB_AUTH_H_
#define RUNNER_WEB_AUTH_H_

#include <flutter_linux/flutter_linux.h>

// Registers the `app.crosschat/webauth` channel: the embedded sign-in window
// for bridge `cookies` login steps (see lib/src/webauth/web_auth.dart).
// WebKitGTK is loaded at runtime, so the app builds and runs without it;
// when it's missing `isAvailable` answers false and the app falls back to
// pasting cookies.
void web_auth_register(FlView* view);

#endif  // RUNNER_WEB_AUTH_H_
