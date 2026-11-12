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
- metadata_item.json: one film asked by its rating key (/library/metadata/{id}), hand written after the folder
  view items with its Part and Stream elements (Play on the TV).

Hand written for the films (lot A2, 10 November 2026), after the official reference (https://developer.plex.tv/pms/,
schemas metadata, media, part, stream, filter) and python-plexapi, no capture of a server yet: metadata_film.json (the
full item of a film with includeGuids: Guid, Genre, Director, Writer, Role, the streams of its file with a subtitle
inside it, a SubRip file beside it and an image subtitle file), section_filters.json, filter_year.json,
filter_decade.json, filter_content_rating.json (the filters of a library and their values, Directory elements).
filter_content_rating.json follows the answer of PMS 1.42.1 seen on 11 November 2026: the key of each value percent
encoded ("fr%2F12"), its title as the films hold it ("fr/12"), and a fastKey.

Hand written after the Plex Media Server API reference 1.2.3 (developer.plex.tv/pms, Library and Search) and
python-plexapi, no server being asked (lot A1 of the films study, 11 November 2026); titles, ids and paths made up:
- films_all_page.json: a page of /library/sections/1/all?type=1&sort=year:desc,titleSort, a film without a year last.
- films_years_light.json: the same list trimmed by excludeElements and excludeFields (the light pass of the years).
- hubs_search.json: /hubs/search?query=elan&sectionId=1, a film of another library in the movie hub, an actor hub.

After the answer of a Plex Media Server 1.42.1 read on 11 November 2026 (/library/metadata/{id} of a film with
subtitle files beside it; field names and value types kept, every title, id, path and hash made up):
- metadata_film_sidecars.json: one file with three subtitle files beside it, as that server lists them: a SubRip file
  with its language, one without ("Unknown"), and one Plex calls WebVTT from its name. On that server the side files
  come as they are on the disk from /library/streams/{id}: the format parameter converts nothing, a path ending in
  another extension than the stream's codec answers 404, encoding=utf-8 turns a Latin-1 file into UTF-8 and leaves a
  UTF-8 one byte for byte, and a file named .vtt may hold SubRip or ASS text.
