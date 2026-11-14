#!/usr/bin/env python3
"""A made-up Subsonic server with a big library, to stress the demo instance: scripts/big-server.py [port]

Run the app against it with MUSICSYNC_DEMO_SERVER=http://127.0.0.1:<port> (demo mode only).
Sizes (env): BIG_ARTISTS (2000), BIG_ALBUMS (5000), BIG_SONGS_PER_ALBUM (10), BIG_PLAYLISTS (500).
Playlist pl-0 holds 10000 songs, the others 50; artist ar-0 has every 40th album as well. BIG_MEDIA=1 draws album covers
in the asked size (up to 1000 px) and streams 30 s of silence for every song. Otherwise covers, streams and lyrics are
missing, except for the podcasts:
three channels with drawn covers, bookmarks kept in memory, and silent episode streams (seekable).
The user has the jukebox role; the jukebox keeps its playlist in memory and plays no sound."""
import functools
import json
import os
import random
import struct
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ARTISTS = int(os.environ.get("BIG_ARTISTS", 2000))
ALBUMS = int(os.environ.get("BIG_ALBUMS", 5000))
PER_ALBUM = int(os.environ.get("BIG_SONGS_PER_ALBUM", 10))
PLAYLISTS = int(os.environ.get("BIG_PLAYLISTS", 500))
GENRES = ["Rock", "Jazz", "Electronic", "Ambient", "Hip-Hop", "Classical", "Folk", "Metal", "Pop", "Soul",
          "Блюз", "J-Pop", "Música Popular", "Post-Rock", "Drum & Bass", "Synthwave", "Trip-Hop", "Gospel", "Reggae", "K-Pop"]
WORDS = ["Night", "Echo", "Blue", "Ocean", "Glass", "Fire", "Dream", "Silver", "Ghost", "Garden", "Signal", "River",
         "Mirror", "Paper", "Storm", "Velvet", "Neon", "Winter", "Gold", "Shadow", "Björk", "Café", "東京", "Ночь"]


def name(i, n):
    return " ".join(WORDS[(i * 7 + k * 13) % len(WORDS)] for k in range(n)) + f" {i}"


def day(i):
    return f"20{10 + i % 15:02d}-{1 + i % 12:02d}-{1 + i % 28:02d}T12:00:00Z"


artists = [{"id": f"ar-{i}", "name": name(i, 2), "albumCount": 0} for i in range(ARTISTS)]
albums, songs = [], []
for a in range(ALBUMS):
    artist = artists[0 if a % 40 == 0 else a % ARTISTS]
    artist["albumCount"] += 1
    genre = GENRES[a % len(GENRES)]
    album = {"id": f"al-{a}", "name": name(a, 3), "artist": artist["name"], "artistId": artist["id"],
             "year": 1960 + a % 65, "genre": genre, "songCount": PER_ALBUM, "created": day(a), "coverArt": f"al-{a}",
             "playCount": a % 37}
    if a % 25 == 0:
        album["starred"] = day(a)
    tracks = []
    for t in range(PER_ALBUM):
        s = a * PER_ALBUM + t
        song = {"id": f"s-{s}", "parent": album["id"], "title": name(s, 2 + s % 3), "album": album["name"],
                "albumId": album["id"], "artist": artist["name"], "artistId": artist["id"], "track": t + 1,
                "discNumber": 1, "year": album["year"], "genre": genre, "duration": 120 + s % 300, "size": 5_000_000,
                "suffix": "flac", "bitRate": 900, "coverArt": album["id"], "playCount": s % 11, "created": album["created"]}
        if s % 50 == 0:
            song["starred"] = day(s)
        tracks.append(song)
    album["duration"] = sum(x["duration"] for x in tracks)
    albums.append(album)
    songs.extend(tracks)
by_album = {a["id"]: songs[i * PER_ALBUM:(i + 1) * PER_ALBUM] for i, a in enumerate(albums)}
song_by_id = {s["id"]: s for s in songs}
playlists = []
for p in range(PLAYLISTS):
    count = min(10000 if p == 0 else 50, len(songs))
    ids = [songs[(p * 997 + k * 31) % len(songs)]["id"] for k in range(count)]
    playlists.append({"id": f"pl-{p}", "name": name(p, 2) + " Mix", "owner": "demo", "public": False, "songCount": count,
                      "duration": sum(song_by_id[i]["duration"] for i in ids), "created": day(p), "changed": day(p), "ids": ids})


PODCASTS = [("Night Talks", (214, 52, 71), (88, 24, 69)), ("The Long Read", (36, 99, 176), (20, 40, 90)),
            ("Field Recordings", (46, 140, 87), (16, 64, 48))]
TITLES = ["The Quiet Hours", "What the River Knew", "Letters From Nowhere", "A Short History of Maps", "Night Shift",
          "The Last Lighthouse", "Small Machines", "How Cities Sleep", "Paper Trails", "Under the Ice", "The Sound of Rain",
          "Northern Lines", "Glass Houses", "Signals", "The Long Way Home", "Old Radios", "Morning Birds", "Salt and Stone"]
channels, episodes = [], []
for c, (title, _, _) in enumerate(PODCASTS):
    channels.append({"id": f"ch-{c}", "url": f"https://example.com/{c}/feed.xml", "title": title, "coverArt": f"pod-{c}",
                     "status": "completed", "description": f"<p>Weekly conversations from <b>{title}</b> &amp; friends.</p>"
                                                           "<p>New episodes every Monday.</p>" * (1 if c < 2 else 12)})
    for e in range(6):
        on_server = e < 4
        episodes.append({"id": f"ep-{c}-{e}", "channelId": f"ch-{c}", "title": TITLES[(c * 6 + e) % len(TITLES)],
                         "description": f"Episode {6 - e}: <i>{title}</i> on long walks, old letters and what comes next.",
                         "publishDate": f"2026-{11 - e:02d}-{10 - c:02d}T08:00:00.000Z", "status": "completed" if on_server else "new",
                         "duration": 660 + e * 600, "coverArt": f"pod-{c}", "album": title, "artist": title, "suffix": "wav",
                         "contentType": "audio/wav", "size": 5_280_044, **({"streamId": f"st-{c}-{e}"} if on_server else {})})
episodes[2]["playCount"] = 1
bookmarks = {"st-0-1": 420_000}


def png(top, bottom, size=300):
    """A square with a vertical gradient."""
    rows = b"".join(b"\0" + bytes(round(t + (b - t) * y / size) for t, b in zip(top, bottom)) * size for y in range(size))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


MEDIA = os.environ.get("BIG_MEDIA") == "1"


@functools.lru_cache(maxsize=None)
def album_cover(n, size):
    """One of 24 gradients."""
    return png(((n * 53) % 256, (n * 97) % 256, (n * 151) % 256), ((n * 29) % 256, 40, (n * 71) % 256), size)


def silence(seconds):
    """8 kHz mono 8-bit WAV."""
    n = seconds * 8000
    return b"RIFF" + struct.pack("<I", 36 + n) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8) \
        + b"data" + struct.pack("<I", n) + b"\x80" * n


def podcast(method, q):
    if method == "getPodcasts":
        found = [c for c in channels if q.get("id") in (None, c["id"])]
        with_episodes = q.get("includeEpisodes", "true") == "true"
        return {"podcasts": {"channel": [dict(c, episode=[e for e in episodes if e["channelId"] == c["id"]]) if with_episodes else c
                                         for c in found]}}
    if method == "getNewestPodcasts":
        on_server = sorted((e for e in episodes if "streamId" in e), key=lambda e: e["publishDate"], reverse=True)
        return {"newestPodcasts": {"episode": on_server[:int(q.get("count", 20))]}}
    if method == "createPodcastChannel":
        channels.append({"id": f"ch-{len(channels)}", "url": q.get("url", ""), "title": q.get("url", ""), "status": "new"})
    if method == "deletePodcastChannel":
        channels[:] = [c for c in channels if c["id"] != q.get("id")]
    episode = next((e for e in episodes if e["id"] == q.get("id")), {})
    if method == "downloadPodcastEpisode" and episode:
        episode.update(status="completed", streamId="st-" + episode["id"][3:])
    if method == "deletePodcastEpisode" and episode:
        episode["status"] = "deleted"
        episode.pop("streamId", None)
    if method == "getBookmarks":
        by_stream = {e.get("streamId"): e for e in episodes}
        return {"bookmarks": {"bookmark": [{"position": p, "username": "demo", "created": day(0), "changed": day(0),
                                            "entry": dict(by_stream[i], id=i, isDir=False)} for i, p in bookmarks.items() if i in by_stream]}}
    if method == "createBookmark":
        bookmarks[q.get("id")] = int(q.get("position", 0))
    if method == "deleteBookmark":
        bookmarks.pop(q.get("id"), None)
    return {}


jukebox = {"ids": [], "index": -1, "playing": False, "gain": 0.5, "offset": 0.0, "since": 0.0}


def jukebox_position():
    """Seconds into the current song; it runs on while playing, up to the song's end."""
    j = jukebox
    if not 0 <= j["index"] < len(j["ids"]):
        return 0
    run = time.time() - j["since"] if j["playing"] else 0
    return int(min(j["offset"] + run, song_by_id.get(j["ids"][j["index"]], {}).get("duration", 0)))


def jukebox_control(q, ids):
    j, action = jukebox, q.get("action")
    if action == "start" and 0 <= j["index"] < len(j["ids"]):
        j.update(playing=True, since=time.time())
    elif action == "stop":
        j.update(offset=jukebox_position(), playing=False)
    elif action in ("set", "clear"):
        j.update(ids=ids if action == "set" else [], index=0 if ids and action == "set" else -1, playing=False, offset=0)
    elif action == "add":
        j["ids"] += ids
        j["index"] = max(j["index"], 0)
    elif action == "skip":
        index = int(q.get("index", -1))
        if not 0 <= index < len(j["ids"]):
            return {"error": {"code": 0, "message": "Index out of range"}}
        j.update(index=index, offset=int(q.get("offset", 0)), since=time.time())
    elif action == "remove" and 0 <= int(q.get("index", -1)) < len(j["ids"]):
        del j["ids"][int(q["index"])]
    elif action == "shuffle":
        random.shuffle(j["ids"])
        j.update(index=0 if j["ids"] else -1, offset=0, since=time.time())
    elif action == "setGain":
        j["gain"] = min(max(float(q.get("gain", 0.5)), 0), 1)
    elif action not in ("get", "status"):
        return {"error": {"code": 0, "message": f"Unknown action {action}"}}
    status = {"currentIndex": j["index"], "playing": j["playing"], "gain": j["gain"], "position": jukebox_position()}
    if action == "get":
        return {"jukeboxPlaylist": dict(status, entry=[song_by_id[i] for i in j["ids"] if i in song_by_id])}
    return {"jukeboxStatus": status}


def page(items, q, size="size", offset="offset", default=50):
    start = int(q.get(offset, 0))
    return items[start:start + int(q.get(size, default))]


def album_list(q):
    kind = q.get("type", "alphabeticalByName")
    items = {"alphabeticalByName": sorted(albums, key=lambda a: a["name"]),
             "newest": sorted(albums, key=lambda a: a["created"], reverse=True),
             "frequent": sorted(albums, key=lambda a: -a["playCount"]),
             "starred": [a for a in albums if "starred" in a],
             "byGenre": [a for a in albums if a["genre"] == q.get("genre")]}.get(kind, albums)
    return {"albumList2": {"album": page(items, q, default=10)}}


def search(q):
    text = q.get("query", "").strip('"').lower()
    match = lambda x, key: text in x[key].lower()
    return {"searchResult3": {"artist": page([a for a in artists if match(a, "name")], q, "artistCount", "artistOffset", 20),
                              "album": page([a for a in albums if match(a, "name")], q, "albumCount", "albumOffset", 20),
                              "song": page([s for s in songs if match(s, "title")], q, "songCount", "songOffset", 20)}}


def reply(method, q):
    if method == "getScanStatus":
        return {"scanStatus": {"scanning": False, "count": len(songs), "lastScan": "2024-01-01T00:00:00Z"}}
    if method == "getArtists":
        return {"artists": {"index": [{"name": "#", "artist": artists}]}}
    if method == "getArtist":
        artist = next((a for a in artists if a["id"] == q.get("id")), None)
        return artist and {"artist": dict(artist, album=[a for a in albums if a["artistId"] == artist["id"]])}
    if method == "getAlbumList2":
        return album_list(q)
    if method == "getAlbum":
        album = next((a for a in albums if a["id"] == q.get("id")), None)
        return album and {"album": dict(album, song=by_album[album["id"]])}
    if method == "getSong":
        return q.get("id") in song_by_id and {"song": song_by_id[q["id"]]}
    if method == "getPlaylists":
        return {"playlists": {"playlist": [{k: v for k, v in p.items() if k != "ids"} for p in playlists]}}
    if method == "getPlaylist":
        p = next((p for p in playlists if p["id"] == q.get("id")), None)
        return p and {"playlist": dict({k: v for k, v in p.items() if k != "ids"}, entry=[song_by_id[i] for i in p["ids"]])}
    if method == "updatePlaylist":  # adds the first songIdToAdd and removes the first songIndexToRemove only
        p = next((p for p in playlists if p["id"] == q.get("playlistId")), None)
        if p and "songIdToAdd" in q:
            p["ids"].append(q["songIdToAdd"])
        if p and q.get("songIndexToRemove", "").isdigit() and int(q["songIndexToRemove"]) < len(p["ids"]):
            del p["ids"][int(q["songIndexToRemove"])]
        if p:
            p["songCount"] = len(p["ids"])
        return p and {}
    if method == "getStarred2":
        return {"starred2": {"artist": [a for a in artists[:50]], "album": [a for a in albums if "starred" in a],
                             "song": [s for s in songs if "starred" in s]}}
    if method == "getGenres":
        return {"genres": {"genre": [{"value": g, "songCount": len(songs) // len(GENRES), "albumCount": len(albums) // len(GENRES)} for g in GENRES]}}
    if method == "getSongsByGenre":
        return {"songsByGenre": {"song": page([s for s in songs if s["genre"] == q.get("genre")], q, "count")}}
    if method == "search3":
        return search(q)
    if method == "getUser":
        return {"user": {"username": "demo", "adminRole": False, "streamRole": True, "playlistRole": True, "shareRole": False,
                         "podcastRole": True, "jukeboxRole": True}}
    if method == "getOpenSubsonicExtensions":
        return {"openSubsonicExtensions": []}
    if method == "getPlayQueue":
        return {}
    if method in ("getCoverArt", "stream", "download", "getLyricsBySongId"):
        return None
    return podcast(method, q)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        method = url.path.rsplit("/", 1)[-1].removesuffix(".view")
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        cover = PODCASTS[int(q["id"][4:])] if method == "getCoverArt" and q.get("id", "").startswith("pod-") else None
        if cover:
            return self.send(png(cover[1], cover[2]), "image/png")
        if method == "getCoverArt" and MEDIA and q.get("id", "").startswith("al-"):
            return self.send(album_cover(int(q["id"][3:]) % 24, min(int(q.get("size", 1000)), 1000)), "image/png")
        if method == "stream" and q.get("id", "").startswith("st-"):
            return self.send(SILENCE, "audio/wav")
        if method == "stream" and MEDIA and q.get("id", "").startswith("s-"):
            return self.send(SONG, "audio/wav")
        body = jukebox_control(q, parse_qs(url.query).get("id", [])) if method == "jukeboxControl" else reply(method, q)
        if body is None or body is False:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps({"subsonic-response": {"status": "failed" if "error" in body else "ok", "version": "1.16.1", "openSubsonic": True, **body}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send(self, data, kind):
        """Whole file or one byte range, so the player can seek."""
        start, end = 0, len(data) - 1
        spec = self.headers.get("Range", "")
        if spec.startswith("bytes="):
            first, _, last = spec[6:].partition("-")
            start, end = int(first or 0), min(int(last) if last else end, end)
        self.send_response(206 if spec else 200)
        self.send_header("Content-Type", kind)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if spec:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        self.wfile.write(data[start:end + 1])

    do_POST = do_GET

    def log_message(self, *args):
        pass


SILENCE = silence(max(e["duration"] for e in episodes))
SONG = silence(30)
port = int(sys.argv[1]) if len(sys.argv) > 1 else 4533
print(f"{len(artists)} artists, {len(albums)} albums, {len(songs)} songs, {len(playlists)} playlists on port {port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
