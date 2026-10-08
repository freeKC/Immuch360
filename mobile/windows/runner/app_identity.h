#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// The names of Immuch360 Desktop on Windows, used by Runner.rc and main.cpp.
// path_provider builds the folders of the app from CompanyName and ProductName
// of the version block (%APPDATA%\<company>\<product> for the support folder,
// which holds the database and the secrets, %LOCALAPPDATA%\<company>\<product>
// for the cache), so they must not change once people have data there.
//
// A debug build (flutter run, the integration tests) is a program of its own:
// another profile, so that it never opens the database and the secrets of the
// copy in daily use, and another window class and instance mutex, so that it
// starts while that copy runs instead of handing its command line over and
// quitting. Profile and release builds are the app itself.
#define IMMUCH360_COMPANY_NAME "com.aprogsys"
#define IMMUCH360_COMPANY_NAME_W L"com.aprogsys"
#ifdef _DEBUG
#define IMMUCH360_PRODUCT_NAME "Immuch360 Desktop Debug"
#define IMMUCH360_PRODUCT_NAME_W L"Immuch360 Desktop Debug"
#else
#define IMMUCH360_PRODUCT_NAME "Immuch360 Desktop"
#define IMMUCH360_PRODUCT_NAME_W L"Immuch360 Desktop"
#endif

// The window class of the main window, unique to the app, so that a second
// start finds the first one rather than another Flutter program.
#ifdef _DEBUG
#define IMMUCH360_WINDOW_CLASS_W L"IMMUCH360_DESKTOP_DEBUG_WINDOW"
#else
#define IMMUCH360_WINDOW_CLASS_W L"IMMUCH360_DESKTOP_WINDOW"
#endif

// One running copy per user session (see main.cpp).
#ifdef _DEBUG
#define IMMUCH360_INSTANCE_MUTEX_W L"Local\\Immuch360DesktopDebug.SingleInstance"
#else
#define IMMUCH360_INSTANCE_MUTEX_W L"Local\\Immuch360Desktop.SingleInstance"
#endif

// WM_COPYDATA tag of the command line a second start hands to the first.
#define IMMUCH360_HAND_OVER_TAG 0x494D3336

// The method channel that brings those command lines to Dart
// (lib/desktop/window/single_instance.dart).
#define IMMUCH360_INSTANCE_CHANNEL "immuch360/instance"

#endif  // RUNNER_APP_IDENTITY_H_
