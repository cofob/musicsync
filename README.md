<p align="center"><img src="docs/icon.png" width="128" alt="MusicSync icon"></p>

<h1 align="center">MusicSync</h1>

<p align="center">Native macOS music player for Navidrome / OpenSubsonic servers, with offline downloads and iPod classic sync.</p>

![MusicSync main window](docs/screenshot.webp)

<p>
  <img src="docs/nowplaying.webp" width="49%" alt="MusicSync Now Playing">
  <img src="docs/visualizer.webp" width="49%" alt="MusicSync visualizer">
</p>

## Features

- Browse and play your server library in an Apple Music–style window, with lyrics and a play queue.
- Gapless playback, crossfade and beat-matched AutoMix, a ten-band equalizer and ReplayGain.
- Winamp-style visualizer: spectrum, oscilloscope and MilkDrop presets, with synced lyrics; imports `.milk` presets.
- Save or share song files, original or converted to MP3 or AAC; share links that allow downloads.
- Made for You mixes, stations and AutoPlay from a local recommendation engine; listening stats.
- Smart playlists, podcasts, and offline downloads with smart download rules.
- Play on the server's jukebox, or control playback from iPhone, iPad and Apple Watch in a browser.
- MiniPlayer, menu bar player, Shortcuts and Siri actions, Spotlight and global shortcuts.
- Fast local mirror of the library, so search works at once, also offline.
- Sync albums, artists and playlists to an iPod classic with stock firmware: own iTunesDB writer with hash58, covers, playlists, gapless playback and Sound Check.
- Converts lossless files to AAC with Apple's encoder; MP3 and AAC are copied as they are.
- Keeps songs that iTunes or Finder put on the iPod, and does not add the same album twice.
- Sends plays from the iPod to the server as scrobbles.
- Rockbox presets (FLAC, Opus).

## Requirements

- macOS 15 or later, Apple silicon or Intel.
- Swift 6 toolchain: Xcode or the Command Line Tools (`xcode-select --install`).
- [ffmpeg](https://ffmpeg.org) for conversion: `brew install ffmpeg`.
- For sync: an iPod classic in disk mode. In Finder, turn off automatic sync and turn on manual management of music before the first sync.

## Build

```sh
swift build
swift test
./scripts/bundle.sh
```

`bundle.sh` makes a release build at `build/MusicSync.app` with an ad-hoc signature. `ARCHS="arm64 x86_64" ./scripts/bundle.sh` makes a universal app.

## Install

Install or update to the latest release from the terminal. The app is not notarized; a file downloaded with `curl` gets no quarantine flag, so Gatekeeper does not block it. A running copy quits first:

```sh
curl -fLo /tmp/MusicSync.zip https://github.com/cofob/musicsync/releases/latest/download/MusicSync.zip && { pkill -x MusicSyncApp; while pgrep -xq MusicSyncApp; do sleep 1; done; } && rm -rf /Applications/MusicSync.app && ditto -xk /tmp/MusicSync.zip /Applications && open /Applications/MusicSync.app
```

Or install your own build:

```sh
cp -R build/MusicSync.app /Applications/
open /Applications/MusicSync.app
```

If you download `MusicSync.zip` from [Releases](https://github.com/cofob/musicsync/releases) in a browser and macOS blocks it, run `xattr -dr com.apple.quarantine /Applications/MusicSync.app`.

Open Settings, enter your server address, user name and password, and click Save. The password is kept in the Keychain.

## License

[cofob.dev License](https://cofob.dev/license/): non-commercial use with credit. See [LICENSE](LICENSE).
