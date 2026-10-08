#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// The names of Immuch360 Desktop on Windows, used by Runner.rc and main.cpp.
// path_provider builds the folders of the app from CompanyName and ProductName
// of the version block (%APPDATA%\<company>\<product> for the support folder,
// which holds the database and the secrets, %LOCALAPPDATA%\<company>\<product>
// for the cache), so they must not change once people have data there.
#define IMMUCH360_COMPANY_NAME "com.aprogsys"
#define IMMUCH360_PRODUCT_NAME "Immuch360 Desktop"
#define IMMUCH360_COMPANY_NAME_W L"com.aprogsys"
#define IMMUCH360_PRODUCT_NAME_W L"Immuch360 Desktop"

// The window class of the main window, unique to the app, so that a second
// start finds the first one rather than another Flutter program.
#define IMMUCH360_WINDOW_CLASS_W L"IMMUCH360_DESKTOP_WINDOW"

// One running copy per user session (see main.cpp).
#define IMMUCH360_INSTANCE_MUTEX_W L"Local\\Immuch360Desktop.SingleInstance"

// WM_COPYDATA tag of the command line a second start hands to the first.
#define IMMUCH360_HAND_OVER_TAG 0x494D3336

// The method channel that brings those command lines to Dart
// (lib/desktop/window/single_instance.dart).
#define IMMUCH360_INSTANCE_CHANNEL "immuch360/instance"

#endif  // RUNNER_APP_IDENTITY_H_
