#!/usr/bin/env python3
"""A made-up Subsonic server with a big library, to stress the demo instance: scripts/big-server.py [port]

Run the app against it with MUSICSYNC_DEMO_SERVER=http://127.0.0.1:<port> (demo mode only).
Sizes (env): BIG_ARTISTS (2000), BIG_ALBUMS (5000), BIG_SONGS_PER_ALBUM (10), BIG_PLAYLISTS (500).
Playlist pl-0 holds 5000 songs, the others 50. Covers, streams and lyrics are missing."""
import json
import os
import sys
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
    artist = artists[a % ARTISTS]
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
    count = min(5000 if p == 0 else 50, len(songs))
    ids = [songs[(p * 997 + k * 31) % len(songs)]["id"] for k in range(count)]
    playlists.append({"id": f"pl-{p}", "name": name(p, 2) + " Mix", "owner": "demo", "public": False, "songCount": count,
                      "duration": sum(song_by_id[i]["duration"] for i in ids), "created": day(p), "changed": day(p), "ids": ids})


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
        return {"user": {"username": "demo", "adminRole": False, "streamRole": True, "playlistRole": True, "shareRole": False}}
    if method == "getOpenSubsonicExtensions":
        return {"openSubsonicExtensions": []}
    if method == "getPlayQueue":
        return {}
    if method in ("getCoverArt", "stream", "download", "getLyricsBySongId"):
        return None
    return {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        method = url.path.rsplit("/", 1)[-1].removesuffix(".view")
        body = reply(method, {k: v[0] for k, v in parse_qs(url.query).items()})
        if body is None or body is False:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps({"subsonic-response": {"status": "ok", "version": "1.16.1", "openSubsonic": True, **body}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = do_GET

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 4533
print(f"{len(artists)} artists, {len(albums)} albums, {len(songs)} songs, {len(playlists)} playlists on port {port}", flush=True)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
