Answers of Jellyfin and Emby servers, for the tests of lib/infrastructure/network/jellyfin.

Recorded on 18 November 2026 from three servers in Docker on the build host of the project (the release 49 bench):
jellyfin/jellyfin 12.4 (server 12.4.0) in this folder, jellyfin/jellyfin 10.10.7 in ../jellyfin-10.10 and
emby/embyserver 4.10.2.0 in ../emby, each holding only test media made with ffmpeg from its own patterns and tones
(titles such as "Pattern (2024)" and "Tone (2021)" are the names of those files; no metadata or picture came from the
internet: every fetcher was off). Signed in as a test user without the download right.

Cleaned before they were saved, by store/m2/release-49/jellyfin-bench/record.py of the research folder: every id of 32
hex digits (with or without dashes) became a stable fake (f000...0001 and on), AccessToken, Secret, DeviceId, ETag and
any ApiKey or api_key became "redacted", every IPv4 address became 192.0.2.10 (a documentation address), server and
device names became "Bench". No token, password or real address is left.
