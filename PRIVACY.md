# Privacy policy

Immuch360 is a free and open source fork of the Immich mobile app, for phones and tablets, Android TV and Google TV, the Meta Quest headsets (Quest 2, Quest Pro, Quest 3 and Quest 3S) and Windows computers, with early previews for Linux and macOS. It shows the photos and videos of the device itself, of the network shares, media servers and cameras you add, and of an Immich server that you choose and control. This policy describes what the app does with your data.

## What the app does with your data

- **Nothing goes to the developer.** The app has no advertising, no analytics and no crash reporting service run by the developer. Nothing is sent to the developer of Immuch360.
- **With a server.** The app talks to the Immich server address you enter at login, and to the map tile service that server is configured to use when you open the map (by default the tile service of the Immich project). Your photos, videos, albums, account and settings are stored on that server and on your device.
- **Backup.** With backup enabled, the app uploads the photos and videos you select from your device to your server. Backup is off until you turn it on.
- **Without a server.** "Use without a server" opens the app on the photos and videos of the device, with no account. No server is contacted in this mode. The app uses the network only for the shares you open and for the phone share, if you turn it on.
- **Network shares.** You can add SMB, WebDAV and DLNA shares, such as a NAS, a computer or a media server. The app plays their files live, through a bridge inside the app that only listens on the device itself (127.0.0.1). The files are not copied to the device. The list of shares and their passwords stay on the device.
- **Plex media servers.** When you add a Plex server, the app talks only to the server address you enter, with the token you give it, and reads its libraries live. The token stays on the device, in the secure storage of the system, and is deleted when you remove the server.
- **Tapo cameras.** When you add a Tapo camera, the app talks to the camera on your network with the camera account you give it: the live view is read as a video stream from the camera, and the recordings of its memory card are listed and played from the camera. The camera account password stays on the device, in the secure storage of the system. The app contacts no cloud service of the camera maker. A recording goes to your Immich server only when you ask the app to send it.
- **Upload from a share.** When you are connected to a server, you can pick files of a share and send them to your Immich server. The app streams them from the share to the server, without a copy on the device. It only does so when you ask.
- **Share this phone on the network.** When you turn it on, the phone serves its photos and videos, read only, to the devices of your local network that give the user name and password the app generated, such as your headset. It is off at every start of the app. It stops with its switch, with Stop, after an hour without any request, and when the app is closed. On iPhone and iPad it pauses while the app is in the background.
- **A TV.** On Android TV and Google TV the app works as on a phone, with the remote; it stores the same data on the TV.
- **Sign in with your phone.** A TV, a headset or a computer can be signed in from a phone that is signed in to your server. While its sign-in page shows a code, the screen listens on your home network, on its private address only. The phone reads the code with its camera, or as you type it, asks your server for a new session for that screen, and sends it to the screen encrypted with a key made from the code; your password is not sent. The screen gives its name to your server as the name of that session, which your server lists among your devices. Without the app on the phone, a page served by the screen, in the browser of the phone, sends your email and password to the screen, encrypted the same way; the screen uses them once to sign in and does not keep them.
- **DJI drones and remote controllers (Android, experimental).** The DJI drone page reads only the drone, controller or card folder you pick, and sends the files you choose to your Immich server. The DJI link page reads a DJI remote controller plugged into the device, and writes nothing to it but a one byte check each second, which carries no command; what it captures stays on the device until you export it to the Download folder. Nothing is sent to DJI or to the developer.
- **A computer.** On Windows (and the Linux and macOS previews) the app shows the photos and videos of the folders you choose, and of the shares, media servers, cameras and server you add. Nothing is read outside the chosen folders. A file opened with the program, or dropped on its window, is read in place. The app's data lives in the application data folders of your user account; on Linux the secrets are kept in the keyring of the session.
- **The Meta Quest headset.** The immersive view downloads a photo from your server to the headset for display and deletes it once decoded. Videos and the files of shares are read as they play. A raw camera photo is stitched into a temporary picture, described below.
- **Reading your files.** To find 360° photos and videos, raw camera files and Apple spatial photos, the app reads the start of the files, on the device, on your server or on a share. Raw camera files are stitched on the device. The results stay on the device.
- **Video decoders.** The decoder checks only read the list of video decoders of the device.
- **Location.** The app can read your location and camera metadata only as embedded in your own photos, to display them; it does not track your location.
- **Logs.** Log lines stay on the device unless you share or copy them yourself.

## Data stored on the device

Everything below stays on the device and is never sent to the developer.

- **Server session**: the server address, your account details, the session token and a copy of the library details the server sends, in the app's database. For the home screen widgets, the server address and the token are also kept where the widgets can read them. Logging out deletes the token and the copy of the library.
- **Index of the device's photos**: the name, type, dates, size and, when the system gives it, the place of each photo and video of the device, with its albums, in the app's database. The app uses it to show them and, with a server, to back them up.
- **Network shares, media servers and cameras**: the name, type, address, port, path and user name of each share, Plex server and camera, in the app's database. Each password and token is kept apart, in the secure storage of the system: the keychain on iPhone and iPad, on Android a storage encrypted with a key held by the Android Keystore, on Windows the data protection of your user account (DPAPI), on Linux the keyring of the session. Removing a share, a server or a camera in the app deletes its password or token.
- **Files sent from a share**: the share, path, size and date of each file you sent to your server, with the id the server gave it, in a file of the app's support folder, one per server and user. It keeps a file from being sent twice.
- **Video thumbnails of shares**: a frame of each video of a share, in the app's cache, 200 MB at most.
- **Phone share**: a random identifier of the install (16 hexadecimal digits) in the app's database, and the generated user name and password in the secure storage of the system. They are made once and kept, so that your headset keeps its saved share. "New password" replaces the password. The number of connected devices and the last file served are kept in memory only, while the share runs.
- **Temporary copies of the phone share**: a file the system does not let the app read in place is copied to the app's cache to be served. On iPhone and iPad this is every photo and the videos that cannot be read in place; on Android, a file the app cannot read by its path, such as one outside a partial access. The copies are deleted when the share stops or pauses, and at its next start if the app was closed first.
- **Results of the device scan**: for each photo or video the scan read, whether it is 360°, VR180 or a raw camera file, and when it was read, in the app's database, 2,000 entries at most. The scan only reads the files whose shape or name hints at 360°. It runs when you use the app without a server and when you open the 360° list.
- **Lens calibrations**: the lens calibration of each Insta360 camera met in a raw file, with the serial number and model of the camera, in a small file of the app's support folder. A file without its own calibration then uses the one of the same camera.
- **Stitched pictures (headset)**: a raw photo opened in the immersive view is stitched into a PNG picture in the app's cache. The four most recent are kept and older ones are deleted. The system may also empty the cache at any time.
- **Spatial photos**: for each photo read, whether it is an Apple spatial photo and the details of its two views, by its id on your server or on the device, in the app's database, 2,000 entries at most. A photo is read once.
- **Screens signed in by this phone**: the name, kind, system, date and session id of each TV, headset or computer the phone signed in, in the app's database, to list them and sign them out; never their session token. On such a screen: the name it was given and the name of the phone that signed it in.
- **DJI link captures**: the bytes a DJI remote controller sent, kept in memory while the page captures; an export writes them to `Download/Immuch360/dji-link`, with a header that holds the serial number of the remote and may hold the position of the aircraft. You delete them as any other file.
- **Settings**: your settings and the choices you make in the viewers, such as View as 360°, the 3D layout or 360° or 180°, in the app's database.
- **Logs**: the app's log lines, in its database. At each start, only the last 2,000 are kept. They can hold the addresses of your server and shares, the names of files and folders, and the local addresses of the devices that used the phone share. Passwords are not written to them. The Logs page has a button that shares them as a text file with the app you pick, a button that clears them, and a copy button on each line. The page "Video decoders of this device" has a Copy button that puts the list of decoders and the system version on the clipboard. On Android, parts of the app also write to the system log, which stays on the device and is read with developer tools (adb).

**Deleting the app** deletes everything above that the app keeps in its own storage. On Android, the app's data is left out of the system backup. On iPhone and iPad, iOS can keep the keychain entries of an app after it is deleted, such as the share passwords and the phone share credentials. Removing a share in the app before deleting the app deletes its password. Your server account, its content and the files of your shares are not affected.

## Data on your network

The shares and the phone share work on your network, with the protection of their own protocol. Nothing of it goes to the developer. Not all of this traffic is encrypted in transit.

- **Finding servers.** While the "Add a share" page looks for servers, and when a DLNA share or a phone share no longer answers at its address, the app sends discovery requests on your local network: Bonjour (mDNS), an SSDP search for media servers, and short connections to the usual SMB, WebDAV and web ports of each address of the local network (/24). These requests carry no user name or password.
- **SMB.** The app connects with SMB 2 or 3 and the user name and password you gave. It does not ask the server to encrypt the connection, so the files can travel unencrypted.
- **WebDAV.** With "Secure connection (HTTPS)" on, the connection is encrypted. Without it, the files and the password, sent with HTTP Basic authentication, travel unencrypted.
- **DLNA media servers.** They have no password, and are usually read in plain HTTP, as the protocol works.
- **Plex media servers.** The connection is encrypted when the server address starts with https://; with http://, the token and the files travel unencrypted on your network.
- **Tapo cameras.** The camera account is sent to the camera over its own encrypted connection; the video streams (RTSP) travel unencrypted on your network, as the camera sends them.
- **Share addresses.** The app connects to the address you saved for a share, which can also be outside your home. When a share with a password answers at a new address, the app asks before sending the password there.
- **Share this phone on the network.** The phone share uses plain HTTP: the user name, the password and the files travel unencrypted on your Wi-Fi. It listens only on the Wi-Fi, Ethernet and hotspot addresses of the phone, never on its mobile data or VPN address, and only answers devices with a local address. Every request needs the user name and password. Ten wrong passwords from one device within a minute block it for a minute. A device of your network that can read the traffic could see the password and the files. Use it on a network you trust, and turn it off when you are done.
- **What the phone share serves and announces.** It serves, read only, the albums of the phone, every photo and video by month, and the 360° files the app found, with their own names and the information the files hold. Files stored only in iCloud are left out. While it is on, the phone announces itself on the local network with "Immuch360 on" and the name of the phone, the user name of the share and the identifier of the install, so that your headset can find it. On Android, its notification shows the address and the user name, never the password.
- **Your Immich server.** The connection is encrypted when the server address starts with https://. With http://, it is not.
- **Upload from a share.** The files go from the share to the app, then from the app to your Immich server, each step with the protection described above.
- **Sign in with your phone.** The screen answers only devices of its local network, and only while it shows a code; it is announced on the network (DNS-SD) with its name and its kind, never with the code. The session sent to it, or the email and password of the browser page, travel encrypted with a key that only the phone and the screen can make from the code.

## Permissions

- **Photos and videos**: to back them up, to show the photos and videos of the device, and to serve them with the phone share.
- **Notifications**: backup progress, and on Android the notification of the phone share, asked on Android 13 and later when you turn the share on.
- **Network access**: your server, your shares, the phone share and sign in with your phone.
- **USB** (Android, experimental): the drone, controller or card you plug in and pick, and a DJI remote controller on the DJI link page, after you allow it.
- **Local network** (iPhone and iPad): to reach a server on your network, to cast, to find and read shares and media servers, and to share the phone with your headset.
- **Wi-Fi multicast** (Android): to find shares, media servers and the phone share with Bonjour (mDNS) and SSDP.
- **Foreground services** (Android): the background upload service, and the phone share service. The phone share service keeps the share running with the screen off, shows a notification with the address, the user name and a Stop button, and keeps the Wi-Fi and the processor awake while it runs.
- **Location**: only to read the name of the current Wi-Fi network when you restrict backup to a given network.
- **Camera**: for the Spatial 2.5D mode, and to scan the code of a screen you sign in, see Camera below.
- **Face ID or fingerprint**: to open the locked folder, if you use it.
- **Motion sensors**: to turn a 360° photo as you move the device, read on the device only.
- **Hand tracking** (Meta Quest): to use the immersive view with your hands.
- **Windows, Linux and macOS**: no system permission; the app reads the folders you choose and, on Windows, the files you open with it.

The permissions that need your consent are asked when a feature first needs them. The Meta Quest build has no camera, location or phone share permission.

## Camera

The camera is used only while the experimental Spatial 2.5D mode is active, where the front camera follows the position of your head so the video can show depth, and while you scan the code of a TV, a headset or a computer to sign it in. The images are processed on the device, are never stored, and are never sent to your server or anywhere else. The permission is asked when you first use the mode, and you can revoke it at any time in the system settings.

## Third parties

Your Immich server is operated by you or by the person who gave you an account; its own privacy rules apply. The same goes for the shares and media servers you add. When you open the map, the tile service your server is configured to use, by default the one of the Immich project, receives the requests for the map tiles. The app contains no third party advertising or tracking SDK. On Meta Quest headsets it uses the Meta Spatial SDK to render the immersive view; that library runs locally. Your Plex server and your Tapo cameras are yours: the app talks to them on your network only, and their makers' own privacy rules apply to their products.

## Your rights

Deleting the app removes its local data, as described in "Data stored on the device". In the app, you can remove a share, clear the logs and turn off the phone share at any time. Your server account and its content are managed on your Immich server.

## Contact

Questions about this policy: open an issue at https://github.com/freeKC/Immuch360/issues.

## Changes

22 October 2026: added sign in with your phone (the camera used to scan a code, the listener of the screen, the session sent to it, the list of screens), the DJI drone and DJI link pages, and the USB permission.

13 October 2026: added Android TV and Google TV, the Quest 2, Pro and 3S, the Windows app and the Linux and macOS previews, Plex media servers, Tapo cameras, and the secure storage on Windows and Linux.

6 October 2026: added the mode without a server, network shares, upload from a share, Share this phone on the network, raw camera files, Apple spatial photos, the data stored on the device, the data on your network and the new permissions. The camera and Face ID permissions now say what they are used for in this app. The previous version, of 30 September 2026, covered the server mode only.

Last updated: 22 October 2026.
