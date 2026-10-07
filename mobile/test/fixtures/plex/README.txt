Plex Media Server fixtures of the Plex client tests (test/infrastructure/network/plex/).

Made after the answers of a Plex Media Server 1.42.1 captured on 2026-10-07 with curl and a UDP socket: the
structure of each answer (element and attribute names, value types, line ends) is the captured one, and every value
is made up (hash 0123456789abcdef0123456789abcdef, machine id 0000000000000000000000000000000000000001, addresses
of the documentation ranges, titles and paths of no real library). Nothing of the captured server is kept.
- identity.json, identity.xml, unauthorized.html (the body of a 401, HTML whatever Accept says), server_root.json
  (GET / with the token).
- gdm_answer.txt: the GDM answer, with its line ends as sent: CRLF after the status line, LF after each header.
- sections.json: the movie section; the photo, show and music sections are hand written after it.
- folder_root.json, folder_child_page1.json, folder_child_page2.json: the folder view of a movie section, folders
  and items in the Metadata array, pages with offset and totalSize.
- account.json (/myplex/account, under MyPlex), prefs.json (/:/prefs, ManualPortMappingMode a bool).

Hand written, the captured server having no photo library or player: photo_all.json, album_children.json (after
python-plexapi), gdm_player_answer.txt, folder_no_total.json, folder_empty.json.
