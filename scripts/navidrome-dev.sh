#!/bin/sh
# A throwaway local Navidrome with a small synthetic library: scripts/navidrome-dev.sh up|down|env
# up: makes the music (once), starts the container on 127.0.0.1:$PORT, creates the admin, a radio station, playlists,
# favorites and scans.
# down: removes the container and its data volume (the music stays in $DIR).
# env: prints the variables that point a demo instance at it.
# Env: DIR (default $TMPDIR/musicsync-navidrome), PORT (default 14533). Needs docker (PATH or ~/.orbstack/bin) and ffmpeg.
# The library: 40 albums of 8 quiet (-60 dB) sine songs in FLAC, MP3 and M4A with ReplayGain tags, covers on some,
# a compilation, two discs, Unicode names, synced .lrc lyrics and an 11-minute song. Sharing and the jukebox (to a null
# audio output) are on; external services are off. The admin password is a throwaway for this server only.
set -eu
PATH="$PATH:$HOME/.orbstack/bin"
IMAGE=deluan/navidrome:0.64.2
NAME=musicsync-navidrome
DIR="${DIR:-${TMPDIR:-/tmp}/musicsync-navidrome}"
PORT="${PORT:-14533}"
USER_NAME=admin
PASSWORD=musicsync-dev
URL="http://127.0.0.1:$PORT"

# One silent-level (-60 dB) sine file with tags: track <out> <seconds> <hz> <cover|-> key=value...
track() {
    out=$1 seconds=$2 hz=$3 cover=$4; shift 4
    for kv; do set -- "$@" -metadata "$kv"; shift; done
    if [ "$cover" = - ]; then
        ffmpeg -v error -y -f lavfi -i "sine=f=$hz:d=$seconds" -af volume=0.001 "$@" "$out"
    else
        ffmpeg -v error -y -f lavfi -i "sine=f=$hz:d=$seconds" -i "$cover" -map 0:a -map 1:v -c:v mjpeg \
            -disposition:v attached_pic -af volume=0.001 "$@" "$out"
    fi
}

music() {
    [ -f "$DIR/music/.done" ] && return
    rm -rf "$DIR/music"; mkdir -p "$DIR/music" "$DIR/covers"
    artists="Aurora Fields|Борис Гребенщиков|坂本 龍一|Céline Dupré|Echo Nordic|Zoë Kraft"
    genres="Ambient|Rock|Jazz|Electronic|Блюз"
    i=0
    while [ $i -lt 40 ]; do
        artist=$(echo "$artists" | cut -d'|' -f$((i % 6 + 1)))
        genre=$(echo "$genres" | cut -d'|' -f$((i % 5 + 1)))  # spread over the artists
        album="Album $((i + 1))"
        [ $i -eq 1 ] && album="Песни о главном"
        [ $i -eq 2 ] && album="夜の音楽"
        [ $i -eq 3 ] && album="Été à Paris"
        ext=$(echo "flac mp3 m4a" | cut -d' ' -f$((i % 3 + 1)))
        folder="$DIR/music/$artist/$album"
        mkdir -p "$folder"
        cover=-
        ffmpeg -v error -y -f lavfi -i "color=c=0x$(printf '%02x%02x%02x' $((i * 6)) $((200 - i * 5)) $((90 + i * 4))):s=600x600" \
            -frames:v 1 "$DIR/covers/$i.jpg"
        [ $((i % 2)) -eq 0 ] && cover="$DIR/covers/$i.jpg"
        [ $((i % 4)) -eq 1 ] && cp "$DIR/covers/$i.jpg" "$folder/cover.jpg"
        n=1
        while [ $n -le 8 ]; do
            disc=1 tn=$n tartist=$artist aartist=$artist comp=0
            # Album 5 has two discs; album 6 is a compilation.
            [ $i -eq 4 ] && { disc=$(( (n - 1) / 4 + 1 )); tn=$(( (n - 1) % 4 + 1 )); }
            [ $i -eq 5 ] && { tartist=$(echo "$artists" | cut -d'|' -f$((n % 6 + 1))); aartist="Various Artists"; comp=1; }
            seconds=$((20 + n * 3))
            # Album 1 is long enough to seek in (check:jukebox, check:nowplaying-lyrics) and ends with a song of 11 minutes.
            [ $i -eq 0 ] && seconds=$((180 + n * 3))
            [ $i -eq 0 ] && [ $n -eq 8 ] && seconds=660
            title="Song $n"
            [ $i -eq 1 ] && title="Песня $n"
            [ $i -eq 2 ] && title="曲 $n"
            [ $i -eq 7 ] && title="Night Drive $n"
            file="$folder/$disc-$(printf %02d $tn) $title.$ext"
            track "$file" $seconds $((220 + n * 20)) "$cover" "title=$title" "artist=$tartist" "album_artist=$aartist" \
                "album=$album" "track=$tn/$([ $i -eq 4 ] && echo 4 || echo 8)" "disc=$disc/$([ $i -eq 4 ] && echo 2 || echo 1)" \
                "date=$([ $i -eq 9 ] && echo 1965 || echo $((1990 + i)))" "genre=$genre" "compilation=$comp" \
                "REPLAYGAIN_TRACK_GAIN=-$((n % 5)).50 dB" "REPLAYGAIN_TRACK_PEAK=0.9$n" \
                "REPLAYGAIN_ALBUM_GAIN=-3.20 dB" "REPLAYGAIN_ALBUM_PEAK=0.98"
            if [ $i -eq 0 ] && [ $n -le 3 ]; then
                printf '[00:00.50]First line of song %s\n[00:04.00]Second line\n[00:08.00]Third line\n[00:12.00]Last line\n' \
                    $n >"${file%.*}.lrc"
            fi
            n=$((n + 1))
        done
        i=$((i + 1))
    done
    touch "$DIR/music/.done"
}

api() { curl -fsS "$URL/rest/$1?u=$USER_NAME&p=$PASSWORD&v=1.16.1&c=navidrome-dev&f=json${2:-}"; }

up() {
    music
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4533" -v "$DIR/music:/music:ro" -v "$NAME-data:/data" \
        -e ND_ENABLESHARING=true -e ND_JUKEBOX_ENABLED=true -e ND_LOGLEVEL=info -e ND_SCANNER_SCHEDULE=0 \
        -e ND_ENABLEEXTERNALSERVICES=false -e ND_ENABLEINSIGHTSCOLLECTOR=false \
        -e 'ND_MPVCMDTEMPLATE=mpv --ao=null --no-audio-display --pause %f --input-ipc-server=%s' \
        "$IMAGE" >/dev/null
    until curl -fsS "$URL/ping" >/dev/null 2>&1; do sleep 1; done
    curl -fsS -X POST "$URL/auth/createAdmin" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASSWORD\"}" >/dev/null 2>&1 || true
    api getInternetRadioStations | grep -q '"Dev Radio"' ||
        api createInternetRadioStation "&streamUrl=http://127.0.0.1:9/stream&name=Dev%20Radio&homepageUrl=http://127.0.0.1:9/" >/dev/null
    api startScan "&fullScan=true" >/dev/null
    while api getScanStatus | grep -q '"scanning":true'; do sleep 1; done
    # Two playlists of 24 and 6 songs and a few favorites (the long song among them), once per data volume.
    if ! api getPlaylists | grep -q '"Dev Mix"'; then
        ids=$(api search3 "&query=&songCount=30&artistCount=0&albumCount=0" | grep -o '"id":"[^"]*","parent"' | cut -d'"' -f4)
        api createPlaylist "&name=Dev%20Mix$(echo "$ids" | head -24 | sed 's/^/\&songId=/' | tr -d '\n')" >/dev/null
        api createPlaylist "&name=Короткий%20список$(echo "$ids" | tail -6 | sed 's/^/\&songId=/' | tr -d '\n')" >/dev/null
        api star "$(echo "$ids" | sed -n '1p;5p;9p' | sed 's/^/\&id=/' | tr -d '\n')" >/dev/null
        long=$(api search3 "&query=Song%208&songCount=500&artistCount=0&albumCount=0" | grep -o '"id":"[^"]*","parent"[^}]*"duration":660' | cut -d'"' -f4)
        api star "&id=$long" >/dev/null
    fi
    echo "$URL is up ($(api getScanStatus | sed 's/.*"count":\([0-9]*\).*/\1/') songs)"
}

down() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-data" >/dev/null 2>&1 || true
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    env) echo "MUSICSYNC_DEMO_SERVER=$URL MUSICSYNC_DEMO_USER=$USER_NAME MUSICSYNC_DEMO_PASSWORD=$PASSWORD" ;;
    *) echo "usage: $0 up|down|env" >&2; exit 2 ;;
esac
