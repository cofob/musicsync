import Foundation

enum Fixtures {
    static let artists = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.54.5 (abc123)","openSubsonic":true,
    "artists":{"ignoredArticles":"The El La Los Las Le Les","index":[
      {"name":"A","artist":[{"id":"ar-1","name":"Aphex Twin","albumCount":5,"musicBrainzId":"f22942a1-6f70-4f48-866e-238cb2308fbd","sortName":"aphex twin","coverArt":"ar-ar-1_65a1"}]},
      {"name":"B","artist":[{"id":"ar-2","name":"Björk","albumCount":3}]}]}}}
    """

    static let album = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.54.5","openSubsonic":true,
    "album":{"id":"al-1","name":"Selected Ambient Works 85-92","artist":"Aphex Twin","artistId":"ar-1","coverArt":"al-al-1_65a1",
      "songCount":2,"duration":600,"playCount":4,"created":"2024-02-01T10:00:00.123456789Z","year":1992,"genre":"Electronic",
      "musicBrainzId":"d1d5bbb5-1e7c-4a1d-8d7f-2a4f1c8f0aa1","isCompilation":false,"sortName":"selected ambient works 85-92","displayArtist":"Aphex Twin",
      "song":[
      {"id":"s-1","parent":"al-1","isDir":false,"title":"Xtal","album":"Selected Ambient Works 85-92","artist":"Aphex Twin","track":1,"year":1992,
       "genre":"Electronic","coverArt":"mf-s-1_65a1","size":31457280,"contentType":"audio/flac","suffix":"flac","duration":291,"bitRate":1411,
       "bitDepth":24,"samplingRate":96000,"channelCount":2,"path":"Aphex Twin/SAW/01 Xtal.flac","playCount":2,"discNumber":1,"created":"2024-02-01T10:00:00Z",
       "albumId":"al-1","artistId":"ar-1","type":"music","isVideo":false,"userRating":4,"starred":"2024-03-01T00:00:00Z",
       "musicBrainzId":"aaaa","replayGain":{"trackGain":-6.5,"albumGain":-7.25,"trackPeak":0.98,"albumPeak":1.0},
       "albumArtists":[{"id":"ar-1","name":"Aphex Twin"}],"displayAlbumArtist":"Aphex Twin","displayArtist":"Aphex Twin"},
      {"id":"s-2","parent":"al-1","title":"Heliosphan","album":"Selected Ambient Works 85-92","artist":"Aphex Twin","track":2,
       "size":9000000,"contentType":"audio/mpeg","suffix":"mp3","duration":309,"bitRate":320,"bitDepth":0,"samplingRate":44100,"channelCount":2,"albumId":"al-1"}]}}}
    """

    static let albumList = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","openSubsonic":true,
    "albumList2":{"album":[{"id":"al-1","name":"Selected Ambient Works 85-92","artist":"Aphex Twin","artistId":"ar-1","year":1992}]}}}
    """

    static let emptyAlbumList = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{}}}
    """

    static let playlists = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","playlists":{"playlist":[
      {"id":"pl-1","name":"Road trip","comment":"","owner":"demo","public":true,"songCount":12,"duration":3000,
       "created":"2024-01-01T00:00:00Z","changed":"2024-01-02T00:00:00Z","coverArt":"pl-pl-1"}]}}}
    """

    static let search = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
      "artist":[{"id":"ar-1","name":"Aphex Twin"}],
      "song":[{"id":"s-1","title":"Xtal","suffix":"flac"}]}}}
    """

    static let scanStatus = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","scanStatus":{"scanning":false,"count":1234,"folderCount":56,"lastScan":"2024-05-01T12:00:00Z"}}}
    """

    static let extensions = """
    {"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonic":true,"openSubsonicExtensions":[
      {"name":"transcodeOffset","versions":[1]},{"name":"formPost","versions":[1]}]}}
    """

    static let failed = """
    {"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome","serverVersion":"0.54.5","openSubsonic":true,
    "error":{"code":40,"message":"Wrong username or password"}}}
    """
}
