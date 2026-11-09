#!/usr/bin/env python3
"""A fake Immich server for the lab tests of the Android lab (immuch360-android-lab.yml), and their hands on the emulator.

The lab tests run in the app on an emulator of the runner and reach this server at http://10.0.2.2:<port>, the address
of the runner seen from the emulator. It answers what the app asks to sign in, to sync a timeline of three photos (a
JPEG, a HEIC and an AVIF), to show their thumbnails, previews and originals, to take an upload and to keep its web
socket open, as Immich 3.3.5 (the version of media.freekc.fr):

- GET /.well-known/immich answers 302 with the relative Location /lab/well-known/immich, which gives the API endpoint;
  GET /api/server/ping answers 302 with the relative Location ping-target (so /api/server/ping-target); POST
  /api/auth/login answers 302 with the relative Location /api/auth/login-target, where the sign in is checked. The
  app's OkHttp resolves those Locations itself (RedirectInterceptor of mobile/packages/ok_http, crash F1 of release 44).
- POST /api/sync/stream streams the user and the three photos; after POST /lab/hold-next-sync the next stream sends the
  same events and stays open until the client closes it or POST /lab/release-syncs, as a slow server does while a
  background run is cancelled. Which side closed each stream is recorded.
- GET /api/assets/<id>/thumbnail and /original serve the files of mobile/test/fixtures/android_lab (ranges included);
  POST /api/assets reads the multipart upload and records its fields, its size and its SHA-1.
- GET /lab/state gives the requests, the streams, the uploads and the web socket to the tests; GET /lab/fixture/<name>
  serves a fixture file.

Every JSON answer and every sync event is checked against the schemas of open-api/immich-openapi-specs.json when the
server starts (--check runs that check alone and exits), so a change of the API that the fake answers no longer follow
fails here rather than as a puzzling test failure.

The tests also print "LAB_HOST <id> <command> [argument]" lines to logcat; with --serial the server follows logcat
through adb and runs them on the emulator: "grant" (the media and notification permissions the app would ask in a
dialog), "home" (the Home key), "open" (the launcher intent of the app again), "mark" (a place in logcat) and
"wait <mark> <regex>" (the first logcat line after that mark that matches). GET /lab/host/<id> says when a command is
done and what it found.

Usage: fake_immich.py --port 2283 --fixtures mobile/test/fixtures/android_lab --spec open-api/immich-openapi-specs.json
       [--out DIR] [--adb ADB --serial emulator-5554 --package com.aprogsys.immuch360.debug] | --check
"""

import argparse
import base64
import hashlib
import json
import os
import queue
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

VERSION = (3, 3, 5)
USER_ID = "8d2f1d55-6a0e-4f0e-9a52-6f3c1b7e2a10"
EMAIL = "lab@immuch360.test"
PASSWORD = "lab-password"
NAME = "Lab"
TOKEN = "lab-access-token-0123456789"
CREATED = "2026-11-01T09:00:00.000Z"

# The photos of the timeline: id, file of the fixtures, name, type, size in pixels, date
ASSETS = [
    {"id": "4b1c7d0e-1f2a-4c3b-8d4e-5f6a7b8c9d01", "file": "lab_photo.jpg", "name": "lab_jpeg.jpg",
     "mime": "image/jpeg", "width": 1200, "height": 800, "date": "2026-11-03T10:00:00.000Z"},
    {"id": "4b1c7d0e-1f2a-4c3b-8d4e-5f6a7b8c9d02", "file": "lab_photo.heic", "name": "lab_heic.heic",
     "mime": "image/heic", "width": 1200, "height": 800, "date": "2026-11-02T10:00:00.000Z"},
    {"id": "4b1c7d0e-1f2a-4c3b-8d4e-5f6a7b8c9d03", "file": "lab_photo.avif", "name": "lab_avif.avif",
     "mime": "image/avif", "width": 1200, "height": 800, "date": "2026-11-01T10:00:00.000Z"},
]
THUMBNAILS = {"thumbnail": "lab_thumbnail.jpg", "preview": "lab_preview.jpg", "fullsize": "lab_preview.jpg"}
FIXTURES = ["lab_photo.jpg", "lab_photo.heic", "lab_photo.avif", "lab_thumbnail.jpg", "lab_preview.jpg",
            "lab_large.heic", "lab_large.avif"]
FIXTURE_TYPES = {".jpg": "image/jpeg", ".heic": "image/heic", ".avif": "image/avif"}

# The permissions the app asks in a dialog, which a test on the emulator cannot answer
PERMISSIONS = [
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.ACCESS_MEDIA_LOCATION",
    "android.permission.POST_NOTIFICATIONS",
]


# ---------------------------------------------------------------------------------------------------------------------
# The answers, and their check against the OpenAPI schemas


def json_answers():
    """Every JSON answer of the fake, by name: (schema, value); a schema "[X]" is an array of X"""
    user_admin = {
        "avatarColor": "primary", "clusterGroupId": "6f0b6b2e-1d1c-4e8a-9a51-1f1d8f0e2c33", "createdAt": CREATED,
        "deletedAt": None, "email": EMAIL, "id": USER_ID, "isAdmin": True, "license": None, "name": NAME,
        "oauthId": "", "profileChangedAt": CREATED, "profileImagePath": "", "quotaSizeInBytes": None,
        "quotaUsageInBytes": 0, "shouldChangePassword": False, "status": "active", "storageLabel": "admin",
        "updatedAt": CREATED,
    }
    preferences = {
        "albums": {"defaultAssetOrder": "desc"}, "cast": {"gCastEnabled": False},
        "download": {"archiveSize": 4294967296, "includeEmbeddedVideos": False},
        "emailNotifications": {"albumInvite": False, "albumUpdate": False, "enabled": False},
        "folders": {"enabled": False, "sidebarWeb": False},
        "memories": {"duration": 5, "enabled": False, "sidebarWeb": False},
        "people": {"enabled": False, "sidebarWeb": False, "updateStrategy": "self"},
        "purchase": {"hideBuyButtonUntil": "2099-01-01T00:00:00.000Z", "showSupportBadge": False},
        "ratings": {"enabled": False}, "recentlyAdded": {"sidebarWeb": False},
        "sharedLinks": {"enabled": False, "sidebarWeb": False}, "tags": {"enabled": False, "sidebarWeb": False},
    }
    features = {key: False for key in (
        "configFile", "duplicateDetection", "email", "facialRecognition", "importFaces", "map", "oauth",
        "oauthAutoLaunch", "ocr", "realtimeTranscoding", "reverseGeocoding", "search", "sidecar", "smartSearch")}
    features.update(passwordLogin=True, trash=True)
    return {
        "wellKnown": (None, {"api": {"endpoint": "/api"}}),
        "ping": ("ServerPingResponse", {"res": "pong"}),
        "version": ("ServerVersionResponseDto",
                    {"major": VERSION[0], "minor": VERSION[1], "patch": VERSION[2], "prerelease": None}),
        "features": ("ServerFeaturesDto", features),
        "config": ("ServerConfigDto", {
            "externalDomain": "", "isInitialized": True, "isOnboarded": True, "loginPageMessage": "",
            "maintenanceMode": False, "mapDarkStyleUrl": "", "mapLightStyleUrl": "", "minFaces": 3,
            "oauthButtonText": "", "publicUsers": True, "trashDays": 30, "userDeleteDelay": 7}),
        "about": ("ServerAboutResponseDto", {"licensed": False, "version": "v%d.%d.%d" % VERSION,
                                             "versionUrl": "https://github.com/immich-app/immich/releases"}),
        "storage": ("ServerStorageResponseDto", {
            "diskAvailable": "100 GiB", "diskAvailableRaw": 107374182400, "diskSize": "200 GiB",
            "diskSizeRaw": 214748364800, "diskUsagePercentage": 50.0, "diskUse": "100 GiB",
            "diskUseRaw": 107374182400}),
        "mediaTypes": ("ServerMediaTypesResponseDto", {
            "image": [".jpg", ".jpeg", ".heic", ".heif", ".avif", ".png", ".webp", ".tif", ".tiff", ".dng"],
            "sidecar": [".xmp"], "video": [".mp4", ".mov", ".webm"]}),
        "versionHistory": ("[ServerVersionHistoryResponseDto]", [
            {"createdAt": CREATED, "id": "0d6c1f2e-9b8a-4c7d-8e6f-5a4b3c2d1e0f", "version": "v%d.%d.%d" % VERSION}]),
        "login": ("LoginResponseDto", {
            "accessToken": TOKEN, "isAdmin": True, "isOnboarded": True, "name": NAME, "profileImagePath": "",
            "shouldChangePassword": False, "userEmail": EMAIL, "userId": USER_ID}),
        "logout": ("LogoutResponseDto", {"redirectUri": "/auth/login?autoLaunch=0", "successful": True}),
        "validateToken": ("ValidateAccessTokenResponseDto", {"authStatus": True}),
        "authStatus": ("AuthStatusResponseDto", {"isElevated": False, "password": True, "pinCode": False}),
        "me": ("UserAdminResponseDto", user_admin),
        "preferences": ("UserPreferencesResponseDto", preferences),
        "acks": ("[SyncAckDto]", []),
    }


def sync_events(files):
    """The events of a sync stream: (type, schema, data, ack). [files] gives the bytes of the originals."""
    events = [
        ("AuthUserV2", "SyncAuthUserV2", {
            "avatarColor": "primary", "deletedAt": None, "email": EMAIL, "hasProfileImage": False, "id": USER_ID,
            "isAdmin": True, "name": NAME, "oauthId": None, "pinCode": None, "profileChangedAt": CREATED,
            "quotaSizeInBytes": None, "quotaUsageInBytes": 0, "storageLabel": "admin"}),
        ("UserV1", "SyncUserV1", {
            "avatarColor": "primary", "deletedAt": None, "email": EMAIL, "hasProfileImage": False, "id": USER_ID,
            "name": NAME, "profileChangedAt": CREATED}),
    ]
    for asset in ASSETS:
        checksum = base64.b64encode(hashlib.sha1(files[asset["file"]]).digest()).decode()
        events.append(("AssetV2", "SyncAssetV2", {
            "checksum": checksum, "createdAt": asset["date"], "deletedAt": None, "duration": None,
            "fileCreatedAt": asset["date"], "fileModifiedAt": asset["date"], "height": asset["height"],
            "id": asset["id"], "isEdited": False, "isFavorite": False, "libraryId": None, "livePhotoVideoId": None,
            "localDateTime": asset["date"], "originalFileName": asset["name"], "ownerId": USER_ID, "stackId": None,
            "thumbhash": None, "type": "IMAGE", "visibility": "timeline", "width": asset["width"]}))
    for asset in ASSETS:
        exif = {key: None for key in (
            "city", "country", "description", "exposureTime", "fNumber", "focalLength", "fps", "iso", "latitude",
            "lensModel", "longitude", "make", "model", "orientation", "profileDescription", "projectionType",
            "rating", "state", "timeZone")}
        exif.update(assetId=asset["id"], dateTimeOriginal=asset["date"], modifyDate=asset["date"],
                    exifImageWidth=asset["width"], exifImageHeight=asset["height"],
                    fileSizeInByte=len(files[asset["file"]]))
        events.append(("AssetExifV1", "SyncAssetExifV1", exif))
    return [(kind, schema, data, f"{kind}|lab-{index}") for index, (kind, schema, data) in enumerate(events)]


UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def schema_errors(spec, value, schema, where):
    """What in [value] does not follow [schema] of the OpenAPI document [spec]: required keys, types, enums, formats"""
    schemas = spec["components"]["schemas"]
    if "$ref" in schema:
        return schema_errors(spec, value, schemas[schema["$ref"].split("/")[-1]], where)
    if "allOf" in schema:
        if value is None and schema.get("nullable"):
            return []
        errors = []
        for part in schema["allOf"]:
            errors += schema_errors(spec, value, part, where)
        return errors
    if value is None:
        return [] if schema.get("nullable") else [f"{where}: null where the schema does not allow it"]
    kind = schema.get("type")
    errors = []
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} is not one of {schema['enum'][:10]}")
    if kind == "object" or "properties" in schema:
        if not isinstance(value, dict):
            return [f"{where}: not an object"]
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: required key {key} missing")
        for key, item in value.items():
            if key in schema.get("properties", {}):
                errors += schema_errors(spec, item, schema["properties"][key], f"{where}.{key}")
    elif kind == "array":
        if not isinstance(value, list):
            return [f"{where}: not an array"]
        for index, item in enumerate(value):
            errors += schema_errors(spec, item, schema["items"], f"{where}[{index}]")
    elif kind == "string":
        if not isinstance(value, str):
            return [f"{where}: {value!r} is not a string"]
        if schema.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                errors.append(f"{where}: {value!r} is not a date-time")
        if schema.get("format") == "uuid" and not UUID.match(value):
            errors.append(f"{where}: {value!r} is not a uuid")
    elif kind == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            errors.append(f"{where}: {value!r} is not an integer")
    elif kind == "number":
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            errors.append(f"{where}: {value!r} is not a number")
    elif kind == "boolean":
        if not isinstance(value, bool):
            errors.append(f"{where}: {value!r} is not a boolean")
    return errors


def check_answers(spec, files):
    """The errors of every JSON answer and sync event against the schemas"""
    errors = []
    for name, (schema, value) in json_answers().items():
        if schema is None:
            continue
        if schema.startswith("["):
            item = {"$ref": f"#/components/schemas/{schema[1:-1]}"}
            errors += schema_errors(spec, value, {"type": "array", "items": item}, name)
        else:
            errors += schema_errors(spec, value, {"$ref": f"#/components/schemas/{schema}"}, name)
    entity_types = spec["components"]["schemas"]["SyncEntityType"]["enum"]
    for kind, schema, data, _ in sync_events(files):
        if kind not in entity_types:
            errors.append(f"sync {kind}: not a SyncEntityType of the specification")
        errors += schema_errors(spec, data, {"$ref": f"#/components/schemas/{schema}"}, f"sync {kind}")
    upload = {"id": str(uuid.uuid4()), "status": "created"}
    errors += schema_errors(spec, upload, {"$ref": "#/components/schemas/AssetMediaResponseDto"}, "upload")
    return errors


# ---------------------------------------------------------------------------------------------------------------------
# The state the tests read


class LabState:
    def __init__(self, files, out):
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.files = files
        self.out = out
        self.requests = []
        self.streams = []
        self.uploads = []
        self.socket = {"opened": 0, "connected": 0, "closedBy": []}
        self.hold_next_sync = False
        self.release = threading.Event()
        self.stopping = threading.Event()
        self.host = {}
        self.answers = json_answers()
        self.events = sync_events(files)

    def now(self):
        return round(time.monotonic() - self.started, 3)

    def record(self, entry):
        with self.lock:
            entry["seq"] = len(self.requests) + 1
            self.requests.append(entry)
            if self.out:
                with open(os.path.join(self.out, "server-requests.jsonl"), "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(entry) + "\n")

    def snapshot(self):
        with self.lock:
            return {
                "requests": list(self.requests), "streams": [dict(s) for s in self.streams],
                "uploads": list(self.uploads), "socket": dict(self.socket), "holdNextSync": self.hold_next_sync,
                "assets": [{k: a[k] for k in ("id", "name", "mime", "width", "height")} for a in ASSETS],
                "user": {"id": USER_ID, "email": EMAIL, "password": PASSWORD},
            }


# ---------------------------------------------------------------------------------------------------------------------
# The HTTP side


def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ImmichLab/1"
    state: LabState = None

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_PUT(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def do_PATCH(self):
        self.route()

    def do_HEAD(self):
        self.route()

    # One request: its body read, its answer sent, and a line in the log
    def route(self):
        url = urlsplit(self.path)
        self.url_path = url.path
        self.query = parse_qs(url.query)
        self.entry = {"t": self.state.now(), "method": self.command, "path": url.path, "query": url.query,
                      "auth": TOKEN in (self.headers.get("x-immich-user-token", "") +
                                        self.headers.get("Authorization", "") + self.headers.get("Cookie", "")),
                      "agent": self.headers.get("User-Agent", "")}
        try:
            self.body = self.read_body()
            self.entry["length"] = len(self.body)
            self.dispatch()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
            self.entry.setdefault("status", "closed by the client")
        finally:
            self.state.record(self.entry)

    def read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return bytes(data)
                data += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def send(self, status, body=b"", content_type="application/json", headers=None):
        self.entry["status"] = status
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        # No Content-Length in a 204, which OkHttp would refuse with a length other than 0
        if status not in (204, 304):
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def answer(self, name, status=200):
        self.send(status, json.dumps(self.state.answers[name][1]).encode())

    def redirect(self, location):
        self.entry["location"] = location
        self.send(302, b"", headers={"Location": location})

    def not_found(self):
        self.entry["unknown"] = True
        self.send(404, json.dumps({"message": "Not found", "statusCode": 404, "error": "Not Found"}).encode())

    def dispatch(self):
        method, path = self.command, self.url_path
        simple = {
            ("GET", "/lab/well-known/immich"): "wellKnown",
            ("GET", "/api/server/ping-target"): "ping",
            ("GET", "/api/server/version"): "version",
            ("GET", "/api/server/features"): "features",
            ("GET", "/api/server/config"): "config",
            ("GET", "/api/server/about"): "about",
            ("GET", "/api/server/storage"): "storage",
            ("GET", "/api/server/media-types"): "mediaTypes",
            ("GET", "/api/server/version-history"): "versionHistory",
            ("POST", "/api/auth/logout"): "logout",
            ("POST", "/api/auth/validateToken"): "validateToken",
            ("GET", "/api/auth/status"): "authStatus",
            ("GET", "/api/users/me"): "me",
            ("GET", "/api/users/me/preferences"): "preferences",
            ("GET", "/api/sync/ack"): "acks",
        }
        if (method, path) in simple:
            return self.answer(simple[(method, path)])
        if method == "GET" and path == "/.well-known/immich":
            return self.redirect("/lab/well-known/immich")
        if method == "GET" and path == "/api/server/ping":
            return self.redirect("ping-target")
        if method == "POST" and path == "/api/auth/login":
            return self.redirect("/api/auth/login-target")
        if method == "POST" and path == "/api/auth/login-target":
            return self.login()
        if path == "/api/sync/ack" and method in ("POST", "DELETE"):
            if method == "POST":
                self.entry["acks"] = json.loads(self.body or b"{}").get("acks", [])
            return self.send(204)
        if method == "POST" and path == "/api/sync/stream":
            return self.sync_stream()
        match = re.match(r"^/api/assets/([0-9a-f-]+)/(thumbnail|original)$", path)
        if match and method in ("GET", "HEAD"):
            return self.asset_file(match.group(1), match.group(2))
        if method == "POST" and path == "/api/assets":
            return self.upload()
        if path.startswith("/api/socket.io") and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.web_socket()
        if path.startswith("/lab/"):
            return self.lab()
        return self.not_found()

    def login(self):
        try:
            credentials = json.loads(self.body or b"{}")
        except ValueError:
            credentials = {}
        self.entry["email"] = credentials.get("email")
        if credentials.get("email") != EMAIL or credentials.get("password") != PASSWORD:
            return self.send(401, json.dumps({"message": "Incorrect email or password", "statusCode": 401,
                                              "error": "Unauthorized"}).encode())
        return self.answer("login", status=201)

    # The jsonlines of a sync, chunked; a held stream stays open after its events
    def sync_stream(self):
        state = self.state
        with state.lock:
            held = state.hold_next_sync
            state.hold_next_sync = False
            stream = {"index": len(state.streams) + 1, "held": held, "openedAt": state.now(), "endedAt": None,
                      "endedBy": None, "types": json.loads(self.body or b"{}").get("types", [])}
            state.streams.append(stream)
        self.entry["stream"] = stream["index"]
        self.entry["status"] = 200
        self.send_response(200)
        self.send_header("Content-Type", "application/jsonlines+json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        wanted = set(stream["types"])
        requested = {"AuthUserV2": "AuthUsersV2", "UserV1": "UsersV1", "AssetV2": "AssetsV2",
                     "AssetExifV1": "AssetExifsV1"}
        ended_by = "server"
        try:
            for kind, _, data, ack in state.events:
                if requested[kind] not in wanted:
                    continue
                line = (json.dumps({"type": kind, "data": data, "ack": ack}) + "\n").encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line))
            self.wfile.flush()
            if held:
                ended_by = self.hold()
            if ended_by != "client":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            ended_by = "client"
        with state.lock:
            stream["endedAt"] = state.now()
            stream["endedBy"] = ended_by
        if ended_by == "client":
            self.close_connection = True

    # Waits until the client closes the connection, the tests release the stream, or two minutes pass
    def hold(self):
        deadline = time.monotonic() + 120
        connection = self.connection
        while time.monotonic() < deadline and not self.state.release.is_set() and not self.state.stopping.is_set():
            readable, _, _ = select.select([connection], [], [], 0.25)
            if readable:
                try:
                    if connection.recv(1, socket.MSG_PEEK) == b"":
                        return "client"
                except (ConnectionResetError, OSError):
                    return "client"
        return "release" if self.state.release.is_set() else "server"

    def asset_file(self, asset_id, kind):
        asset = next((a for a in ASSETS if a["id"] == asset_id), None)
        if asset is None:
            return self.not_found()
        if kind == "thumbnail":
            size = (self.query.get("size") or ["thumbnail"])[0]
            name, mime = THUMBNAILS.get(size, THUMBNAILS["thumbnail"]), "image/jpeg"
            self.entry["size"] = size
        else:
            name, mime = asset["file"], asset["mime"]
        self.entry["asset"] = asset["name"]
        self.file(name, mime)

    def file(self, name, mime):
        data = self.state.files[name]
        match = re.match(r"^bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if match and (match.group(1) or match.group(2)):
            if match.group(1):
                start = int(match.group(1))
                end = min(int(match.group(2)) if match.group(2) else len(data) - 1, len(data) - 1)
            else:
                start, end = max(0, len(data) - int(match.group(2))), len(data) - 1
            self.entry["range"] = f"{start}-{end}"
            return self.send(206, data[start:end + 1], mime,
                             {"Content-Range": f"bytes {start}-{end}/{len(data)}", "Accept-Ranges": "bytes"})
        self.send(200, data, mime, {"Accept-Ranges": "bytes"})

    def upload(self):
        match = re.search(r"boundary=\"?([^\";]+)\"?", self.headers.get("Content-Type", ""))
        if not match:
            return self.send(400, b'{"message":"not multipart"}')
        fields, files = {}, []
        for part in self.body.split(b"--" + match.group(1).encode())[1:]:
            if part.startswith(b"--"):
                break
            head, _, content = part.lstrip(b"\r\n").partition(b"\r\n\r\n")
            content = content[:-2] if content.endswith(b"\r\n") else content
            disposition = re.search(rb'name="([^"]*)"(?:; filename="([^"]*)")?', head)
            if not disposition:
                continue
            name = disposition.group(1).decode()
            if disposition.group(2) is not None:
                files.append({"field": name, "filename": disposition.group(2).decode(), "size": len(content),
                              "sha1": hashlib.sha1(content).hexdigest()})
            else:
                fields[name] = content.decode(errors="replace")
        upload = {"id": str(uuid.uuid4()), "fields": fields, "files": files, "length": len(self.body),
                  "contentLength": self.headers.get("Content-Length"),
                  "chunked": self.headers.get("Transfer-Encoding", "").lower() == "chunked"}
        with self.state.lock:
            self.state.uploads.append(upload)
        self.entry["upload"] = upload["id"]
        ok = any(f["field"] == "assetData" for f in files) and "deviceAssetId" in fields
        if not ok:
            return self.send(400, b'{"message":"assetData and deviceAssetId are required"}')
        self.send(201, json.dumps({"id": upload["id"], "status": "created"}).encode())

    # The web socket of the app: socket.io 4 over a plain web socket, enough to open it, connect and answer pings
    def web_socket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        self.entry["status"] = 101
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", ws_accept(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        state = self.state
        with state.lock:
            state.socket["opened"] += 1
        sid = uuid.uuid4().hex[:20]
        self.ws_send(1, "0" + json.dumps({"sid": sid, "upgrades": [], "pingInterval": 25000, "pingTimeout": 60000,
                                          "maxPayload": 1000000}))
        # The frames are read by a thread of their own, so that this loop can send the pings of socket.io meanwhile
        frames = queue.Queue()

        def read_frames():
            try:
                while True:
                    frame = self.ws_read()
                    frames.put(frame)
                    if frame is None:
                        return
            except (OSError, ValueError, struct.error):
                frames.put(None)

        threading.Thread(target=read_frames, daemon=True).start()
        closed_by = "server"
        last_ping = time.monotonic()
        try:
            while not state.stopping.is_set():
                if time.monotonic() - last_ping > 25:
                    self.ws_send(1, "2")
                    last_ping = time.monotonic()
                try:
                    frame = frames.get(timeout=0.5)
                except queue.Empty:
                    continue
                if frame is None:
                    closed_by = "client"
                    break
                opcode, payload = frame
                if opcode == 8:
                    self.ws_send(8, payload[:2].decode("latin-1") if payload else "")
                    closed_by = "client"
                    break
                if opcode == 9:
                    self.ws_send(10, payload.decode("latin-1"))
                elif opcode == 1:
                    text = payload.decode(errors="replace")
                    if text.startswith("40"):
                        self.ws_send(1, "40" + json.dumps({"sid": uuid.uuid4().hex[:20]}))
                        with state.lock:
                            state.socket["connected"] += 1
                    elif text == "2":
                        self.ws_send(1, "3")
        except (BrokenPipeError, ConnectionResetError, OSError):
            closed_by = "client"
        with state.lock:
            state.socket["closedBy"].append(closed_by)

    def ws_send(self, opcode, text):
        data = text.encode("latin-1") if opcode in (8, 10) else text.encode()
        header = bytes([0x80 | opcode])
        if len(data) < 126:
            header += bytes([len(data)])
        elif len(data) < 65536:
            header += bytes([126]) + struct.pack(">H", len(data))
        else:
            header += bytes([127]) + struct.pack(">Q", len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    # One frame of the client: (opcode, payload unmasked), or None at the end of the connection
    def ws_read(self):
        head = self.rfile.read(2)
        if len(head) < 2:
            return None
        opcode, length = head[0] & 0x0F, head[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
        data = self.rfile.read(length)
        if len(data) < length:
            return None
        return opcode, bytes(b ^ mask[i % 4] for i, b in enumerate(data))

    def lab(self):
        state, path = self.state, self.url_path
        if path == "/lab/state":
            return self.send(200, json.dumps(state.snapshot()).encode())
        if path == "/lab/hold-next-sync" and self.command == "POST":
            with state.lock:
                state.hold_next_sync = True
                state.release.clear()
            return self.send(204)
        if path == "/lab/release-syncs" and self.command == "POST":
            state.release.set()
            return self.send(204)
        if path.startswith("/lab/fixture/"):
            name = path[len("/lab/fixture/"):]
            if name in state.files:
                return self.file(name, FIXTURE_TYPES.get(os.path.splitext(name)[1], "application/octet-stream"))
        if path.startswith("/lab/host/"):
            command = state.host.get(path[len("/lab/host/"):])
            return self.send(200, json.dumps(command or {"done": False, "seen": False}).encode())
        return self.not_found()


# ---------------------------------------------------------------------------------------------------------------------
# The hands on the emulator: the LAB_HOST lines of the tests in logcat


class Host(threading.Thread):
    MARKER = re.compile(r"LAB_HOST (\S+) (\S+)(?: (.*))?$")

    def __init__(self, state, adb, serial, package, out):
        super().__init__(daemon=True)
        self.state, self.adb, self.serial, self.package, self.out = state, adb, serial, package, out
        self.lines = []
        self.marks = {}
        self.waits = []
        self.lock = threading.Lock()
        self.process = None

    def log(self, text):
        if self.out:
            with open(os.path.join(self.out, "server-host.log"), "a", encoding="utf-8") as handle:
                handle.write(f"{self.state.now():9.3f} {text}\n")

    def shell(self, *args):
        result = subprocess.run([self.adb, "-s", self.serial, "shell", *args], capture_output=True, text=True,
                                timeout=60)
        return (result.stdout + result.stderr).strip()

    def done(self, command_id, result="", error=None):
        self.state.host[command_id] = {"done": True, "seen": True, "result": result, "error": error,
                                       "at": self.state.now()}
        self.log(f"{command_id} done: {error or result}"[:500])

    def run_command(self, command_id, verb, argument):
        try:
            if verb == "grant":
                outputs = [self.shell("pm", "grant", self.package, permission) for permission in PERMISSIONS]
                self.done(command_id, "; ".join(o for o in outputs if o) or "granted")
            elif verb == "home":
                self.done(command_id, self.shell("input", "keyevent", "KEYCODE_HOME") or "home")
            elif verb == "open":
                self.done(command_id, self.shell(
                    "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER",
                    "-n", f"{self.package}/app.alextran.immich.MainActivity"))
            else:
                self.done(command_id, error=f"unknown command {verb}")
        except Exception as error:  # noqa: BLE001 - the test reads the error
            self.done(command_id, error=f"{type(error).__name__}: {error}")

    def on_line(self, line):
        with self.lock:
            index = len(self.lines)
            self.lines.append(line)
            for wait in list(self.waits):
                # The LAB_HOST lines name the patterns themselves
                if "LAB_HOST " not in line and wait["regex"].search(line):
                    self.waits.remove(wait)
                    self.done(wait["id"], line)
        if "LAB_HOST " not in line:
            return
        match = self.MARKER.search(line.rstrip())
        if not match:
            return
        command_id, verb, argument = match.group(1), match.group(2), (match.group(3) or "").strip()
        if command_id in self.state.host:
            return
        self.state.host[command_id] = {"done": False, "seen": True}
        self.log(f"{command_id} {verb} {argument}")
        if verb == "mark":
            with self.lock:
                self.marks[command_id] = index
            return self.done(command_id, str(index))
        if verb == "wait":
            since, _, pattern = argument.partition(" ")
            try:
                regex = re.compile(pattern)
            except re.error as error:
                return self.done(command_id, error=f"bad regex: {error}")
            with self.lock:
                start = self.marks.get(since, index) + 1
                found = next((old for old in self.lines[start:index]
                              if "LAB_HOST " not in old and regex.search(old)), None)
                if found is None:
                    self.waits.append({"id": command_id, "regex": regex})
            if found is not None:
                self.done(command_id, found)
            return
        threading.Thread(target=self.run_command, args=(command_id, verb, argument), daemon=True).start()

    def run(self):
        while not self.state.stopping.is_set():
            process = subprocess.Popen([self.adb, "-s", self.serial, "logcat", "-v", "threadtime", "-T", "1"],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                       errors="replace")
            self.process = process
            for line in process.stdout:
                self.on_line(line.rstrip("\n"))
                if self.state.stopping.is_set():
                    break
            process.kill()
            time.sleep(1)


def load_files(folder):
    files = {}
    for name in FIXTURES:
        with open(os.path.join(folder, name), "rb") as handle:
            files[name] = handle.read()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=2283)
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--out")
    parser.add_argument("--adb")
    parser.add_argument("--serial")
    parser.add_argument("--package", default="com.aprogsys.immuch360.debug")
    parser.add_argument("--check", action="store_true", help="check the answers against the schemas and exit")
    args = parser.parse_args()

    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)
    files = load_files(args.fixtures)
    errors = check_answers(spec, files)
    for error in errors:
        print(f"::error::fake Immich answer: {error}")
    if errors or args.check:
        print(f"Fake Immich answers against {os.path.basename(args.spec)}: {len(errors)} errors, "
              f"{len(json_answers())} answers and {len(sync_events(files))} sync events checked")
        return 1 if errors else 0

    if args.out:
        os.makedirs(args.out, exist_ok=True)
    state = LabState(files, args.out)
    Handler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    host = None
    if args.serial:
        host = Host(state, args.adb or "adb", args.serial, args.package, args.out)
        host.start()

    # The kill of the lab script ends the logcat reader too
    def stop(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    print(f"Fake Immich {'.'.join(map(str, VERSION))} on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        state.stopping.set()
        if host is not None and host.process is not None:
            host.process.kill()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
