import QtQuick
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import PipMpv
import "../"

Item {
    id: window
    focus: true

    // Main.qml reads this to let the user drag/resize the shell window while a
    // video is up; it snaps back to the default layout geometry when this is false.
    readonly property bool windowMovable: window.currentView === "player"
    // Display aspect ratio of the playing video (0 = unknown). Main.qml sizes the
    // shell window to match this so the player has no letterboxing.
    property real videoAspect: 0

    Caching { id: paths }
    readonly property string moviesCache: paths.getCacheDir("movies")

    Scaler {
        id: scaler
        currentWidth: Screen.width
    }

    function s(val) { 
        return scaler.s(val); 
    }

    MatugenColors { id: _theme }
    readonly property color base: _theme.base
    readonly property color crust: _theme.crust
    readonly property color mantle: _theme.mantle
    readonly property color text: _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color mauve: _theme.mauve || "#cba6f7"
    readonly property color blue: _theme.blue || "#89b4fa"
    readonly property color green: _theme.green || "#a6e3a1"
    readonly property color red: _theme.red || "#f38ba8"

    // --- STATE MANAGEMENT ---
    property string currentView: "search" // "search", "series", "pip", "player"
    property string playerStatus: "" // overlay text shown while the player has no media

    // --- EMBEDDED PLAYER STATE (driven by a poll of the mpv item) ---
    property real playerPos: 0          // current time-pos (seconds)
    property real playerDur: 0          // duration (seconds)
    property bool playerPaused: false   // mpv pause state
    property bool seekDragging: false   // user is scrubbing the seek bar
    property string currentYtId: ""     // youtube id of what's playing (for comments)
    property string currentVideoChannel: ""      // channel of the playing video (up-next header)
    property string currentVideoChannelId: ""    // its channel id — channel-name links jump there
    property string currentVideoDate: ""         // relative upload date of the playing video
    property string heroArtUrl: ""                // current hero slide art (drives heroBackdrop)
    property string currentVideoDescription: ""  // description of the playing video
    // What's playing, for the comments source dispatch (youtube|movie|tv|anime).
    property string playerKind: ""
    property string playerImdb: ""
    property int playerSeason: 0
    property int playerEpisode: 0
    property bool commentsOpen: false   // right-side comments panel visible
    property bool commentsLoading: false
    property string commentsMsg: ""     // placeholder/empty message for the panel
    property bool playerFullscreen: false   // Main.qml expands the window to fill the screen
    property bool playerSettingsOpen: false // subtitles / speed / resolution menu
    property real playerSpeed: 1.0
    property bool subsOn: true
    // ── SponsorBlock skip system (YouTube) ──────────────────────────────────
    // Segments (sponsor/intro/outro/…) fetched per video; drawn on the seek
    // bar; auto-skipped on NATURAL forward entry only (once per segment — a
    // backward scrub marks everything ahead as "watching by choice" so nothing
    // yanks the playhead). Forward scrubs landing inside a segment snap to its
    // end. `autoSkip` is persisted alongside subsOn.
    property bool autoSkip: true
    property var sbSegments: []      // [{start,end,cat,skipped}]
    property real playerPrevPos: 0
    property real sbPosBeforeDrag: 0
    readonly property var sbCurrent: {
        if (window.playerKind !== "youtube") return null
        for (var i = 0; i < sbSegments.length; i++) {
            var sg = sbSegments[i]
            if (playerPos >= sg.start && playerPos < sg.end - 0.5) return sg
        }
        return null
    }
    function setAutoSkip(v) { window.autoSkip = v; saveUiState() }
    function fetchSbSegments(vid) {
        window.sbSegments = []
        if (!vid) return
        var xhr = new XMLHttpRequest()
        // Superset of the YouTubio config's categories (sponsor/selfpromo/preview)
        // + music_offtopic, which hits constantly on music-channel feeds.
        xhr.open("GET", "https://sponsor.ajay.app/api/skipSegments?videoID=" + encodeURIComponent(vid)
                 + '&categories=["sponsor","selfpromo","interaction","intro","outro","preview","music_offtopic"]')
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var arr = JSON.parse(xhr.responseText)
                var out = []
                for (var i = 0; i < arr.length; i++) {
                    var s = arr[i].segment
                    if (s && s.length === 2 && (s[1] - s[0]) >= 2)
                        out.push({ start: s[0], end: s[1], cat: arr[i].category || "segment", skipped: false })
                }
                out.sort(function(a, b) { return a.start - b.start })
                window.sbSegments = out
            } catch (e) {}
        }
        xhr.send()
    }
    // Preferred subtitle language (mpv slang + YouTube caption pull). Persisted.
    property string subLang: "en"
    readonly property var subLangChoices: [
        { key: "en", label: "English" }, { key: "ja", label: "日本語" },
        { key: "es", label: "Español" }, { key: "fr", label: "Français" },
        { key: "de", label: "Deutsch" }, { key: "any", label: "Any" }
    ]
    // Per language, the EXACT caption codes to request from YouTube and the
    // preference order for picking a loaded track. Order matters: native code
    // first, then -orig, regional variants, translated-from-English last.
    // Deliberately NO ".*" globs — "es.*" also matches every translated
    // permutation (es-en, es-ja, es-pt-BR …), which ballooned one video into
    // 30+ external subtitle URLs; mpv probes each at load, YouTube throttles,
    // and loads started failing with NO working subtitles at all.
    // 639-2 codes (eng/jpn/…) ride along for embedded MKV tracks (tv/anime).
    readonly property var subLangCodes: ({
        en: ["en", "eng", "en-orig", "en-US", "en-GB"],
        ja: ["ja", "jpn", "ja-orig", "ja-en"],
        es: ["es", "spa", "es-orig", "es-419", "es-ES", "es-en"],
        fr: ["fr", "fre", "fra", "fr-orig", "fr-FR", "fr-en"],
        de: ["de", "ger", "deu", "de-orig", "de-DE", "de-en"]
    })
    function setSubLang(code) {
        window.subLang = code
        applySubLangNow()   // one deterministic path — load-time slang is only a hint
        saveUiState()
    }
    // Deterministic subtitle-track selection — delegated to pip/sub_select.sh,
    // which reads track-list and sets the numeric sid over the IPC socket.
    // NOT done with embeddedMpv.getProperty: mpvqt's property marshalling
    // silently drops map values (setProperty of ytdl-raw-options stayed {}),
    // so trusting it to return track-list (a list of maps) is how the language
    // selector ended up doing nothing. The script path is verified end-to-end.
    // mpv's slang only applies at LOAD anyway (sid="auto" mid-file selects
    // nothing), so this is THE selection mechanism for load (player poll) and
    // mid-play switches alike — one path, every language.
    function applySubLangNow() {
        // Subs off → don't select or download anything; toggling them ON
        // calls this again (see subsOnToggle), so nothing is missed.
        if (!window.subsOn) return
        var codes = window.subLang === "any" ? "any"
                  : (window.subLangCodes[window.subLang] || [window.subLang]).join(",")
        Quickshell.execDetached(["bash", window.subSelectSh, codes])
    }
    function subLangLabel() {
        for (var i = 0; i < subLangChoices.length; i++)
            if (subLangChoices[i].key === window.subLang) return subLangChoices[i].label
        return "English"
    }
    property bool subAutoApplied: false     // per-file: poll already picked the sub track
    property int subApplyTicks: 0           // countdown to the late re-pick (straggler tracks)
    property string playerRes: "Auto"       // youtube quality cap
    property real _resumePos: 0             // restore position after a resolution reload
    // AI "parse this video" panel (transcript → local agent w/ web tools)
    property bool aiOpen: false
    property bool aiLoading: false
    property string aiText: ""
    property string aiMsg: ""
    property string mediaType: "movie" // section: "movie", "tv", "anime", "youtube"
    property string filterSort: "Default"

    // The active browse section IS the mediaType now: youtube | anime | tv | movie.
    // All four live inside the "search" view as grids driven by the top slider.
    readonly property string activeSection: window.mediaType
    readonly property color musicAccent: _theme.yellow || _theme.peach || "#f9e2af"
    readonly property color gamesAccent: _theme.sapphire || _theme.teal || "#74c7ec"
    readonly property color booksAccent: _theme.peach || _theme.rosewater || "#fab387"
    readonly property color sectionAccent: window.mediaType === "movie" ? window.mauve
        : window.mediaType === "tv" ? window.blue
        : window.mediaType === "anime" ? window.green
        : window.mediaType === "music" ? window.musicAccent
        : window.mediaType === "games" ? window.gamesAccent
        : window.mediaType === "books" ? window.booksAccent
        : window.red

    readonly property string pipDir: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip"
    // Unified video CLI (movies/video/video): every video op goes through this so
    // new sources are drop-in providers. See movies/BACKEND.md + video/README.md.
    readonly property string videoCli: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/video/video"
    readonly property string pipIpcSh: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/pip_ipc.sh"
    readonly property string subSelectSh: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/sub_select.sh"

    function selectSection(key) {
        window.currentView = "search"
        window.mediaType = key
        if (key === "youtube") {
            if (searchInput.text.trim() !== "") ytSearchDispatch(searchInput.text)
            else if (ytResults.count === 0 && window.ytView === "home") youtubeHomeFeed()
        } else if (key === "music") {
            if (window.subsonicReady && !window.musicLoaded) fetchMusicAlbums()
            if (searchInput.text.trim() !== "") musicSearch(searchInput.text)
        } else if (key === "games") {
            loadSteamGames(false)
        } else if (key === "books") {
            if (searchInput.text.trim() !== "") fetchBooks(searchInput.text)
            else if (!window.booksLoaded) fetchBooks("")
        } else {
            if (key === "anime" && !window.trendingAnimeLoaded) fetchTrendingAnime()
            if (key === "anime" && window.malReady && malModel.count === 0 && !window.malLoading) fetchMal(window.malStatus)
            if (searchInput.text.trim() !== "") doSearch(searchInput.text)
        }
        // Movies / TV / Anime are gated by the self-limit; evaluate on entry.
        if (window.gatedKeys.indexOf(key) >= 0) mediaGateEvaluate()
        else window.mediaGateOpen = false
        saveUiState()
    }

    // Tab order matches the slider: Music · Games · YouTube · Anime · TV · Movies.
    readonly property var sectionOrder: ["books", "music", "games", "youtube", "anime", "tv", "movie"]
    function cycleSection(step) {
        var vis = window.sectionOrder.filter(function (k) { return window.isSectionVisible(k) })
        if (vis.length === 0) return
        var i = vis.indexOf(window.mediaType)
        if (i < 0) i = 0
        selectSection(vis[(i + step + vis.length) % vis.length])
    }
    property bool isSearching: searchInput.text.trim() !== ""
    property bool isSearchingNetwork: false
    property bool isSearchMode: window.isSearching
    property string selectedImdbId: ""
    property string selectedTitle: ""
    property string selectedPoster: ""
    property string selectedDescription: ""
    property string selectedBackground: ""   // series banner art (meta background)
    // Series page: the synopsis is a DROPDOWN toggled by clicking the title.
    property bool selectedIsAnime: false
    property var seriesDataMap: ({})
    property int currentSeason: 1
    property bool isLoadingSeries: false
    property bool trendingMoviesLoaded: false
    property bool trendingTvLoaded: false
    property bool isFetchingMovies: false
    property bool isFetchingTv: false
    property bool isFetchingAnime: false
    property bool isLoadingPopular: isFetchingMovies || isFetchingTv || isFetchingAnime
    property var currentFetchResults: []
    property var rawTrendingMovies: []
    property var rawTrendingTv: []
    property var rawTrendingAnime: []
    property real trendingMoviesLastFetch: 0
    property real trendingTvLastFetch: 0
    property real trendingAnimeLastFetch: 0
    property bool trendingAnimeLoaded: false
    // YouTube search state — its own grid, no Cinemeta involvement.
    property bool isSearchingYt: false
    // YouTube source: YouTubio (self-hosted Stremio addon). yt-dlp direct search
    // was removed; comments still use yt-dlp via yt_comments.sh.
    property string ytSource: "youtubio"
    property string youtubioBase: "" // set from youtubio_url.txt (minus /manifest.json)
    readonly property bool youtubioReady: window.youtubioBase !== ""
    property var youtubioCatalogs: []   // [{id,name,searchable}] from the manifest
    property string youtubioCatalog: "" // currently-browsed catalog id
    // Browsable catalogs only (your channels/playlists) — search catalogs are
    // driven by the shared search box instead.
    readonly property var youtubioBrowseCatalogs: {
        var out = []
        for (var i = 0; i < youtubioCatalogs.length; i++) if (!youtubioCatalogs[i].searchable) out.push(youtubioCatalogs[i])
        return out
    }

    // ── YouTube home / subscriptions ────────────────────────────────────────
    // ytView drives the YouTube tab: "home" (algorithmic feed from your subs),
    // "videos" (a text search), "channels" (channel search to subscribe), or
    // "channel" (one channel's uploads).
    // ytView drives the YouTube tab. Top-level pages picked from the dropdown:
    //   "home" (algorithmic, unseen feed) · "channels" (people you follow) · "playlists"
    // Drill-downs: "channel" (one channel's videos) · "playlist" (one local playlist) ·
    // "videos" (a text search, which also surfaces channels).
    property string ytView: "home"
    property string ytSearchKind: "videos"   // legacy; kept for any stragglers
    property string ytChannelId: ""
    property string ytChannelName: ""
    property var youtubeSubs: []              // [{channelId, name, thumb}]
    property int ytHomePending: 0             // channels still loading for the home feed
    property var ytHomeBuffer: []             // merged videos awaiting shuffle

    // Algorithmic-home state: what you've already watched + whose stuff you watch.
    property var ytSeen: ({})                 // {vid:true} — hidden from Home ("never seen")
    property var ytWatchedChannels: []        // [{channelId,name}] — discovery beyond your subs
    // Local playlists (no YouTube account needed).
    property var ytPlaylists: []              // [{id,name,items:[{vid,title,channelId,thumb}]}]
    property string ytPlaylistId: ""
    property string ytPlaylistName: ""
    property string ytReturnView: "home"      // where a channel/playlist back-button returns to
    property var ytAddItem: ({})              // the video pending "add to playlist"
    property bool ytPlPickerOpen: false       // playlist picker overlay
    function ytOpenAddPicker(vid, title, channelId, channel, thumb) {
        window.ytAddItem = { vid: vid, title: title || vid, channelId: channelId || "", channel: channel || "", thumb: thumb || "" }
        window.ytPlPickerOpen = true
    }

    function isSubscribed(channelId) {
        for (var i = 0; i < youtubeSubs.length; i++) if (youtubeSubs[i].channelId === channelId) return true
        return false
    }
    function ytIsSeen(vid) { return window.ytSeen[vid] === true }
    function ytMarkSeen(vid, channelId, name) {
        if (vid && window.ytSeen[vid] !== true) {
            var s = window.ytSeen; s[vid] = true; window.ytSeen = s
            saveJsonToCache("qs_youtube_seen.json", s)
        }
        if (channelId && !isSubscribed(channelId)) {
            var arr = window.ytWatchedChannels.slice()
            for (var i = 0; i < arr.length; i++) if (arr[i].channelId === channelId) return
            arr.unshift({ channelId: channelId, name: name || channelId })
            window.ytWatchedChannels = arr.slice(0, 40)   // cap the discovery set
            saveJsonToCache("qs_youtube_watched_ch.json", { ch: window.ytWatchedChannels })
        }
    }
    // Channels that drive the Home feed: your subs ∪ channels you watch (deduped).
    function ytFeedChannels() {
        var out = [], seen = {}
        for (var i = 0; i < youtubeSubs.length; i++) {
            var s = youtubeSubs[i]; if (s.channelId && !seen[s.channelId]) { seen[s.channelId] = true; out.push(s) }
        }
        for (var j = 0; j < ytWatchedChannels.length; j++) {
            var w = ytWatchedChannels[j]; if (w.channelId && !seen[w.channelId]) { seen[w.channelId] = true; out.push(w) }
        }
        return out
    }
    // ── Local playlists ──
    function ytSavePlaylists() { saveJsonToCache("qs_youtube_playlists.json", { lists: window.ytPlaylists }) }
    function ytPlaylistCreate(name) {
        var arr = window.ytPlaylists.slice()
        arr.push({ id: "pl_" + Date.now(), name: (name && name.trim()) || "New playlist", items: [] })
        window.ytPlaylists = arr; ytSavePlaylists()
    }
    function ytPlaylistDelete(id) {
        window.ytPlaylists = window.ytPlaylists.filter(function (p) { return p.id !== id }); ytSavePlaylists()
        if (window.ytPlaylistId === id) { window.ytView = "playlists"; window.ytPlaylistId = "" }
    }
    function ytPlaylistAdd(id, item) {
        var arr = window.ytPlaylists.slice()
        for (var i = 0; i < arr.length; i++) {
            if (arr[i].id !== id) continue
            for (var j = 0; j < arr[i].items.length; j++) if (arr[i].items[j].vid === item.vid) return  // dedupe
            arr[i].items = arr[i].items.concat([item])
            window.ytPlaylists = arr; ytSavePlaylists()
            Quickshell.execDetached(["notify-send", "Added to " + arr[i].name, item.title || item.vid])
            return
        }
    }
    function ytPlaylistOpen(id) {
        for (var i = 0; i < window.ytPlaylists.length; i++) {
            if (window.ytPlaylists[i].id !== id) continue
            window.ytReturnView = "playlists"; window.ytView = "playlist"
            window.ytPlaylistId = id; window.ytPlaylistName = window.ytPlaylists[i].name
            ytChannels.clear(); ytResults.clear(); searchInput.text = ""
            var items = window.ytPlaylists[i].items
            // Older saved playlists predate duration/dateStr — default the roles so
            // the ListModel's role set stays consistent regardless of append order.
            for (var j = 0; j < items.length; j++)
                ytResults.append(Object.assign({ duration: "", dateStr: "" }, items[j]))
            return
        }
    }
    // Channels page: show the people you follow as channel cards.
    function ytShowSubscribedChannels() {
        window.ytView = "channels"
        window.ytChannelsIsSubs = true
        ytResults.clear(); ytChannels.clear(); searchInput.text = ""
        for (var i = 0; i < youtubeSubs.length; i++)
            ytChannels.append({ channelId: youtubeSubs[i].channelId, name: youtubeSubs[i].name, thumb: youtubeSubs[i].thumb || "" })
        ytSubsFeedFetch()
    }
    // ── Subscriptions feed: every subscribed channel's uploads, newest first ──
    // (the Channels page main area; the channel rail sits to its left).
    property bool ytChannelsIsSubs: true   // false = channel SEARCH results (card grid)
    property int ytSubsPending: 0
    property var ytSubsBuffer: []
    ListModel { id: ytSubsVideos }
    function ytSubsFeedFetch() {
        ytSubsVideos.clear()
        window.ytSubsBuffer = []
        if (!window.youtubioReady || youtubeSubs.length === 0) return
        window.isSearchingYt = true
        window.ytSubsPending = youtubeSubs.length
        for (var i = 0; i < youtubeSubs.length; i++) {
            (function(sub) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", window.youtubioBase + "/catalog/YouTube/yt_id:" + encodeURIComponent(sub.channelId) + ".json")
                xhr.onerror = function() {
                    if (--window.ytSubsPending <= 0) { window.isSearchingYt = false; ytSubsFeedFlush() }
                }
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== XMLHttpRequest.DONE) return
                    if (xhr.status === 200) {
                        try {
                            var ms = (JSON.parse(xhr.responseText).metas) || []
                            var buf = window.ytSubsBuffer.slice()
                            for (var j = 0; j < Math.min(ms.length, 25); j++) {
                                var vid = (ms[j].id || "").replace(/^yt_id:/, "")
                                if (!vid) continue
                                buf.push({ vid: vid, title: ms[j].name || vid, channel: sub.name, channelId: sub.channelId,
                                           duration: ms[j].runtime || "", dateStr: ytRelDate(ms[j].released || ""),
                                           thumb: ms[j].poster || "", relTs: Date.parse(ms[j].released || "") || 0 })
                            }
                            window.ytSubsBuffer = buf
                        } catch(e) {}
                    }
                    if (--window.ytSubsPending <= 0) { window.isSearchingYt = false; ytSubsFeedFlush() }
                }
                xhr.send()
            })(youtubeSubs[i])
        }
    }
    function ytSubsFeedFlush() {
        // Merge all channels newest-first (real upload dates), dedup collabs.
        var arr = window.ytSubsBuffer.slice()
        arr.sort(function(a, b) { return b.relTs - a.relTs })
        var have = {}
        ytSubsVideos.clear()
        for (var n = 0; n < arr.length; n++)
            if (arr[n].vid && !have[arr[n].vid]) { have[arr[n].vid] = true; ytSubsVideos.append(arr[n]) }
    }
    // Dropdown navigation between the three top-level YouTube pages.
    function ytGoPage(page) {
        searchInput.text = ""
        window.ytMoreDone = false; window.ytMoreLoading = false
        if (page === "home") { window.ytView = "home"; if (ytResults.count === 0) youtubeHomeFeed() }
        else if (page === "channels") ytShowSubscribedChannels()
        else if (page === "playlists") { window.ytView = "playlists"; ytResults.clear(); ytChannels.clear() }
        else if (page === "history") { window.ytView = "history"; ytResults.clear(); ytChannels.clear(); ytLoadHistory() }
    }

    // ── Infinite scroll: pull more videos when the grid reaches its end ─────
    // home  → reveals more of the prefetched per-channel buffer (no network);
    // search/channel → next skip= page of the YouTubio catalog.
    property bool ytMoreLoading: false
    property bool ytMoreDone: false
    property string ytLastQuery: ""
    property var ytHomeExtra: []   // per-channel items beyond the first 8, revealed on scroll
    function ytLoadMore() {
        if (window.mediaType !== "youtube" || window.isSearchingYt) return
        if (window.ytMoreLoading || window.ytMoreDone || ytResults.count === 0) return
        var have = {}
        for (var m = 0; m < ytResults.count; m++) have[ytResults.get(m).vid] = true
        if (window.ytView === "home") {
            var ex = window.ytHomeExtra
            if (ex.length === 0) { window.ytMoreDone = true; return }
            var rest = [], took = 0
            for (var i = 0; i < ex.length; i++) {
                if (took < 24 && ex[i].vid && !have[ex[i].vid]) {
                    have[ex[i].vid] = true
                    ytResults.append(Object.assign({ duration: "", dateStr: "" }, ex[i]))
                    took++
                } else if (took >= 24) {
                    rest.push(ex[i])
                }
            }
            window.ytHomeExtra = rest
            if (rest.length === 0 && took === 0) window.ytMoreDone = true
            return
        }
        var url = ""
        if (window.ytView === "videos" && window.ytLastQuery !== "")
            url = window.youtubioBase + "/catalog/YouTube/yt_id::ytsearch/search=" + encodeURIComponent(window.ytLastQuery) + "&skip=" + ytResults.count + ".json"
        else if (window.ytView === "channel" && window.ytChannelId !== "")
            url = window.youtubioBase + "/catalog/YouTube/yt_id:" + encodeURIComponent(window.ytChannelId) + "/skip=" + ytResults.count + ".json"
        else return
        window.ytMoreLoading = true
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.ytMoreLoading = false; window.ytMoreDone = true }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.ytMoreLoading = false
            if (xhr.status !== 200) { window.ytMoreDone = true; return }
            var added = 0
            try {
                var ms = (JSON.parse(xhr.responseText).metas) || []
                for (var j = 0; j < ms.length; j++) {
                    var vid = (ms[j].id || "").replace(/^yt_id:/, "")
                    if (!vid || have[vid]) continue
                    have[vid] = true
                    var ch = ytMetaChannel(ms[j])
                    ytResults.append({ vid: vid, title: ms[j].name || vid,
                                       channel: ch.name || window.ytChannelName, channelId: ch.id || window.ytChannelId,
                                       duration: ms[j].runtime || "", dateStr: ytRelDate(ms[j].released || ""),
                                       thumb: ms[j].poster || "" })
                    added++
                }
            } catch (e) {}
            if (added === 0) window.ytMoreDone = true   // catalog exhausted
        }
        xhr.send()
    }
    // Full video watch history — EVERY video you play (kept, no cap), stored separately
    // from the capped (500) AI-summary history. The History page merges them: all videos,
    // with the AI summary attached where one exists.
    property var ytWatchHistory: []   // [{vid,title,channel,ts}] newest-first, deduped by vid
    Process {
        id: ytWatchHistProc; running: true
        // NB: must read the SAME file saveJsonToCache writes (moviesCache) — the
        // old ~/.cache path never existed, so every session booted with an empty
        // list and the next save wiped the real history.
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_yt_watch_history.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(this.text || "{}"); if (d.items) window.ytWatchHistory = d.items } catch (e) {} } }
    }
    function ytRecordWatch(vid, title, channel, channelId) {
        if (!vid) return
        var arr = window.ytWatchHistory.filter(function (e) { return e.vid !== vid })   // dedupe, newest wins
        arr.unshift({ vid: vid, title: title || vid, channel: channel || "",
                      cid: channelId || "", ts: Math.floor(Date.now() / 1000) })
        window.ytWatchHistory = arr.slice(0, 5000)   // keep essentially all
        saveJsonToCache("qs_yt_watch_history.json", { items: window.ytWatchHistory })
    }

    // History page model: all watched videos (newest first), AI summary where available.
    ListModel { id: ytHistoryModel }
    property bool ytHistoryLoading: false
    function ytLoadHistory() { window.ytHistoryLoading = true; ytHistoryProc.running = false; ytHistoryProc.running = true }
    Process {
        id: ytHistoryProc
        command: ["bash", "-c", "python3 -c '" +
            "import json,os\n" +
            "def L(p):\n" +
            " try: return json.load(open(os.path.expanduser(p)))\n" +
            " except Exception: return []\n" +
            "w=L(\"" + window.moviesCache + "/qs_yt_watch_history.json\")\n" +
            "w=w.get(\"items\",[]) if isinstance(w,dict) else (w if isinstance(w,list) else [])\n" +
            "s=L(\"~/.cache/qs_ai_history.json\")\n" +
            "sm={e.get(\"vid\"):e.get(\"summary\",\"\") for e in (s if isinstance(s,list) else []) if e.get(\"vid\")}\n" +
            "out=[{\"vid\":e.get(\"vid\",\"\"),\"title\":e.get(\"title\",\"\"),\"channel\":e.get(\"channel\",\"\"),\"cid\":e.get(\"cid\",\"\"),\"summary\":sm.get(e.get(\"vid\",\"\"),\"\"),\"ts\":e.get(\"ts\",0)} for e in w]\n" +
            "print(json.dumps(out))' 2>/dev/null || echo '[]'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                ytHistoryModel.clear()
                var arr = []
                try { arr = JSON.parse((this.text || "[]").trim() || "[]") } catch (e) { arr = [] }
                for (var i = 0; i < arr.length; i++) {   // already newest-first
                    var e = arr[i]
                    ytHistoryModel.append({ vid: e.vid || "", title: e.title || "Untitled", channel: e.channel || "",
                                            cid: e.cid || "", summary: e.summary || "", ts: e.ts || 0 })
                }
                window.ytHistoryLoading = false
            }
        }
    }
    function subscribeChannel(channelId, name, thumb) {
        if (!channelId || isSubscribed(channelId)) return
        var arr = youtubeSubs.slice()
        arr.push({ channelId: channelId, name: name || channelId, thumb: thumb || "" })
        window.youtubeSubs = arr
        saveJsonToCache("qs_youtube_subs.json", { subs: arr })
        invalidateYoutubeHomeCache()
    }
    function unsubscribeChannel(channelId) {
        var arr = []
        for (var i = 0; i < youtubeSubs.length; i++) if (youtubeSubs[i].channelId !== channelId) arr.push(youtubeSubs[i])
        window.youtubeSubs = arr
        saveJsonToCache("qs_youtube_subs.json", { subs: arr })
        invalidateYoutubeHomeCache()
    }
    // Drop the cached home feed so a sub/unsub is reflected on the next open.
    function invalidateYoutubeHomeCache() {
        Quickshell.execDetached(["bash", "-c", "rm -f " + window.moviesCache + "/qs_youtube_home.json"])
    }

    // Extract {name,id} of a video meta's channel from its Stremio links.
    function ytMetaChannel(meta) {
        var out = { name: "", id: "" }
        var links = meta.links || []
        for (var i = 0; i < links.length; i++) {
            if (links[i].category === "Directors") {
                out.name = links[i].name || ""
                var u = links[i].url || ""
                var seg = u.split("/").pop()           // encoded "yt_id:UC..."
                try { out.id = decodeURIComponent(seg).replace(/^yt_id:/, "") } catch(e) { out.id = "" }
                break
            }
        }
        return out
    }

    // ── Music (Navidrome via the Subsonic API) ──────────────────────────────
    property string navidromeUrl: ""    // e.g. https://music.example.com (no trailing /)
    property string navidromeUser: ""
    property string navidromePass: ""
    readonly property bool subsonicReady: navidromeUrl !== "" && navidromeUser !== "" && navidromePass !== ""

    // ── Kavita (manga + novels reading library) ──
    // Browse-only front end: surfaces ONLY manga/novel libraries (filtered in
    // kavita_fetch.py). Clicking a series opens it in the Kavita web reader,
    // which handles both image (manga) and EPUB (novel) reading uniformly.
    property string kavitaUrl: "http://localhost:5000"
    property string kavitaKey: ""
    readonly property bool kavitaReady: kavitaUrl !== "" && kavitaKey !== ""
    property bool booksLoaded: false
    property bool booksLoading: false
    property bool isSearchingBooks: false

    // ── MyAnimeList (mal-better-stremio addon) ──
    // Browse your MAL lists (watching / plan / completed / on hold / dropped) in
    // the anime section, with a slider to switch lists. malAddonUrl is the
    // configured addon base ending in your user id (…/<user_id>); the trailing
    // /manifest.json, if pasted, is stripped. malToken (optional, write scope)
    // lets the flip-card status buttons actually move entries between lists.
    property string malAddonUrl: ""
    property string malToken: ""
    readonly property bool malReady: malAddonUrl !== ""
    property string malStatus: "watching"   // which MAL list the row shows
    property bool malLoading: false
    property string malError: ""             // "" | "fetch"
    readonly property var malStatuses: [
        { key: "watching",      label: "Watching" },
        { key: "plan_to_watch", label: "Plan to Watch" },
        { key: "completed",     label: "Completed" },
        { key: "on_hold",       label: "On Hold" },
        { key: "dropped",       label: "Dropped" }
    ]
    // Subsonic token auth: token = md5(password + salt). Salt is generated once.
    readonly property string subsonicSalt: Math.random().toString(36).slice(2, 14)
    readonly property string subsonicToken: subsonicReady ? Qt.md5(navidromePass + subsonicSalt) : ""
    property bool musicLoaded: false
    property bool isSearchingMusic: false
    property string selectedAlbumId: ""
    property string selectedAlbumName: ""
    property string selectedAlbumArtist: ""
    property string selectedAlbumCover: ""

    // Build an authenticated Subsonic REST URL.
    function subsonicUrl(method, extra) {
        return window.navidromeUrl + "/rest/" + method + "?u=" + encodeURIComponent(window.navidromeUser)
            + "&t=" + window.subsonicToken + "&s=" + window.subsonicSalt
            + "&v=1.16.1&c=qsmovies&f=json" + (extra ? "&" + extra : "")
    }
    function subsonicCoverUrl(coverId, size) {
        if (!coverId) return ""
        return subsonicUrl("getCoverArt", "id=" + encodeURIComponent(coverId) + "&size=" + (size || 300))
    }
    function subsonicStreamUrl(songId) {
        return subsonicUrl("stream", "id=" + encodeURIComponent(songId))
    }

    // Whether the centered loading spinner should cover the content area.
    readonly property bool showLoadingOverlay: window.mediaType === "youtube"
        ? window.isSearchingYt
        : window.mediaType === "music"
        ? window.isSearchingMusic
        : (window.isSearchingNetwork || (!window.isSearchMode && window.isLoadingPopular))
    readonly property real trendingCacheMaxAge: 12 * 60 * 60 * 1000
    property bool seasonSwitching: false
    property bool stateRestored: false
    property bool pendingSeriesFocusRestore: false

    Timer {
        id: safetyLoadingTimer
        interval: 12000
        running: window.isLoadingPopular || window.isSearchingNetwork || window.isSearchingYt
        repeat: false
        onTriggered: {
            window.isFetchingMovies = false
            window.isFetchingTv = false
            window.isFetchingAnime = false
            window.isSearchingNetwork = false
            window.isSearchingYt = false
        }
    }

    Timer {
        id: searchDebounceTimer
        interval: 400
        repeat: false
        onTriggered: {
            if (searchInput.text.trim() !== "") {
                runSearch(searchInput.text)
            }
        }
    }

    Timer {
        id: seriesFocusRestoreTimer
        interval: 350
        repeat: false
        onTriggered: {
            if (window.currentView === "series") {
                window.forceActiveFocus()
                window.pendingSeriesFocusRestore = false
            }
        }
    }

    // --- SHARED DISK I/O HELPER ---
    function saveJsonToCache(filename, dataObj) {
        // Pass the JSON as an ARGUMENT — no shell quoting to escape (the old
        // single-quote splice was escaped correctly, but printf "$1" removes
        // the quoting question entirely and echo's escape pitfalls with it).
        Quickshell.execDetached(["bash", "-c", 'printf %s "$1" > ' + window.moviesCache + "/" + filename, "_", JSON.stringify(dataObj)])
    }

    // ── Personal Library (MAL-style watchlist for movies + TV + anime) ──────────
    // A local watchlist using the SAME statuses as the MAL anime lists, but for any
    // item, persisted to qs_library.json. libraryAll = the whole list; libraryModel
    // = the current-status slice shown in the Library browse. libStatus = the
    // browse filter (keys match window.malStatuses).
    function libSaveAll() { saveJsonToCache("qs_library.json", window.libraryAll) }
    function libIndexOf(imdbId) {
        for (var i = 0; i < window.libraryAll.length; i++)
            if (window.libraryAll[i].imdbId === imdbId) return i
        return -1
    }
    function libStatusOf(imdbId) { var i = libIndexOf(imdbId); return i >= 0 ? window.libraryAll[i].status : "" }
    function libInLibrary(imdbId) { return libIndexOf(imdbId) >= 0 }
    function libLabel(key) {
        for (var i = 0; i < window.malStatuses.length; i++)
            if (window.malStatuses[i].key === key) return window.malStatuses[i].label
        return key
    }
    function libRefreshModel() {
        libraryModel.clear()
        for (var i = window.libraryAll.length - 1; i >= 0; i--) {   // newest first
            var e = window.libraryAll[i]
            if (e.status === window.libStatus) libraryModel.append(e)
        }
    }
    function libSet(item, status, quiet) {
        if (!item || !item.imdbId) return
        var arr = window.libraryAll.slice()
        var i = libIndexOf(item.imdbId)
        var kind = item.type || (window.mediaType === "movie" ? "movie"
                   : (window.selectedIsAnime ? "anime" : "series"))
        var entry = { imdbId: item.imdbId, type: kind, title: item.title || "",
                      poster: item.poster || "", status: status, ts: Date.now() }
        if (i >= 0) arr[i] = entry; else arr.push(entry)
        window.libraryAll = arr
        libSaveAll(); libRefreshModel()
        // quiet = automatic shelving (auto-Watching on play etc.) — no toast spam.
        if (!quiet) Quickshell.execDetached(["notify-send", "Library",
            (i >= 0 ? "Updated: " : "Added: ") + entry.title + " → " + libLabel(status)])
    }
    function libRemove(imdbId) {
        var i = libIndexOf(imdbId); if (i < 0) return
        var arr = window.libraryAll.slice(); var t = arr[i].title; arr.splice(i, 1)
        window.libraryAll = arr; libSaveAll(); libRefreshModel()
        Quickshell.execDetached(["notify-send", "Library", "Removed: " + t])
    }
    function libToggle(item) {   // card bookmark: in → remove; out → add as Plan to Watch
        if (!item || !item.imdbId) return
        if (libIndexOf(item.imdbId) >= 0) libRemove(item.imdbId)
        else libSet(item, "plan_to_watch")
    }
    function libSetBrowseStatus(key) { window.libStatus = key; libRefreshModel() }
    function openLibrary() {
        window.currentView = "search"
        readLibraryProc.running = true    // refresh from disk
        window.libraryOpen = true
    }

    // --- PERSISTENT CACHE IO ---
    Process {
        id: readHistoryProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_movie_history.json 2>/dev/null || echo '[]'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let parsed = JSON.parse(data.trim())
                    searchHistoryModel.clear()
                    for (let i = parsed.length - 1; i >= 0; i--) {
                        searchHistoryModel.insert(0, { query: parsed[i] })
                    }
                } catch(e) {}
            }
        }
    }

    Process {
        id: readWatchHistoryProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_movie_watch_history.json 2>/dev/null || echo '[]'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let parsed = JSON.parse(data.trim())
                    watchHistoryModel.clear()
                    for (let i = parsed.length - 1; i >= 0; i--) {
                        watchHistoryModel.insert(0, parsed[i])
                    }
                } catch(e) {}
            }
        }
    }

    function processTrendingCache(parsed, typeStr, targetModel) {
        let now = Date.now()
        let isMovie = typeStr === "movie"
        let lastFetch = parsed[isMovie ? "moviesLastFetch" : "tvLastFetch"] || 0
        let items = parsed[isMovie ? "movies" : "tv"]

        if (items && items.length > 0) {
            targetModel.clear()
            if (isMovie) window.rawTrendingMovies = items; else window.rawTrendingTv = items
            for (let i = 0; i < items.length; i++) targetModel.append(items[i])
            
            if (isMovie) { window.trendingMoviesLoaded = true; window.isFetchingMovies = false; window.trendingMoviesLastFetch = lastFetch } 
            else { window.trendingTvLoaded = true; window.isFetchingTv = false; window.trendingTvLastFetch = lastFetch }
            
            if ((now - lastFetch) > window.trendingCacheMaxAge) fetchTrending(typeStr === "movie" ? "movie" : "series")
        } else {
            fetchTrending(typeStr === "movie" ? "movie" : "series")
        }
    }

    Process {
        id: readTrendingCacheProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_trending_cache.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let parsed = JSON.parse(data.trim())
                    processTrendingCache(parsed, "movie", cachedTrendingMovies)
                    processTrendingCache(parsed, "tv", cachedTrendingTv)
                } catch(e) {
                    fetchTrending("movie")
                    fetchTrending("series")
                }
            }
        }
    }

    Process {
        id: readUiStateProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_ui_state.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let s = JSON.parse(data.trim())
                    if (!s || Object.keys(s).length === 0) {
                        window.stateRestored = true
                        return
                    }
                    if (s.mediaType) window.mediaType = s.mediaType
                    if (s.filterSort) {
                        window.filterSort = s.filterSort
                        let idx = filterSelector.model.indexOf(s.filterSort)
                        if (idx >= 0) filterSelector.currentIndex = idx
                    }
                    if (s.searchText && s.searchText !== "") searchInput.text = s.searchText
                    // Anime/YouTube used to be separate views; they're now sections
                    // (mediaType) inside the search view. Migrate any old saved state.
                    if (s.currentView === "anime") { window.mediaType = "anime"; window.currentView = "search" }
                    else if (s.currentView === "youtube") { window.mediaType = "youtube"; window.currentView = "search" }
                    // Transient views (a playing track / an open album) shouldn't be
                    // restored cold with no data — fall back to the browse grid.
                    else if (s.currentView === "album" || s.currentView === "player") window.currentView = "search"
                    else if (s.currentView) window.currentView = s.currentView
                    if (s.selectedImdbId) window.selectedImdbId = s.selectedImdbId
                    if (s.selectedTitle) window.selectedTitle = s.selectedTitle
                    if (s.selectedPoster) window.selectedPoster = s.selectedPoster
                    if (s.selectedDescription) window.selectedDescription = s.selectedDescription
                    if (s.selectedBackground) window.selectedBackground = s.selectedBackground
                    window.selectedIsAnime = s.selectedIsAnime === true
                    if (s.currentSeason) window.currentSeason = s.currentSeason
                    if (s.subLang) window.subLang = s.subLang
                    if (s.subsOn !== undefined) window.subsOn = s.subsOn === true
                    if (s.autoSkip !== undefined) window.autoSkip = s.autoSkip === true
                    if (s.animeDub !== undefined) window.animeDub = s.animeDub === true

                    if (s.currentView === "series" && s.selectedImdbId) {
                        window.pendingSeriesFocusRestore = true
                        fetchSeriesData(s.selectedImdbId, s.currentSeason || 1, "", "", true)
                    }
                    // Now that mediaType is restored, load the section's feed so it's not blank
                    // on open (the onVisibleChanged check can run before this restore completes).
                    if (window.mediaType === "youtube" && window.currentView === "search"
                            && window.ytView === "home" && ytResults.count === 0)
                        youtubeHomeFeed()
                    else if (window.mediaType === "games" && window.currentView === "search" && gamesModel.count === 0)
                        loadSteamGames(false)
                    window.stateRestored = true
                } catch(e) {
                    window.stateRestored = true
                }
            }
        }
    }

    // --- SAVING CACHE FUNCTIONS ---
    function saveUiState() {
        saveJsonToCache("qs_ui_state.json", {
            mediaType: window.mediaType, filterSort: window.filterSort, searchText: searchInput.text,
            currentView: window.currentView, selectedImdbId: window.selectedImdbId,
            selectedTitle: window.selectedTitle, selectedPoster: window.selectedPoster,
            selectedDescription: window.selectedDescription, selectedBackground: window.selectedBackground,
            currentSeason: window.currentSeason,
            selectedIsAnime: window.selectedIsAnime, subLang: window.subLang,
            subsOn: window.subsOn, autoSkip: window.autoSkip, animeDub: window.animeDub
        })
    }

    function saveHistory() {
        let arr = []
        for (let i = 0; i < searchHistoryModel.count; i++) arr.push(searchHistoryModel.get(i).query)
        saveJsonToCache("qs_movie_history.json", arr)
    }

    function saveWatchHistory() {
        let arr = []
        for (let i = 0; i < watchHistoryModel.count; i++) {
            let item = watchHistoryModel.get(i)
            arr.push({ imdbId: item.imdbId, title: item.title, poster: item.poster, type: item.type,
                       season: item.season || 0, ep: item.ep || 0 })
        }
        saveJsonToCache("qs_movie_watch_history.json", arr)
    }

    function saveTrendingCache() {
        if (cachedTrendingMovies.count === 0 || cachedTrendingTv.count === 0) return
        let cacheObj = { moviesLastFetch: window.trendingMoviesLastFetch, tvLastFetch: window.trendingTvLastFetch, movies: [], tv: [] }
        for (let i = 0; i < cachedTrendingMovies.count; i++) {
            let m = cachedTrendingMovies.get(i)
            cacheObj.movies.push({ imdbId: m.imdbId, title: m.title, poster: m.poster, type: m.type, year: m.year, rating: parseFloat(m.rating) || 0, popularity: i })
        }
        for (let i = 0; i < cachedTrendingTv.count; i++) {
            let t = cachedTrendingTv.get(i)
            cacheObj.tv.push({ imdbId: t.imdbId, title: t.title, poster: t.poster, type: t.type, year: t.year, rating: parseFloat(t.rating) || 0, popularity: i })
        }
        saveJsonToCache("qs_trending_cache.json", cacheObj)
    }

    // --- ANIMATIONS & FOCUS ---
    property real introPhase: 0
    NumberAnimation on introPhase {
        id: introPhaseAnim
        from: 0; to: 1; duration: 800; easing.type: Easing.OutQuart; running: true
    }

    Timer {
        id: focusTimer
        interval: 50; running: true; repeat: false
        onTriggered: {
            if (window.currentView === "search") searchInput.forceActiveFocus()
            else window.forceActiveFocus()
        }
    }

    Timer {
        id: scrollToTopTimer
        interval: 80; running: false; repeat: false
        onTriggered: {
            movieGrid.positionViewAtBeginning()
            tvGrid.positionViewAtBeginning()
            animeGrid.positionViewAtBeginning()
            searchGrid.positionViewAtBeginning()
        }
    }

    Component.onCompleted: {
        readHistoryProc.running = true
        readWatchHistoryProc.running = true
        readLibraryProc.running = true
        window.isFetchingMovies = true
        window.isFetchingTv = true
        window.isFetchingAnime = true
        readTrendingCacheProc.running = true
        readAnimeCacheProc.running = true
        readUiStateProc.running = true
        readYoutubioUrlProc.running = true
    }

    Connections {
        target: window
        function onVisibleChanged() {
            if (window.visible) {
                introPhaseAnim.restart()
                if (window.currentView === "search") {
                    focusTimer.restart()
                    scrollToTopTimer.restart()
                } else if (window.currentView === "series") {
                    seriesFocusRestoreTimer.restart()
                }
                if (searchHistoryModel.count === 0) readHistoryProc.running = true
                if (watchHistoryModel.count === 0) readWatchHistoryProc.running = true
                if (!window.trendingMoviesLoaded) fetchTrending("movie")
                if (!window.trendingTvLoaded) fetchTrending("series")
                if (!window.trendingAnimeLoaded) fetchTrendingAnime()
                if (searchInput.text !== "") runSearch(searchInput.text)
                // Opening on the YouTube tab: load its feed straight away (cache-first → instant).
                if (window.mediaType === "youtube" && window.currentView === "search"
                        && window.ytView === "home" && ytResults.count === 0)
                    youtubeHomeFeed()
                // Opening on the Games tab (gaming mode): make sure the library is loaded.
                if (window.mediaType === "games" && window.currentView === "search" && gamesModel.count === 0)
                    loadSteamGames(false)
                if (window.currentView === "series" && window.selectedImdbId !== "" && episodeModel.count === 0) {
                    fetchSeriesData(window.selectedImdbId, window.currentSeason, "", "", true)
                }
            } else {
                saveUiState()
            }
        }
    }

    Keys.onPressed: (event) => {
        // Watch-limit wheel is modal: arrow keys move it, Enter confirms, Esc leaves.
        if (window.mediaGateOpen && !window.mediaIsLocked()) {
            if (event.key === Qt.Key_Left)       { epWheel.decrementCurrentIndex(); event.accepted = true }
            else if (event.key === Qt.Key_Right) { epWheel.incrementCurrentIndex(); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { window.mediaChooseAllowance(epWheel.currentIndex + 1); event.accepted = true }
            else if (event.key === Qt.Key_Escape) { window.mediaGateOpen = false; selectSection(window.focusMode === "gaming" ? "games" : "youtube"); event.accepted = true }
            else event.accepted = true   // swallow the rest while the gate is up
            return
        }
        if (window.currentView === "series") {
            if (event.key === Qt.Key_Escape) {
                window.currentView = "search"
                searchInput.forceActiveFocus()
                event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                let sCount = seasonModel.count
                if (sCount > 0) {
                    let idx = -1
                    for (let i = 0; i < sCount; i++) { if (seasonModel.get(i).seasonNum === window.currentSeason) { idx = i; break } }
                    if (idx !== -1) {
                        let step = event.key === Qt.Key_Tab ? 1 : -1
                        window.currentSeason = seasonModel.get((idx + step + sCount) % sCount).seasonNum
                        updateEpisodes(window.currentSeason)
                    }
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                if (epList.currentIndex < epList.count - 1) epList.currentIndex++; event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                if (epList.currentIndex > 0) epList.currentIndex--; event.accepted = true
            } else if (event.key === Qt.Key_Return) {
                let ep = episodeModel.get(epList.currentIndex)
                if (ep) playSelectedEpisode(ep.epNum)
                event.accepted = true
            }
        } else if (window.currentView === "player") {
            if (event.key === Qt.Key_Escape) { window.closePlayer(); event.accepted = true }
            else if (event.key === Qt.Key_Space) { embeddedMpv.command(["cycle", "pause"]); event.accepted = true }
            else if (event.key === Qt.Key_Left) { embeddedMpv.command(["seek", "-10"]); event.accepted = true }
            else if (event.key === Qt.Key_Right) { embeddedMpv.command(["seek", "10"]); event.accepted = true }
        } else if (window.currentView === "pip") {
            if (event.key === Qt.Key_Escape) {
                window.currentView = "search"
                searchInput.forceActiveFocus()
                saveUiState()
                event.accepted = true
            }
        } else if (window.currentView === "search" && !searchInput.activeFocus
                   && event.text.length === 1 && event.text.charCodeAt(0) > 0x20
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            // Type-to-search: any printable key focuses the search box and
            // types straight into it, wherever keyboard focus happens to be
            // (grids keep arrows / Tab / Enter — those aren't printable).
            searchInput.forceActiveFocus()
            searchInput.insert(searchInput.length, event.text)
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            saveUiState()
            Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "close"])
            event.accepted = true
        }
    }

    property bool isKeyboardNav: false
    Timer { id: keyboardNavTimer; interval: 500; repeat: false; onTriggered: window.isKeyboardNav = false }

    ListModel { id: searchHistoryModel }
    ListModel { id: watchHistoryModel }
    ListModel { id: cachedTrendingMovies }
    ListModel { id: cachedTrendingTv }
    ListModel { id: cachedTrendingAnime }
    ListModel { id: searchResults }
    ListModel { id: ytResults }
    ListModel { id: ytChannels }
    ListModel { id: musicAlbums }
    ListModel { id: musicTracks }
    ListModel { id: seasonModel }
    ListModel { id: gamesModel }
    ListModel { id: booksModel }
    ListModel { id: malModel }

    // ── Library state + loader (see the lib* helpers above) ──
    property var libraryAll: []              // whole watchlist: [{imdbId,type,title,poster,status,ts}]
    property string libStatus: "watching"    // Library browse filter (keys = malStatuses)
    property bool libraryOpen: false         // Library browse overlay visible
    ListModel { id: libraryModel }
    Process {
        id: readLibraryProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_library.json 2>/dev/null || echo '[]'"]
        running: false
        stdout: SplitParser { onRead: (data) => {
            try { window.libraryAll = JSON.parse(data.trim()) || [] } catch(e) { window.libraryAll = [] }
            window.libRefreshModel()
        } }
    }

    // ── Steam games (local files; launch routed through Steam) ──
    property bool gamesLoaded: false
    property bool gamesLoading: false
    Process {
        id: gamesProc
        command: ["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/steam_games.sh"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                window.gamesLoading = false
                gamesModel.clear()
                var arr = []
                try { arr = JSON.parse((this.text || "").trim() || "[]") } catch (e) { arr = [] }
                for (var i = 0; i < arr.length; i++) gamesModel.append(arr[i])
                window.gamesLoaded = true
            }
        }
    }
    function loadSteamGames(force) {
        if (window.gamesLoading) return
        if (window.gamesLoaded && !force) return
        window.gamesLoading = true
        gamesProc.running = false
        gamesProc.running = true
    }
    function launchGame(appid) {
        if (!appid) return
        // Route the launch through Steam so it handles Proton/cloud/overlay.
        Quickshell.execDetached(["steam", "steam://rungameid/" + appid])
        Quickshell.execDetached(["notify-send", "Launching via Steam", "App " + appid])
    }

    // ── Kavita books (manga + novels) ──
    // kavita_fetch.py authenticates with the API key, lists ONLY the manga/novel
    // libraries, and emits series rows with ready-to-use cover URLs.
    property string booksError: ""   // "no-key" | "auth" | "" (ok)
    Process {
        id: booksProc
        command: ["python3", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/kavita_fetch.py", "series"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                window.booksLoading = false
                window.isSearchingBooks = false
                booksModel.clear()
                window.booksError = ""
                var parsed = []
                try { parsed = JSON.parse((this.text || "").trim() || "[]") } catch (e) { parsed = [] }
                if (parsed && parsed.error) { window.booksError = parsed.error }
                else if (Array.isArray(parsed)) {
                    for (var i = 0; i < parsed.length; i++) booksModel.append(parsed[i])
                }
                window.booksLoaded = true
            }
        }
    }
    function fetchBooks(search) {
        if (window.booksLoading) return
        var q = (search || "").trim()
        window.booksLoading = true
        window.isSearchingBooks = (q !== "")
        booksProc.running = false
        booksProc.command = q === ""
            ? ["python3", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/kavita_fetch.py", "series"]
            : ["python3", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/kavita_fetch.py", "series", q]
        booksProc.running = true
    }
    function booksSearch(query) {
        booksModel.clear()
        fetchBooks(query)
    }
    // ── MyAnimeList lists (mal-better-stremio addon) ──
    // Fetch one MAL list (watching / plan_to_watch / completed / on_hold / dropped)
    // from the addon's Stremio catalog and populate malModel for the home row.
    function malLabelFor(key) {
        for (var i = 0; i < window.malStatuses.length; i++)
            if (window.malStatuses[i].key === key) return window.malStatuses[i].label
        return key
    }
    function selectMalStatus(key) {
        if (window.malStatus === key && malModel.count > 0 && !window.malLoading) return
        window.malStatus = key
        fetchMal(key)
    }
    function fetchMal(status) {
        if (!window.malReady) { window.malError = ""; malModel.clear(); return }
        var st = status || window.malStatus
        window.malLoading = true
        window.malError = ""
        var url = window.malAddonUrl + "/catalog/anime/" + st + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function () { window.malLoading = false; window.malError = "fetch" }
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.malLoading = false
            // Ignore a stale response if the user already switched lists.
            if (st !== window.malStatus) return
            malModel.clear()
            try {
                var metas = (JSON.parse(xhr.responseText).metas) || []
                for (var i = 0; i < metas.length; i++) {
                    var m = metas[i]
                    var malId = String(m.id || "").replace(/^mal_/, "")
                    malModel.append({
                        malId: malId,
                        title: m.name || "",
                        poster: m.poster || "",
                        animeType: m.type || "series",
                        status: st
                    })
                }
            } catch (e) { window.malError = "fetch" }
        }
        xhr.send()
    }
    // Move a MAL entry to another list. Optimistic: update/remove the card now,
    // then PATCH MyAnimeList in the background (needs mal_access_token).
    Process { id: malSetProc; running: false
        stdout: StdioCollector { onStreamFinished: {
            var r = {}; try { r = JSON.parse((this.text || "{}").trim() || "{}") } catch (e) {}
            if (r.ok) Quickshell.execDetached(["notify-send", "MyAnimeList", "Moved to " + window.malLabelFor(r.status)])
            else if (r.error === "no-token")
                Quickshell.execDetached(["notify-send", "MyAnimeList", "Add \"mal_access_token\" to config.json to change your lists."])
            else if (r.error === "auth")
                Quickshell.execDetached(["notify-send", "MyAnimeList", "Token rejected — re-copy mal_access_token."])
            else Quickshell.execDetached(["notify-send", "MyAnimeList", "Couldn't update the list."])
        } }
    }
    function malSetStatus(malId, newStatus) {
        if (!malId) return
        // Optimistic UI: if the card is leaving the list we're viewing, drop it.
        if (newStatus !== window.malStatus) {
            for (var i = 0; i < malModel.count; i++) {
                if (String(malModel.get(i).malId) === String(malId)) { malModel.remove(i); break }
            }
        }
        malSetProc.running = false
        malSetProc.command = ["python3", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/mal_set_status.py", String(malId), newStatus]
        malSetProc.running = true
    }
    // Left-click a MAL card: open it in the normal anime browser (kitsu-backed),
    // which resolves episodes/streams via ani-cli.
    function openMalAnime(item) {
        if (!item) return
        window.mediaType = "anime"
        searchInput.text = item.title
        doSearch(item.title)
    }

    // Open a series in the Kavita web reader — handles manga (images) and novels
    // (EPUB) uniformly, so we don't reimplement two readers in QML.
    function openBook(item) {
        if (!item) return
        var u = window.kavitaUrl + "/library/" + item.libraryId + "/series/" + item.id
        Quickshell.execDetached(["xdg-open", u])
        Quickshell.execDetached(["notify-send", "Kavita", "Opening " + (item.name || "series") + " in your reader"])
    }

    // ── Focus mode (shared with TopBar / focus daemon via ~/.cache/qs_focus_mode) ──
    // "gaming" → Games tab appears; "study" → movies/tv/anime tabs disappear.
    property string focusMode: "default"
    readonly property var gatedKeys: ["movie", "tv", "anime"]
    function isSectionVisible(key) {
        if (key === "games") return window.focusMode === "gaming"
        if (window.gatedKeys.indexOf(key) >= 0) {
            if (window.focusMode === "study") return false
            // gaming has no watch limit, so a stale lock never hides the tabs there
            if (window.focusMode !== "gaming" && window.mediaLockUntil > window.mediaNow()) return false
        }
        return true
    }
    // In-process watch (was a cat Process + inotifywait waiter pair)
    FileView {
        id: focusModeView
        path: Quickshell.env("HOME") + "/.cache/qs_focus_mode"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            window.focusMode = text().trim() || "default"
            // Covers the case where the value is unchanged (so onFocusModeChanged
            // won't fire) but the restored tab isn't valid for this mode.
            if (!window.isSectionVisible(window.mediaType) && window.currentView === "search")
                selectSection(window.focusMode === "gaming" ? "games" : "youtube")
        }
        onLoadFailed: focusModeRetry.start()
    }
    Timer { id: focusModeRetry; interval: 2000; repeat: false; onTriggered: focusModeView.reload() }
    onFocusModeChanged: {
        // Gaming has no watch limit — make sure the selector isn't left open from before.
        if (window.focusMode === "gaming") window.mediaGateOpen = false
        // If the section we're on just got hidden by the mode change, bail to a safe tab.
        if (!isSectionVisible(window.mediaType) && window.currentView === "search") {
            selectSection(window.focusMode === "gaming" ? "games" : "youtube")
            return
        }
        // Toggling study while on YouTube swaps the feed (learning ↔ subscriptions).
        if (window.mediaType === "youtube" && window.currentView === "search" && window.ytView === "home")
            youtubeHomeFeed()
    }

    // ── Mandatory self-limit gate for movies / TV / anime ──
    // On entering one of the three, a blank popup makes you pick how many videos you
    // may watch. After that many, the three lock for 10 minutes (it "kicks you out").
    // State persists in ~/.cache/qs_media_gate so a reload/reopen can't bypass it.
    property int mediaAllowance: -1     // -1 = not yet chosen this cycle
    property int mediaWatched: 0
    property real mediaLockUntil: 0     // epoch ms; >now = locked
    property bool mediaGateOpen: false  // selector popup visible
    property int mediaTick: 0           // bumped each second while locked, to refresh the countdown
    readonly property int mediaLockMs: 10 * 60 * 1000
    function mediaNow() { return Date.now() }
    function mediaIsLocked() { return window.mediaLockUntil > window.mediaNow() }
    function mediaLockRemaining() { return Math.max(0, Math.ceil((window.mediaLockUntil - window.mediaNow()) / 1000)) }
    function mediaPersist() {
        var j = JSON.stringify({ allowance: window.mediaAllowance, watched: window.mediaWatched, lockUntil: window.mediaLockUntil })
        Quickshell.execDetached(["bash", "-c", 'printf %s "$1" > ~/.cache/qs_media_gate', "_", j])
    }
    Process {
        id: mediaGateReader; running: true
        command: ["bash", "-c", "cat ~/.cache/qs_media_gate 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var c = JSON.parse((this.text || "{}").trim() || "{}")
                    window.mediaAllowance = (typeof c.allowance === "number") ? c.allowance : -1
                    window.mediaWatched = (typeof c.watched === "number") ? c.watched : 0
                    var lu = (typeof c.lockUntil === "number") ? c.lockUntil : 0
                    // Sanity clamp: a lock can never be more than its 10-min window in the
                    // future, so a corrupt/huge value can't trap you forever.
                    if (lu > window.mediaNow() + window.mediaLockMs) lu = 0
                    window.mediaLockUntil = lu
                } catch (e) {}
                window.mediaGateEvaluate()
            }
        }
    }
    // Ticks while locked so the countdown updates and re-prompts when the lock lifts.
    Timer {
        id: mediaLockTimer; interval: 1000; repeat: true
        running: window.mediaLockUntil > 0
        onTriggered: {
            window.mediaTick++
            if (!window.mediaIsLocked()) { window.mediaResetCycle(); window.mediaGateEvaluate() }
        }
    }
    function mediaResetCycle() {
        window.mediaAllowance = -1; window.mediaWatched = 0; window.mediaLockUntil = 0
        window.mediaPersist()
    }
    function mediaStartLock() {
        // Idempotent: only arm the lock + notify once. Repeat calls just ensure you're
        // kicked out, so this can never loop or spam notifications.
        if (!window.mediaIsLocked()) {
            window.mediaLockUntil = window.mediaNow() + window.mediaLockMs
            window.mediaPersist()
            Quickshell.execDetached(["notify-send", "Watch limit reached", "Movies / TV / Anime hidden for 10 minutes — YouTube & Music still work."])
        }
        window.mediaGateOpen = false
        // Kick out of the three to a usable tab (the gated tabs also hide while locked).
        if (window.gatedKeys.indexOf(window.mediaType) >= 0)
            selectSection(window.focusMode === "gaming" ? "games" : "youtube")
    }
    // Called when landing on / already on one of the three. Decides: lock-kick, prompt, or allow.
    function mediaGateEvaluate() {
        if (window.focusMode === "gaming") { window.mediaGateOpen = false; return }   // no limit while gaming
        if (window.gatedKeys.indexOf(window.mediaType) < 0) { window.mediaGateOpen = false; return }
        if (window.currentView !== "search") return
        if (window.mediaIsLocked()) {                                                 // locked → kick out to a usable tab
            window.mediaGateOpen = false
            if (window.gatedKeys.indexOf(window.mediaType) >= 0)
                selectSection(window.focusMode === "gaming" ? "games" : "youtube")
            return
        }
        if (window.mediaAllowance < 0) { window.mediaGateOpen = true; return }       // need a choice
        if (window.mediaWatched >= window.mediaAllowance) { window.mediaStartLock(); return }  // exhausted → lock
        window.mediaGateOpen = false                                                 // allowance remaining
    }
    function mediaChooseAllowance(n) {
        window.mediaAllowance = n; window.mediaWatched = 0; window.mediaLockUntil = 0
        window.mediaGateOpen = false
        window.mediaPersist()
    }
    // Controller → watch-limit wheel. Driven by watchers/media_gate_controller.py while
    // the gate is open. All no-op unless the selector is actually showing.
    IpcHandler {
        target: "mediagate"
        function left(): void   { if (window.mediaGateOpen) epWheel.decrementCurrentIndex() }
        function right(): void  { if (window.mediaGateOpen) epWheel.incrementCurrentIndex() }
        function confirm(): void { if (window.mediaGateOpen) window.mediaChooseAllowance(epWheel.currentIndex + 1) }
        function cancel(): void  { if (window.mediaGateOpen) { window.mediaGateOpen = false; selectSection(window.focusMode === "gaming" ? "games" : "youtube") } }
    }
    // Returns true if a movie/tv/anime video may start; counts the watch and may lock.
    function mediaCanWatch() {
        if (window.focusMode === "gaming") return true   // no limit while gaming — unlimited
        if (window.mediaIsLocked()) { window.mediaStartLock(); return false }
        if (window.mediaAllowance < 0) { window.mediaGateOpen = true; return false }
        if (window.mediaWatched >= window.mediaAllowance) { window.mediaStartLock(); return false }
        window.mediaWatched += 1
        window.mediaPersist()
        return true
    }

    // ── Background cache warming ──
    // Warm every module's cache at session start (staggered, so we don't spike CPU),
    // then refresh one module every 15 minutes on rotation. Each warm self-skips if
    // its tab is the one currently on screen, so it never disrupts what you're viewing.
    readonly property int warmCount: 5
    property int warmRotateIndex: 0
    function warmActive(key) { return window.mediaType === key && window.currentView === "search" }
    function warmTrendingMovies() { if (!warmActive("movie")) fetchTrending("movie") }
    function warmTrendingTv()     { if (!warmActive("tv"))    fetchTrending("series") }
    function warmTrendingAnime()  { if (!warmActive("anime")) fetchTrendingAnime() }
    function warmMusic()          { if (window.subsonicReady && !warmActive("music")) fetchMusicAlbums() }
    function warmGames()          { if (!warmActive("games")) loadSteamGames(true) }
    // NB: YouTube home is intentionally NOT background-warmed — fetching into the live
    // ytResults model while its GridView is hidden/unsized stacked the tiles. It's
    // cache-first on open instead, which is already instant after the first visit.
    function runWarm(n) {
        switch (n % window.warmCount) {
        case 0: warmTrendingMovies(); break
        case 1: warmTrendingTv();     break
        case 2: warmTrendingAnime();  break
        case 3: warmMusic();          break
        case 4: warmGames();          break
        }
    }
    // Session-start pass: warm all six once, ~8s apart (gives config readers time to
    // load first, and keeps inference/scrapers from stacking — see the CPU-pressure note).
    Timer {
        id: warmStartupTimer
        interval: 8000; repeat: true; running: true
        property int step: 0
        onTriggered: { runWarm(step); step++; if (step >= window.warmCount) stop() }
    }
    // Hourly rotation: refresh one module every 15 minutes.
    Timer {
        id: warmRotateTimer
        interval: 15 * 60 * 1000; repeat: true; running: true
        onTriggered: { runWarm(window.warmRotateIndex); window.warmRotateIndex++ }
    }

    // Read Navidrome connection details from config.json — via secrets.sh
    // getjson, which overlays keyring-held secrets (kavita/mal/navidrome…)
    // onto the plaintext file; the file itself only carries blanks for those.
    Process {
        id: navidromeConfigProc
        running: true
        command: ["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/secrets.sh", "getjson"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var c = JSON.parse(this.text || "{}")
                    window.navidromeUrl = (c.navidrome_url || "").replace(/\/+$/, "")
                    window.navidromeUser = c.navidrome_user || ""
                    window.navidromePass = c.navidrome_pass || ""
                    window.kavitaUrl = (c.kavita_url || "http://localhost:5000").replace(/\/+$/, "")
                    window.kavitaKey = c.kavita_api_key || ""
                    window.malAddonUrl = (c.mal_addon_url || "").replace(/\/manifest\.json\/?$/, "").replace(/\/+$/, "")
                    window.malToken = c.mal_access_token || ""
                } catch(e) {}
            }
        }
    }

    // ── Music data (Subsonic) ──
    function fetchMusicAlbums() {
        if (!window.subsonicReady) return
        window.isSearchingMusic = true
        musicAlbums.clear()
        var xhr = new XMLHttpRequest()
        xhr.open("GET", subsonicUrl("getAlbumList2", "type=newest&size=60"))
        xhr.onerror = function() { window.isSearchingMusic = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingMusic = false
            window.musicLoaded = true
            try {
                var r = JSON.parse(xhr.responseText)["subsonic-response"]
                var list = (r && r.albumList2 && r.albumList2.album) || []
                for (var i = 0; i < list.length; i++) musicAppendAlbum(list[i])
            } catch(e) {}
        }
        xhr.send()
    }

    function musicSearch(query) {
        var q = (query || "").trim()
        musicAlbums.clear()
        if (q === "" || !window.subsonicReady) { window.isSearchingMusic = false; return }
        window.isSearchingMusic = true
        var xhr = new XMLHttpRequest()
        xhr.open("GET", subsonicUrl("search3", "albumCount=40&songCount=0&artistCount=0&query=" + encodeURIComponent(q)))
        xhr.onerror = function() { window.isSearchingMusic = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingMusic = false
            try {
                var r = JSON.parse(xhr.responseText)["subsonic-response"]
                var list = (r && r.searchResult3 && r.searchResult3.album) || []
                for (var i = 0; i < list.length; i++) musicAppendAlbum(list[i])
            } catch(e) {}
        }
        xhr.send()
    }

    function musicAppendAlbum(a) {
        musicAlbums.append({
            albumId: a.id || "",
            name: a.name || a.album || "Unknown",
            artist: a.artist || "",
            cover: subsonicCoverUrl(a.coverArt || a.id, 300),
            year: a.year || 0,
            songCount: a.songCount || 0
        })
    }

    function openAlbum(albumId, name, artist, cover) {
        if (!albumId || !window.subsonicReady) return
        window.selectedAlbumId = albumId
        window.selectedAlbumName = name || ""
        window.selectedAlbumArtist = artist || ""
        window.selectedAlbumCover = cover || ""
        musicTracks.clear()
        window.currentView = "album"
        saveUiState()
        var xhr = new XMLHttpRequest()
        xhr.open("GET", subsonicUrl("getAlbum", "id=" + encodeURIComponent(albumId)))
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var r = JSON.parse(xhr.responseText)["subsonic-response"]
                var songs = (r && r.album && r.album.song) || []
                for (var i = 0; i < songs.length; i++) {
                    var s = songs[i]
                    musicTracks.append({
                        songId: s.id || "",
                        title: s.title || "Untitled",
                        artist: s.artist || "",
                        track: s.track || (i + 1),
                        duration: s.duration || 0
                    })
                }
            } catch(e) {}
        }
        xhr.send()
    }

    // Play a track in the embedded player (audio only — cover art shown behind).
    function playMusic(songId, title) {
        if (!songId || !window.subsonicReady) return
        enterPlayer(title || "")
        window.playerKind = "music"
        window.currentYtId = ""
        refreshPlayerComments()
        Quickshell.execDetached(["bash", window.videoCli, "play", "music", songId])
    }
    ListModel { id: episodeModel }

    // --- ANIME POPULAR (Cinemeta series, genre=Animation) ---
    // Self-contained mirror of the movie/tv trending path so the delicate
    // movie/tv duality logic stays untouched.
    Process {
        id: readAnimeCacheProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_trending_anime.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: SplitParser {
            onRead: (data) => {
                try {
                    let parsed = JSON.parse(data.trim())
                    let items = parsed.items
                    if (items && items.length > 0) {
                        cachedTrendingAnime.clear()
                        window.rawTrendingAnime = items
                        for (let i = 0; i < items.length; i++) cachedTrendingAnime.append(items[i])
                        window.trendingAnimeLoaded = true
                        window.isFetchingAnime = false
                        window.trendingAnimeLastFetch = parsed.lastFetch || 0
                        if ((Date.now() - (parsed.lastFetch || 0)) > window.trendingCacheMaxAge) fetchTrendingAnime()
                    } else {
                        fetchTrendingAnime()
                    }
                } catch(e) { fetchTrendingAnime() }
            }
        }
    }

    function fetchTrendingAnime() {
        window.isFetchingAnime = true
        var xhr = new XMLHttpRequest()
        // Kitsu addon — keyless, dedicated anime (Most Popular catalog).
        xhr.open("GET", "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-popular.json")
        xhr.onerror = function() { window.isFetchingAnime = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isFetchingAnime = false
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    if (res && res.metas) {
                        let rawItems = []
                        cachedTrendingAnime.clear()
                        for (let i = 0; i < res.metas.length; i++) {
                            let item = res.metas[i]
                            if (!item.id || !item.poster) continue
                            let entry = {
                                imdbId: item.id, title: item.name || "Unknown",
                                poster: item.poster || item.background || "",
                                type: "tv", year: item.releaseInfo || "N/A",
                                rating: parseFloat(item.imdbRating) || 0, popularity: i
                            }
                            rawItems.push(entry)
                            cachedTrendingAnime.append(entry)
                        }
                        window.rawTrendingAnime = rawItems
                        window.trendingAnimeLastFetch = Date.now()
                        window.trendingAnimeLoaded = true
                        saveAnimeCache()
                    }
                } catch(e) {}
            }
        }
        xhr.send()
    }

    function saveAnimeCache() {
        if (cachedTrendingAnime.count === 0) return
        let arr = []
        for (let i = 0; i < cachedTrendingAnime.count; i++) {
            let a = cachedTrendingAnime.get(i)
            arr.push({ imdbId: a.imdbId, title: a.title, poster: a.poster, type: a.type, year: a.year, rating: parseFloat(a.rating) || 0, popularity: i })
        }
        saveJsonToCache("qs_trending_anime.json", { lastFetch: window.trendingAnimeLastFetch, items: arr })
    }

    // ── HiAnime-style HOME: hero spotlight + category rows ──────────────────
    // Each movie/tv/anime dashboard gets a rotating hero banner plus themed
    // horizontal rows (Top Rated / New / genres … — Kitsu catalogs for anime),
    // all keyless Cinemeta/Kitsu catalogs. The "hero" key per type is a rich
    // first-page fetch (background/description/logo) driving the banner.
    readonly property var homeCategories: ({
        "movie": [
            { key: "m-hero",     title: "",             url: "https://v3-cinemeta.strem.io/catalog/movie/top.json" },
            { key: "m-featured", title: "Top Rated",    url: "https://v3-cinemeta.strem.io/catalog/movie/imdbRating.json" },
            { key: "m-new",      title: "New Releases", url: "https://v3-cinemeta.strem.io/catalog/movie/year.json" },
            { key: "m-action",   title: "Action",       url: "https://v3-cinemeta.strem.io/catalog/movie/top/genre=Action.json" },
            { key: "m-comedy",   title: "Comedy",       url: "https://v3-cinemeta.strem.io/catalog/movie/top/genre=Comedy.json" },
            { key: "m-scifi",    title: "Sci-Fi",       url: "https://v3-cinemeta.strem.io/catalog/movie/top/genre=Sci-Fi.json" },
            { key: "m-horror",   title: "Horror",       url: "https://v3-cinemeta.strem.io/catalog/movie/top/genre=Horror.json" }
        ],
        "tv": [
            { key: "t-hero",     title: "",             url: "https://v3-cinemeta.strem.io/catalog/series/top.json" },
            { key: "t-featured", title: "Top Rated",    url: "https://v3-cinemeta.strem.io/catalog/series/imdbRating.json" },
            { key: "t-new",      title: "New Seasons",  url: "https://v3-cinemeta.strem.io/catalog/series/year.json" },
            { key: "t-drama",    title: "Drama",        url: "https://v3-cinemeta.strem.io/catalog/series/top/genre=Drama.json" },
            { key: "t-action",   title: "Action",       url: "https://v3-cinemeta.strem.io/catalog/series/top/genre=Action.json" },
            { key: "t-comedy",   title: "Comedy",       url: "https://v3-cinemeta.strem.io/catalog/series/top/genre=Comedy.json" }
        ],
        "anime": [
            // Kitsu's trending/airing catalogs IGNORE skip (fixed lists), so
            // their rows/pages continue seamlessly into the paginating
            // popular catalog via `more` once the primary list runs out.
            { key: "a-hero",     title: "",              url: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-trending.json" },
            { key: "a-trending", title: "Trending Now",  url: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-trending.json",
              more: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-popular.json" },
            { key: "a-airing",   title: "Top Airing",    url: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-airing.json",
              more: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-popular.json" },
            { key: "a-rated",    title: "Highest Rated", url: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-rating.json",
              more: "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-popular.json" }
        ]
    })
    // Rows (with a title) of the current section; the hero entry is looked up
    // separately via homeHeroKey. Bound by the dashboard header.
    readonly property var homeRows: {
        var cats = homeCategories[mediaType] || []
        var out = []
        for (var i = 0; i < cats.length; i++) if (cats[i].title !== "") out.push(cats[i])
        return out
    }
    readonly property string homeHeroKey: mediaType === "movie" ? "m-hero"
        : mediaType === "tv" ? "t-hero" : mediaType === "anime" ? "a-hero" : ""
    property var homeCatData: ({})     // key → [items]; session cache (small, ~30 each)
    property var homeCatPending: ({})
    function homeCatItems(key) { return homeCatData[key] || [] }
    function homeFetchCat(key, url) {
        if (!key || homeCatData[key] || homeCatPending[key]) return
        homeCatPending[key] = true
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { delete window.homeCatPending[key] }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            delete window.homeCatPending[key]
            if (xhr.status !== 200) return
            try {
                var res = JSON.parse(xhr.responseText)
                if (!res || !res.metas) return
                var items = []
                for (var i = 0; i < res.metas.length && items.length < 100; i++) {   // keep the whole first page
                    var m = res.metas[i]
                    if (!m.id || !m.poster) continue
                    items.push({
                        imdbId: m.id, title: m.name || "Unknown",
                        poster: m.poster || "",
                        background: m.background || "",
                        logo: m.logo || "",
                        description: m.description || "",
                        genres: (m.genres && m.genres.length) ? m.genres.slice(0, 3).join(" · ") : "",
                        type: m.type === "movie" ? "movie" : "tv",
                        year: m.releaseInfo || "",
                        rating: parseFloat(m.imdbRating) || 0
                    })
                }
                // Shallow-copy so the var property sees a NEW object and reliably
                // fires homeCatDataChanged (same-reference writes may not notify).
                var d = {}
                for (var k in window.homeCatData) d[k] = window.homeCatData[k]
                d[key] = items
                window.homeCatData = d
            } catch(e) {}
        }
        xhr.send()
    }

    // ── Category full page ("View All" on a home row) ────────────────────────
    // Opens an overlay grid of the whole catalog behind a row, paginating the
    // Stremio catalog with skip= (genre catalogs join extras with '&').
    property bool catPageOpen: false
    property string catPageKey: ""
    property string catPageTitle: ""
    property string catPageUrl: ""
    // Series-page Back target: null = home/search; {kind:"catpage",…} reopens
    // that View All page; {kind:"library"} reopens the Library browse overlay.
    property var seriesReturn: null
    property var homeCatMoreState: ({})   // key → { busy, done }
    ListModel { id: catPageModel }
    function openCatPage(cat) {
        window.catPageKey = cat.key
        window.catPageTitle = cat.title
        window.catPageUrl = cat.url
        catPageModel.clear()
        var items = homeCatItems(cat.key)
        for (var i = 0; i < items.length; i++) catPageModel.append(items[i])
        window.catPageOpen = true
        homeCatMore(cat.key, cat.url)
    }
    function homeCatMore(key, url) {
        var st = window.homeCatMoreState[key] || ({ busy: false, done: false, fb: false, fbSkip: 0 })
        window.homeCatMoreState[key] = st
        var have = homeCatItems(key).length
        // No item cap — keep paging until the catalog stops yielding new titles
        // (st.done). The 20k guard only stops a runaway server.
        if (st.busy || st.done || have === 0 || have >= 20000) return
        st.busy = true
        // Some Kitsu anime catalogs (trending / airing) IGNORE skip — fixed
        // lists. Categories can declare a `more` fallback URL (popular, which
        // paginates) so their pages keep flowing once the primary runs dry.
        var cat = null
        for (var ct in homeCategories) {
            var carr = homeCategories[ct]
            for (var ci = 0; ci < carr.length; ci++) if (carr[ci].key === key) { cat = carr[ci]; break }
            if (cat) break
        }
        var useUrl = (st.fb && cat && cat.more) ? cat.more : url
        var skip = st.fb ? st.fbSkip : have
        var base = useUrl.replace(".json", "")
        var moreUrl = (base.indexOf("genre=") >= 0 ? base + "&skip=" + skip
                                                   : base + "/skip=" + skip) + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", moreUrl)
        xhr.onerror = function() { st.busy = false; st.done = true }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            st.busy = false
            if (xhr.status !== 200) { st.done = true; return }
            var added = 0, got = 0
            try {
                var res = JSON.parse(xhr.responseText)
                var metas = (res && res.metas) ? res.metas : []
                got = metas.length
                if (st.fb) st.fbSkip += got   // fallback advances even on all-dupe pages
                var cur = homeCatItems(key)
                var seen = ({})
                for (var i = 0; i < cur.length; i++) seen[cur[i].imdbId] = true
                var out = cur.slice()
                for (var j = 0; j < metas.length; j++) {
                    var m = metas[j]
                    if (!m.id || !m.poster || seen[m.id]) continue
                    seen[m.id] = true
                    var e = {
                        imdbId: m.id, title: m.name || "Unknown",
                        poster: m.poster || "", background: m.background || "",
                        logo: m.logo || "", description: m.description || "",
                        genres: (m.genres && m.genres.length) ? m.genres.slice(0, 3).join(" · ") : "",
                        type: m.type === "movie" ? "movie" : "tv",
                        year: m.releaseInfo || "", rating: parseFloat(m.imdbRating) || 0
                    }
                    out.push(e)
                    added++
                    if (window.catPageOpen && window.catPageKey === key) catPageModel.append(e)
                }
                if (added > 0) {
                    var d = {}
                    for (var k in window.homeCatData) d[k] = window.homeCatData[k]
                    d[key] = out
                    window.homeCatData = d
                }
                if (got === 0) {
                    // Source truly empty: switch to the fallback once, else done.
                    if (!st.fb && cat && cat.more) { st.fb = true; st.fbSkip = 0 }
                    else st.done = true
                } else if (added === 0 && !st.fb) {
                    // Primary returned only titles we already have — either a
                    // skip-ignoring catalog or exhausted: move to the fallback.
                    if (cat && cat.more) { st.fb = true; st.fbSkip = 0 }
                    else st.done = true
                }
            } catch(e2) { st.done = true }
            // Keep filling while the page is open and the catalog still yields.
            // Also chase all-dupe pages (added === 0): skip-ignoring catalogs
            // (Top Airing / Trending) hand back the same list, and without the
            // immediate retry the fallback switch never actually fetched — home
            // rows looked "finished" at one page while genre rows kept going.
            if (!st.done && (added === 0 || (window.catPageOpen && window.catPageKey === key)))
                homeCatMore(key, url)
        }
        xhr.send()
    }

    // --- YOUTUBE SEARCH ---
    // YouTube search → YouTubio. Routes to video or channel search per the toggle.
    function ytSearchDispatch(query) {
        window.youtubioCatalog = ""   // a text search is not a catalog browse
        window.ytView = "videos"
        youtubioSearch(query)          // videos → ytResults grid
        youtubioSearchChannels(query)  // matching channels → strip above the results
    }
    // Channel matches for a search, shown as a strip (does NOT take over the view).
    function youtubioSearchChannels(query) {
        var q = (query || "").trim()
        ytChannels.clear()
        if (q === "" || !window.youtubioReady) return
        var url = window.youtubioBase + "/catalog/YouTube/yt_id::ytsearch:channel/search=" + encodeURIComponent(q) + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var ms = (JSON.parse(xhr.responseText).metas) || []
                for (var i = 0; i < Math.min(ms.length, 8); i++) {
                    var cid = (ms[i].id || "").replace(/^yt_id:/, "")
                    if (cid) ytChannels.append({ channelId: cid, name: ms[i].name || cid, thumb: ms[i].poster || "" })
                }
            } catch (e) {}
        }
        xhr.send()
    }

    // Load Navidrome-style: read saved YouTube subscriptions from cache.
    Process {
        id: youtubeSubsProc
        running: true
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_youtube_subs.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(this.text || "{}")
                    if (d.subs && d.subs.length) window.youtubeSubs = d.subs
                } catch(e) {}
            }
        }
    }
    Process {
        id: ytSeenProc; running: true
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_youtube_seen.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { onStreamFinished: { try { window.ytSeen = JSON.parse(this.text || "{}") || ({}) } catch(e) {} } }
    }
    Process {
        id: ytWatchedChProc; running: true
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_youtube_watched_ch.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(this.text || "{}"); if (d.ch) window.ytWatchedChannels = d.ch } catch(e) {} } }
    }
    Process {
        id: ytPlaylistsProc; running: true
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_youtube_playlists.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(this.text || "{}"); if (d.lists) window.ytPlaylists = d.lists } catch(e) {} } }
    }

    // Study-mode YouTube feed: route through YouTubio's ytsearch (== youtube.com/
    // /results?search_query=…) with a learning query, instead of the normal
    // subscription feed. Editable via movies/youtube_study_query.txt.
    property string studyYoutubeQuery: "university lecture full course"
    Process {
        id: studyQueryProc
        running: true
        command: ["bash", "-c", "cat " + Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/youtube_study_query.txt 2>/dev/null || true"]
        stdout: StdioCollector {
            onStreamFinished: { var q = (this.text || "").trim(); if (q !== "") window.studyYoutubeQuery = q }
        }
    }
    function studyYoutubeFeed() {
        window.ytView = "home"
        ytChannels.clear()
        youtubioSearch(window.studyYoutubeQuery)   // /results learning feed
    }

    // Algorithmic home feed: pull recent uploads from each subscribed channel,
    // merge and shuffle them into the video grid.
    property int ytHomeCacheTtl: 30 * 60 * 1000   // 30 min: cache the merged home feed
    function youtubeHomeFeed() {
        // In study mode the YouTube tab becomes a learning /results feed.
        if (window.focusMode === "study") { studyYoutubeFeed(); return }
        window.ytView = "home"
        window.ytHomeExtra = []
        window.ytMoreDone = false; window.ytMoreLoading = false
        ytChannels.clear()
        window.isSearchingYt = true
        // Cache-first: populate instantly from the last merged feed; fan out only if stale/missing.
        youtubeHomeCacheProc.running = false
        youtubeHomeCacheProc.running = true
    }
    // The network build: one request per feed channel (subs ∪ channels you watch),
    // merged + shuffled. Discovery comes from the watched-channel set.
    function youtubeHomeFetch() {
        window.ytView = "home"
        ytChannels.clear()
        // Don't wipe ytResults — keep what's on screen; flush only appends new videos.
        window.ytHomeBuffer = []
        var feed = ytFeedChannels()
        if (!window.youtubioReady || feed.length === 0) { window.isSearchingYt = false; return }
        window.isSearchingYt = true
        window.ytHomePending = feed.length
        for (var i = 0; i < feed.length; i++) {
            (function(sub) {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", window.youtubioBase + "/catalog/YouTube/yt_id:" + encodeURIComponent(sub.channelId) + ".json")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState !== XMLHttpRequest.DONE) return
                    if (xhr.status === 200) {
                        try {
                            var ms = (JSON.parse(xhr.responseText).metas) || []
                            var buf = window.ytHomeBuffer.slice()
                            var extra = window.ytHomeExtra.slice()
                            for (var j = 0; j < Math.min(ms.length, 40); j++) {
                                var vid = (ms[j].id || "").replace(/^yt_id:/, "")
                                if (!vid) continue
                                var entry = { vid: vid, title: ms[j].name || vid, channel: sub.name, channelId: sub.channelId,
                                              duration: ms[j].runtime || "", dateStr: ytRelDate(ms[j].released || ""), thumb: ms[j].poster || "" }
                                // First 8 per channel show immediately; the rest wait in
                                // ytHomeExtra and stream in as you scroll (no refetch).
                                if (j < 8) buf.push(entry); else extra.push(entry)
                            }
                            window.ytHomeBuffer = buf
                            window.ytHomeExtra = extra
                        } catch(e) {}
                    }
                    window.ytHomePending--
                    if (window.ytHomePending <= 0) youtubeHomeFlush()
                }
                xhr.send()
            })(feed[i])
        }
    }
    function youtubeHomeFlush(fromCache) {
        window.isSearchingYt = false
        // Persist the freshly-merged feed so the next open is instant.
        if (!fromCache && window.ytHomeBuffer.length > 0)
            saveJsonToCache("qs_youtube_home.json", { ts: Date.now(), items: window.ytHomeBuffer })
        if (window.ytView !== "home") return   // only the home view uses this merged feed
        // Filter to "never seen". If everything's been seen, fall back to the full set.
        var src = window.ytHomeBuffer
        var buf = src.filter(function (it) { return !ytIsSeen(it.vid) })
        if (buf.length === 0) buf = src.slice()
        else buf = buf.slice()
        // Dedup by vid in both paths: the same video can surface from more than one
        // channel feed (collabs / reposts), which otherwise shows up twice.
        var have = {}
        for (var m = 0; m < ytResults.count; m++) have[ytResults.get(m).vid] = true
        if (ytResults.count === 0) {
            // First load: shuffle once = "the algorithm", then leave the order alone.
            for (var i = buf.length - 1; i > 0; i--) {
                var j = Math.floor(Math.random() * (i + 1)); var t = buf[i]; buf[i] = buf[j]; buf[j] = t
            }
        }
        // Already on screen: keep what's there put — only append genuinely new videos
        // to the bottom so nothing shifts under you.
        for (var n = 0; n < buf.length; n++) {
            var v = buf[n].vid
            if (v && !have[v]) { have[v] = true; ytResults.append(Object.assign({ duration: "", dateStr: "" }, buf[n])) }
        }
    }
    // Reads the cached merged home feed; uses it if fresh, else triggers the network build.
    Process {
        id: youtubeHomeCacheProc
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_youtube_home.json 2>/dev/null || echo '{}'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                if (window.focusMode === "study" || window.ytView !== "home") return
                var items = []; var fresh = false
                try {
                    var d = JSON.parse((this.text || "{}").trim() || "{}")
                    items = d.items || []
                    fresh = d.ts && (Date.now() - d.ts < window.ytHomeCacheTtl) && items.length > 0
                } catch (e) {}
                if (fresh) { window.ytHomeBuffer = items; youtubeHomeFlush(true) }
                else youtubeHomeFetch()
            }
        }
    }

    // Channel search → channel cards you can subscribe to / open.
    function youtubioChannelSearch(query) {
        var q = (query || "").trim()
        ytChannels.clear(); ytResults.clear()
        window.ytView = "channels"
        window.ytChannelsIsSubs = false   // search results → the card grid, not the subs feed
        if (q === "" || !window.youtubioReady) { window.isSearchingYt = false; return }
        window.isSearchingYt = true
        var url = window.youtubioBase + "/catalog/YouTube/yt_id::ytsearch:channel/search=" + encodeURIComponent(q) + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.isSearchingYt = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingYt = false
            if (xhr.status === 200) {
                try {
                    var ms = (JSON.parse(xhr.responseText).metas) || []
                    for (var i = 0; i < ms.length; i++) {
                        var cid = (ms[i].id || "").replace(/^yt_id:/, "")
                        if (!cid) continue
                        ytChannels.append({ channelId: cid, name: ms[i].name || cid, thumb: ms[i].poster || "" })
                    }
                } catch(e) {}
            }
        }
        xhr.send()
    }

    // Open one channel's uploads in the video grid.
    function openYoutubeChannel(channelId, name) {
        if (!channelId || !window.youtubioReady) return
        window.ytMoreDone = false; window.ytMoreLoading = false
        window.ytReturnView = (window.ytView === "channels") ? "channels" : "home"
        window.ytView = "channel"
        window.ytChannelId = channelId
        window.ytChannelName = name || channelId
        ytResults.clear(); ytChannels.clear()
        searchInput.text = ""
        window.isSearchingYt = true
        var url = window.youtubioBase + "/catalog/YouTube/yt_id:" + encodeURIComponent(channelId) + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.isSearchingYt = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingYt = false
            if (xhr.status === 200) {
                try {
                    var ms = (JSON.parse(xhr.responseText).metas) || []
                    for (var i = 0; i < ms.length; i++) {
                        var vid = (ms[i].id || "").replace(/^yt_id:/, "")
                        if (!vid) continue
                        var ch = ytMetaChannel(ms[i])
                        ytResults.append({ vid: vid, title: ms[i].name || vid, channel: ch.name || name, channelId: channelId,
                                           duration: ms[i].runtime || "", dateStr: ytRelDate(ms[i].released || ""), thumb: ms[i].poster || "" })
                    }
                } catch(e) {}
            }
        }
        xhr.send()
    }

    // yt-dlp direct search.
    function ytSearch(query) {
        var q = (query || "").trim()
        ytResults.clear()
        ytSearchProc.running = false
        if (q === "") { window.isSearchingYt = false; return }
        window.isSearchingYt = true
        ytSearchProc.query = q
        ytSearchProc.running = true
    }

    // YouTubio (self-hosted Stremio addon) video search → same ytResults grid.
    function youtubioSearch(query) {
        var q = (query || "").trim()
        ytResults.clear()
        ytSearchProc.running = false
        window.ytLastQuery = q                      // infinite scroll paginates this
        window.ytMoreDone = false; window.ytMoreLoading = false
        if (q === "" || !window.youtubioReady) { window.isSearchingYt = false; return }
        window.isSearchingYt = true
        var url = window.youtubioBase + "/catalog/YouTube/yt_id::ytsearch/search=" + encodeURIComponent(q) + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.isSearchingYt = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingYt = false
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    let ms = res.metas || []
                    for (let i = 0; i < ms.length; i++) {
                        let vid = (ms[i].id || "").replace(/^yt_id:/, "")
                        if (!vid) continue
                        let ch = ytMetaChannel(ms[i])
                        ytResults.append({ vid: vid, title: ms[i].name || vid, channel: ch.name, channelId: ch.id,
                                           duration: ms[i].runtime || "", dateStr: ytRelDate(ms[i].released || ""), thumb: ms[i].poster || "" })
                    }
                } catch(e) {}
            }
        }
        xhr.send()
    }

    // Loads the YouTubio base URL (manifest URL minus /manifest.json) from disk,
    // then fetches its catalog list.
    Process {
        id: readYoutubioUrlProc
        command: ["bash", "-c", "cat " + Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/youtubio_url.txt 2>/dev/null || true"]
        running: false
        stdout: SplitParser {
            onRead: (line) => {
                let u = (line || "").trim()
                if (u !== "" && window.youtubioBase === "") {
                    window.youtubioBase = u.replace(/\/manifest\.json\s*$/, "")
                    youtubioFetchManifest()
                }
            }
        }
    }

    // Read the addon's catalog list (so the picker reflects whatever channels /
    // playlists you configured).
    function youtubioFetchManifest() {
        if (!window.youtubioReady) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", window.youtubioBase + "/manifest.json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var m = JSON.parse(xhr.responseText)
                var list = m.catalogs || []
                var cats = []
                for (var i = 0; i < list.length; i++) {
                    var c = list[i]
                    var extras = (c.extra || []).map(function(e) { return e.name }).concat(c.extraSupported || [])
                    cats.push({ id: c.id, name: c.name || c.id, searchable: extras.indexOf("search") >= 0 })
                }
                window.youtubioCatalogs = cats
            } catch(e) {}
        }
        xhr.send()
    }

    // Browse a YouTubio catalog (a channel/playlist feed) into the ytResults grid.
    function youtubioLoadCatalog(catId) {
        if (!window.youtubioReady) return
        window.ytSource = "youtubio"
        window.ytView = "videos"
        window.youtubioCatalog = catId
        searchInput.text = ""
        ytResults.clear(); ytChannels.clear()
        ytSearchProc.running = false
        window.isSearchingYt = true
        var url = window.youtubioBase + "/catalog/YouTube/" + catId + ".json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.isSearchingYt = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isSearchingYt = false
            if (xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText)
                    var ms = res.metas || []
                    for (var i = 0; i < ms.length; i++) {
                        var vid = (ms[i].id || "").replace(/^yt_id:/, "")
                        if (!vid) continue
                        var ch = ytMetaChannel(ms[i])
                        ytResults.append({ vid: vid, title: ms[i].name || vid, channel: ch.name, channelId: ch.id,
                                           duration: ms[i].runtime || "", dateStr: ytRelDate(ms[i].released || ""), thumb: ms[i].poster || "" })
                    }
                } catch(e) {}
            }
        }
        xhr.send()
    }

    Process {
        id: ytSearchProc
        property string query: ""
        command: ["bash", window.videoCli, "search", "youtube", query]
        running: false
        stdout: SplitParser {
            onRead: (line) => {
                let l = (line || "").trim()
                if (l === "") return
                if (l === "__NOYTDLP__") { window.isSearchingYt = false; return }
                let parts = l.split("\t")
                let vid = parts[0]
                if (!vid) return
                ytResults.append({
                    vid: vid,
                    title: parts[1] && parts[1] !== "NA" ? parts[1] : vid,
                    channel: parts[2] && parts[2] !== "NA" ? parts[2] : "",
                    duration: parts[3] && parts[3] !== "NA" ? parts[3] : ""
                })
            }
        }
        onRunningChanged: { if (!running) window.isSearchingYt = false }
    }

    function ytDurationLabel(secs) {
        // YouTubio's patched catalogs hand a pre-formatted "m:ss"/"h:mm:ss" —
        // pass it through; raw seconds (legacy/yt-dlp paths) get formatted here.
        if (String(secs).indexOf(":") >= 0) return secs
        let n = parseInt(secs)
        if (!n || n <= 0) return ""
        let h = Math.floor(n / 3600), m = Math.floor((n % 3600) / 60), s = n % 60
        let pad = (x) => (x < 10 ? "0" + x : "" + x)
        return h > 0 ? (h + ":" + pad(m) + ":" + pad(s)) : (m + ":" + pad(s))
    }

    // Relative upload-date label from an ISO date ("3d ago" / "5mo ago" / "2y ago").
    function ytRelDate(iso) {
        if (!iso) return ""
        var t = Date.parse(iso)
        if (isNaN(t)) return ""
        var d = (Date.now() - t) / 86400000
        if (d < 0) return ""
        if (d < 1) return "today"
        if (d < 30) return Math.floor(d) + "d ago"
        if (d < 365) return Math.floor(d / 30) + "mo ago"
        return Math.floor(d / 365) + "y ago"
    }

    // ── Watch positions (how far into each video/episode you got) ──────────
    // Recorded every poll tick in-memory, flushed to disk (and to the UI via
    // the change signal) every 10s and on player close. Shown as progress
    // bars on episode rows and YouTube thumbnails.
    property var watchPos: ({})   // key → {p: seconds, d: duration, t: ts}
    Process {
        running: true
        command: ["bash", "-c", "cat " + window.moviesCache + "/qs_watch_pos.json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector { onStreamFinished: {
            try { var d = JSON.parse((this.text || "{}").trim() || "{}"); if (d && typeof d === "object") window.watchPos = d } catch (e) {}
        } }
    }
    function watchPosKey() {
        if (window.playerKind === "youtube") return window.currentYtId ? ("yt:" + window.currentYtId) : ""
        if (window.playerKind === "tv" || window.playerKind === "anime")
            return window.selectedImdbId ? (window.selectedImdbId + ":s" + window.playerSeason + "e" + window.playerEpisode) : ""
        if (window.playerKind === "movie") return window.playerImdb ? ("mov:" + window.playerImdb) : ""
        return ""
    }
    function recordWatchPos() {
        if (window.playerDur < 60 || window.playerPos < 5) return
        var k = watchPosKey()
        if (k === "") return
        window.watchPos[k] = { p: Math.floor(window.playerPos), d: Math.floor(window.playerDur), t: Date.now() }
    }
    function flushWatchPos() {
        window.watchPosChanged()   // refresh progress bars
        saveJsonToCache("qs_watch_pos.json", window.watchPos)
    }
    Timer { interval: 10000; repeat: true; running: window.currentView === "player"; onTriggered: { recordWatchPos(); flushWatchPos() } }
    // Fraction watched for a key (≥97% counts as fully watched).
    function watchFrac(key) {
        var e = window.watchPos[key]
        if (!e || !e.d || e.d <= 0) return 0
        var f = e.p / e.d
        return f > 0.97 ? 1 : Math.max(0, Math.min(1, f))
    }

    function addToWatchHistory(item) {
        for (let i = 0; i < watchHistoryModel.count; i++) {
            if (watchHistoryModel.get(i).imdbId === item.imdbId) {
                watchHistoryModel.remove(i)
                break
            }
        }
        watchHistoryModel.insert(0, item)
        if (watchHistoryModel.count > 15) watchHistoryModel.remove(15)
        saveWatchHistory()
        // MAL-style auto-tracking: anything you play shelves itself into the
        // library as "Watching" (fresh items, and plan-to-watch gets promoted).
        // A status you set by hand (completed / on hold / dropped) is respected.
        var st = libStatusOf(item.imdbId)
        if (st === "" || st === "plan_to_watch")
            libSet({ imdbId: item.imdbId, title: item.title, poster: item.poster || "",
                     type: item.type || "" }, "watching", true)
    }

    function removeFromContinue(imdbId) {
        for (let i = 0; i < watchHistoryModel.count; i++) {
            if (watchHistoryModel.get(i).imdbId === imdbId) { watchHistoryModel.remove(i); break }
        }
        saveWatchHistory()
    }

    // Record/refresh a show in "Continue Watching" at the season/episode just
    // played. If that episode is the LAST of its season, drop the show instead —
    // the season is finished, so there's nothing to continue.
    function recordProgress(type, imdbId, title, poster, season, ep) {
        // Every episode play is recorded (resume info). Completion is NOT
        // decided here (this runs when an episode STARTS): the show moves to
        // Completed only when the final aired episode actually FINISHES —
        // see maybeCompleteSeries() (credits-exit and EOF both count, and
        // weekly airing shows are excluded until their season is fully out).
        addToWatchHistory({ imdbId: imdbId, title: title, poster: poster, type: type, season: season, ep: ep })
    }

    function addSearchHistory(query) {
        if (query.trim() === "") return
        for (let i = 0; i < searchHistoryModel.count; i++) {
            if (searchHistoryModel.get(i).query.toLowerCase() === query.toLowerCase()) {
                searchHistoryModel.remove(i)
                break
            }
        }
        searchHistoryModel.insert(0, { query: query.trim() })
        if (searchHistoryModel.count > 10) searchHistoryModel.remove(10)
        saveHistory()
    }

    // --- DATA FETCHING & FILTERING ---
    // Cinemeta's "top" catalog paginates via /skip=N.json (~50 per page). Fetch
    // several pages in sequence and accumulate (deduped) so the home grid goes on
    // for hundreds of titles instead of the ~46 of page one.
    // Effectively "as far as Cinemeta will go" — pagination stops when a page
    // yields no new titles; this only guards against a runaway server.
    readonly property int trendingMaxItems: 5000
    function fetchTrending(typeStr) {
        let isMovie = typeStr === "movie"
        if (isMovie) window.isFetchingMovies = true; else window.isFetchingTv = true
        let targetModel = isMovie ? cachedTrendingMovies : cachedTrendingTv
        targetModel.clear()
        let rawItems = []
        let seen = ({})
        let base = "https://v3-cinemeta.strem.io/catalog/" + typeStr + "/top"

        function finish() {
            if (isMovie) window.isFetchingMovies = false; else window.isFetchingTv = false
            if (isMovie) { window.rawTrendingMovies = rawItems; window.trendingMoviesLastFetch = Date.now(); window.trendingMoviesLoaded = true }
            else { window.rawTrendingTv = rawItems; window.trendingTvLastFetch = Date.now(); window.trendingTvLoaded = true }
            saveTrendingCache()
        }
        function fetchPage(skip) {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", skip > 0 ? (base + "/skip=" + skip + ".json") : (base + ".json"))
            xhr.onerror = function() { finish() }
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                let added = 0
                if (xhr.status === 200) {
                    try {
                        let res = JSON.parse(xhr.responseText)
                        if (res && res.metas) {
                            for (let i = 0; i < res.metas.length; i++) {
                                let item = res.metas[i]
                                if (!item.id || !item.poster || seen[item.id]) continue
                                seen[item.id] = true
                                let entry = {
                                    imdbId: item.id,
                                    title: item.name || "Unknown",
                                    poster: item.poster || item.posterShape || item.background || item.logo || "",
                                    type: isMovie ? "movie" : "tv",
                                    year: item.releaseInfo || "N/A",
                                    rating: parseFloat(item.imdbRating) || 0,
                                    popularity: rawItems.length
                                }
                                rawItems.push(entry)
                                targetModel.append(entry)   // grid grows as pages arrive
                                added++
                            }
                        }
                    } catch(e) {}
                }
                // Keep paging while a page still yields new titles and we're under the cap.
                if (added > 0 && rawItems.length < window.trendingMaxItems && skip < 20000)
                    fetchPage(skip === 0 ? 50 : skip + 50)
                else
                    finish()
            }
            xhr.send()
        }
        fetchPage(0)
    }

    function getSortValue(item, field) {
        if (field === "year") return parseInt(item.year || item.releaseInfo || 0) || 0
        if (field === "title") return (item.title || item.name || "").toString()
        if (field === "rating") return parseFloat(item.rating || item.imdbRating || 0) || 0
        return 0
    }

    function sortItems(items) {
        let mode = window.filterSort
        if (mode === "Year (Newest)") items.sort((a, b) => getSortValue(b, "year") - getSortValue(a, "year"))
        else if (mode === "Year (Oldest)") items.sort((a, b) => getSortValue(a, "year") - getSortValue(b, "year"))
        else if (mode === "Title (A-Z)") items.sort((a, b) => getSortValue(a, "title").localeCompare(getSortValue(b, "title")))
        else if (mode === "Title (Z-A)") items.sort((a, b) => getSortValue(b, "title").localeCompare(getSortValue(a, "title")))
        else if (mode === "Rating (Best)") items.sort((a, b) => getSortValue(b, "rating") - getSortValue(a, "rating"))
        else if (mode === "Rating (Worst)") items.sort((a, b) => getSortValue(a, "rating") - getSortValue(b, "rating"))
        return items
    }

    function applyFiltersToPopular() {
        let rawMovies = sortItems(window.rawTrendingMovies.slice())
        let rawTv = sortItems(window.rawTrendingTv.slice())
        let rawAnime = sortItems(window.rawTrendingAnime.slice())
        cachedTrendingMovies.clear(); for (let i = 0; i < rawMovies.length; i++) cachedTrendingMovies.append(rawMovies[i])
        cachedTrendingTv.clear(); for (let i = 0; i < rawTv.length; i++) cachedTrendingTv.append(rawTv[i])
        cachedTrendingAnime.clear(); for (let i = 0; i < rawAnime.length; i++) cachedTrendingAnime.append(rawAnime[i])
        movieGrid.positionViewAtBeginning()
        tvGrid.positionViewAtBeginning()
        animeGrid.positionViewAtBeginning()
    }

    function applyFiltersAndPopulate() {
        window.isKeyboardNav = false
        searchResults.clear()
        let items = sortItems(window.currentFetchResults.slice())
        for (let i = 0; i < items.length; i++) {
            let item = items[i]
            if (!item.id) continue
            searchResults.append({
                imdbId: item.id, title: item.name || "Unknown", poster: item.poster || "",
                type: item.type === "series" ? "tv" : "movie", year: item.releaseInfo || "N/A", rating: parseFloat(item.imdbRating) || 0
            })
        }
        Qt.callLater(function() {
            if (searchGrid && searchGrid.count > 0) searchGrid.currentIndex = 0
            if (movieGrid && movieGrid.count > 0) movieGrid.currentIndex = 0
            if (tvGrid && tvGrid.count > 0) tvGrid.currentIndex = 0
        })
    }

    function doSearch(query) {
        let q = encodeURIComponent(query.trim())
        let expectedType = window.mediaType
        let isAnime = expectedType === "anime"
        let typeStr = expectedType === "movie" ? "movie" : "series"
        if (q === "") { searchResults.clear(); window.isSearchingNetwork = false; return }
        addSearchHistory(query)
        window.isSearchingNetwork = true
        searchResults.clear()
        // Anime → keyless Kitsu addon search; movies/TV → Cinemeta.
        let url = isAnime
            ? ("https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-list/search=" + q + ".json")
            : ("https://v3-cinemeta.strem.io/catalog/" + typeStr + "/top/search=" + q + ".json")
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.onerror = function() { window.isSearchingNetwork = false }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (window.mediaType === expectedType) {
                window.isSearchingNetwork = false
                if (xhr.status === 200) {
                    try {
                        let res = JSON.parse(xhr.responseText)
                        if (res && res.metas) {
                            window.currentFetchResults = res.metas
                            applyFiltersAndPopulate()
                            // Kitsu already returns posters; only Cinemeta needs enrichment.
                            if (!isAnime) enrichSearchPosters(res.metas, typeStr)
                        }
                    } catch(e) {}
                }
            }
        }
        xhr.send()
    }

    function enrichSearchPosters(metas, typeStr) {
        for (let i = 0; i < metas.length; i++) {
            let item = metas[i]
            if (item.poster && item.poster !== "") continue
            let capturedImdbId = item.id
            ;(function(cImdbId) {
                var xhr2 = new XMLHttpRequest()
                xhr2.open("GET", "https://v3-cinemeta.strem.io/meta/" + typeStr + "/" + cImdbId + ".json")
                xhr2.onreadystatechange = function() {
                    if (xhr2.readyState !== XMLHttpRequest.DONE) return
                    if (xhr2.status === 200) {
                        try {
                            let res2 = JSON.parse(xhr2.responseText)
                            if (res2 && res2.meta) {
                                let poster = res2.meta.poster || res2.meta.background || ""
                                if (poster !== "") {
                                    for (let j = 0; j < searchResults.count; j++) {
                                        if (searchResults.get(j).imdbId === cImdbId) {
                                            searchResults.setProperty(j, "poster", poster)
                                            break
                                        }
                                    }
                                    return
                                }
                            }
                        } catch(e) {}
                    }
                    fetchPosterFallback(cImdbId, typeStr)
                }
                xhr2.send()
            })(capturedImdbId)
        }
    }

    function fetchPosterFallback(imdbId, typeStr) {
        let rpdbUrl = "https://api.ratingposterdb.com/imdb/poster-default/" + imdbId + ".jpg"
        var xhrCheck = new XMLHttpRequest()
        xhrCheck.open("HEAD", rpdbUrl, true)
        xhrCheck.timeout = 5000
        xhrCheck.onreadystatechange = function() {
            if (xhrCheck.readyState !== XMLHttpRequest.DONE) return
            if (xhrCheck.status === 200) {
                for (let j = 0; j < searchResults.count; j++) {
                    if (searchResults.get(j).imdbId === imdbId) {
                        searchResults.setProperty(j, "poster", rpdbUrl)
                        break
                    }
                }
            }
        }
        xhrCheck.onerror = function() { /* silently fail — delegate shows title fallback */ }
        xhrCheck.send()
    }

    function fetchAndUpdatePoster(imdbId, typeStr, targetModel) {
        var xhr = new XMLHttpRequest()
        let metaType = typeStr === "tv" ? "series" : "movie"
        xhr.open("GET", "https://v3-cinemeta.strem.io/meta/" + metaType + "/" + imdbId + ".json")
        xhr.timeout = 6000
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            let posterFound = ""
            if (xhr.status === 200) {
                try {
                    let res = JSON.parse(xhr.responseText)
                    if (res && res.meta) posterFound = res.meta.poster || res.meta.background || ""
                } catch(e) {}
            }
            if (posterFound !== "") {
                for (let j = 0; j < targetModel.count; j++) {
                    if (targetModel.get(j).imdbId === imdbId) {
                        targetModel.setProperty(j, "poster", posterFound)
                        break
                    }
                }
            } else {
                fetchPosterFallback(imdbId, metaType)
            }
        }
        xhr.onerror = function() { fetchPosterFallback(imdbId, metaType) }
        xhr.send()
    }

    function fetchSeriesData(imdbId, targetSeason, title, poster, isReload) {
        if (!isReload) {
            window.selectedImdbId = imdbId
            window.selectedTitle = title
            window.selectedPoster = poster
            window.selectedDescription = ""
            window.selectedBackground = ""   // banner art arrives with the meta
            window.currentView = "series"
            window.forceActiveFocus()
        }
        // Sub/dub counts + AllAnime match index — also on isReload (cold state
        // restore), or playback falls back to result #1: the wrong-show bug.
        if (window.selectedIsAnime) fetchAnimeEpCounts(isReload ? window.selectedTitle : title)
        window.isLoadingSeries = true
        seasonModel.clear()
        episodeModel.clear()

        var xhr = new XMLHttpRequest()
        // Anime episodes come from the Kitsu addon; TV from Cinemeta.
        let metaUrl = window.selectedIsAnime
            ? ("https://anime-kitsu.strem.fun/meta/anime/" + imdbId + ".json")
            : ("https://v3-cinemeta.strem.io/meta/series/" + imdbId + ".json")
        xhr.open("GET", metaUrl)
        xhr.onerror = function() {
            window.isLoadingSeries = false
            if (isReload && window.pendingSeriesFocusRestore) seriesFocusRestoreTimer.restart()
        }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            window.isLoadingSeries = false
            if (xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText)
                    if (res && res.meta) {
                        if (!isReload || !window.selectedDescription) window.selectedDescription = res.meta.description || res.meta.synopsis || ""
                        if ((!window.selectedPoster || window.selectedPoster === "") && res.meta.poster) window.selectedPoster = res.meta.poster
                        if (res.meta.background) window.selectedBackground = res.meta.background
                        
                        if (res.meta.videos) {
                            let seasonsMap = {}
                            let hasUpcoming = false
                            let now = Date.now()
                            for (let i = 0; i < res.meta.videos.length; i++) {
                                let v = res.meta.videos[i]
                                if (v.season === 0) continue
                                // Weekly-airing detector: Cinemeta lists announced future
                                // episodes with future release dates — any of those means
                                // the season is still coming out.
                                let rel = Date.parse(v.released || v.firstAired || "")
                                if (!isNaN(rel) && rel > now) { hasUpcoming = true; continue }   // don't list unaired eps either
                                if (!seasonsMap[v.season]) seasonsMap[v.season] = []
                                let epTitle = v.name || v.title || null
                                if (epTitle && /^(episode\s*\d+|s\d+e\d+|ep\.?\s*\d+)$/i.test(epTitle.toLowerCase().trim())) epTitle = null
                                seasonsMap[v.season].push({
                                    ep: v.episode,
                                    title: epTitle || ("Episode " + v.episode),
                                    hasRealTitle: epTitle !== null,
                                    overview: v.overview || v.description || "",
                                    thumb: v.thumbnail || ""
                                })
                            }
                            let seasonKeys = Object.keys(seasonsMap).map(Number).sort((a, b) => a - b)
                            for (let i = 0; i < seasonKeys.length; i++) seasonModel.append({ seasonNum: seasonKeys[i] })
                            window.seriesDataMap = seasonsMap
                            // Auto-complete bookkeeping: the TRUE last aired episode, and
                            // whether the series has finished airing at all.
                            window.seriesFullyAired = !hasUpcoming
                            var lastS = seasonKeys.length ? seasonKeys[seasonKeys.length - 1] : 0
                            window.seriesLastSeason = lastS
                            var lastE = 0
                            if (lastS > 0) for (let i = 0; i < seasonsMap[lastS].length; i++)
                                if (seasonsMap[lastS][i].ep > lastE) lastE = seasonsMap[lastS][i].ep
                            window.seriesLastEp = lastE
                            
                            let newTargetSeason = seasonsMap[targetSeason] ? targetSeason : (seasonKeys[0] || 1)
                            window.currentSeason = newTargetSeason
                            updateEpisodes(newTargetSeason)
                        }
                    }
                } catch(e) {}
            }
            if (isReload && window.pendingSeriesFocusRestore) seriesFocusRestoreTimer.restart()
            if (!isReload) saveUiState()
        }
        xhr.send()
    }

    function loadSeriesDetails(imdbId, title, poster) {
        window.selectedIsAnime = false
        fetchSeriesData(imdbId, 1, title, poster, false)
    }

    // Anime uses the same series/episode page, but episodes come from Kitsu.
    function loadAnimeDetails(item) {
        window.selectedIsAnime = true
        fetchSeriesData(item.imdbId, 1, item.title, item.poster, false)
    }

    // Fire-and-forget background resolver: finds the title/episode and plays it
    // in the PiP from the start. mov-cli for movies/TV, ani-cli for anime — both
    // run fully headless (no terminal, no prompts) via the video CLI (video play …).
    function playFromStart(kind, title, season, ep) {
        // Self-limit gate for movies/tv/anime: counts the watch, or blocks + locks.
        // Runs synchronously right after the caller's enterPlayer(), so reverting the
        // view here produces no visible flash.
        if (window.gatedKeys.indexOf(kind) >= 0 && !mediaCanWatch()) {
            window.currentView = "search"
            return
        }
        window.currentYtId = ""   // non-youtube source
        window.playerKind = kind
        window.playerSeason = season
        window.playerEpisode = ep
        refreshPlayerComments()
        var args = ["bash", window.videoCli, "play", kind, title]
        if (kind === "tv") { args.push(String(season)); args.push(String(ep)) }
        else if (kind === "anime") {
            args.push(String(ep)); args.push(window.animeDub ? "dub" : "sub")
            args.push(String(window.animeDub ? window.animeDubIdx : window.animeSubIdx))
        }
        Quickshell.execDetached(args)
    }

    function playSelectedEpisode(epNum) {
        enterPlayer(window.selectedTitle)
        window.playerImdb = window.selectedImdbId || ""
        var type = window.selectedIsAnime ? "anime" : "tv"
        recordProgress(type, window.selectedImdbId, window.selectedTitle, window.selectedPoster, window.currentSeason, epNum)
        if (window.selectedIsAnime) playFromStart("anime", window.selectedTitle, 0, epNum)
        else playFromStart("tv", window.selectedTitle, window.currentSeason, epNum)
        if (window.upNextOpen) buildUpNext()
    }

    // ── "Up next": when a video nears its end (credits/outro), offer the next one. ──
    // "Near end" is metadata-driven: the trigger window scales with the video's
    // own duration (4%, clamped 8s…75s) instead of a fixed distance — a 3-min
    // YouTube clip prompts in its last ~8s, a 40-min episode over its credits.
    readonly property real playerEndWindow: Math.min(75, Math.max(8, window.playerDur * 0.04))
    readonly property bool playerNearEnd: window.playerDur > 30 && window.playerPos >= window.playerDur - playerEndWindow

    // ── Anime dub/sub ───────────────────────────────────────────────────────
    // AllAnime carries separate sub and dub episode counts (dubs lag) — the
    // series page shows both and caps the episode list to the selected mode,
    // so "latest episode" means the latest OF THAT MODE. ani-cli gets --dub.
    property bool animeDub: false
    property int animeSubEps: 0
    property int animeDubEps: 0
    // 1-based AllAnime result index per mode — passed to ani-cli -S so playback
    // selects the same show the counts came from (not blindly the first hit).
    property int animeSubIdx: 1
    property int animeDubIdx: 1
    Process {
        id: animeEpCountProc
        property string forTitle: ""
        running: false
        command: ["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/video/lib/anime_epcount.sh", forTitle]
        stdout: StdioCollector { onStreamFinished: {
            try {
                var d = JSON.parse((this.text || "{}").trim() || "{}")
                window.animeSubEps = d.sub || 0
                window.animeDubEps = d.dub || 0
                window.animeSubIdx = d.subIdx || 1
                window.animeDubIdx = d.dubIdx || 1
                if (window.currentView === "series" && window.selectedIsAnime) updateEpisodes(window.currentSeason)
            } catch (e) {}
        } }
    }
    function fetchAnimeEpCounts(title) {
        window.animeSubEps = 0; window.animeDubEps = 0
        window.animeSubIdx = 1; window.animeDubIdx = 1
        animeEpCountProc.forTitle = title
        animeEpCountProc.running = false; animeEpCountProc.running = true
    }
    function setAnimeDub(v) {
        if (window.animeDub === v) return
        window.animeDub = v
        saveUiState()
        if (window.currentView === "series" && window.selectedIsAnime) updateEpisodes(window.currentSeason)
    }

    // ── Series auto-complete ────────────────────────────────────────────────
    // Finishing the LAST episode of the LAST season moves the show from
    // Watching → Completed. "Finishing" = reaching the credits window
    // (playerNearEnd), so backing out during the end credits counts, not just
    // 100%. Weekly shows are excluded: seriesFullyAired is false while
    // Cinemeta still lists future-dated episodes, so watching this week's
    // newest episode never completes an airing show.
    property bool seriesFullyAired: false
    property int seriesLastSeason: 0
    property int seriesLastEp: 0
    function maybeCompleteSeries() {
        if (window.playerKind !== "tv" && window.playerKind !== "anime") return
        if (!window.playerNearEnd) return
        if (!window.seriesFullyAired) return
        if (window.seriesLastSeason <= 0 || window.seriesLastEp <= 0) return
        if (window.playerSeason !== window.seriesLastSeason) return
        if (window.playerEpisode !== window.seriesLastEp) return
        var st = libStatusOf(window.selectedImdbId)
        if (st === "" || st === "watching" || st === "plan_to_watch") {
            libSet({ imdbId: window.selectedImdbId, title: window.selectedTitle,
                     poster: window.selectedPoster, type: window.playerKind }, "completed", true)
            removeFromContinue(window.selectedImdbId)
        }
    }
    function playerHasNextEpisode() {
        if (window.playerKind !== "tv" && window.playerKind !== "anime") return false
        if (window.playerEpisode <= 0) return false
        if (episodeModel.count === 0) return true   // episode list not loaded — assume there's a next
        var nx = window.playerEpisode + 1
        for (var i = 0; i < episodeModel.count; i++) if (episodeModel.get(i).epNum === nx) return true
        return false
    }
    function playerNextYoutubeIndex() {
        if (window.playerKind !== "youtube" || window.currentYtId === "") return -1
        for (var i = 0; i < ytResults.count; i++)
            if (ytResults.get(i).vid === window.currentYtId) return (i + 1 < ytResults.count) ? i + 1 : -1
        return -1
    }
    function playerHasNext() { return playerHasNextEpisode() || playerNextYoutubeIndex() >= 0 }
    function playerNextLabel() { return window.playerKind === "youtube" ? "Next video" : "Next episode" }
    // Auto-advance only when it won't conflict with the watch limit (non-consuming check).
    property bool autoAdvanced: false
    function mediaAutoAdvanceOk() {
        if (window.gatedKeys.indexOf(window.playerKind) < 0) return true   // youtube/music: not limited
        if (window.focusMode === "gaming") return true                    // no limit while gaming
        if (window.mediaIsLocked()) return false
        if (window.mediaAllowance < 0) return false
        return window.mediaWatched < window.mediaAllowance                // a slot is still free
    }
    function playerPlayNext() {
        if (window.playerKind === "tv" || window.playerKind === "anime") {
            playSelectedEpisode(window.playerEpisode + 1)
        } else if (window.playerKind === "youtube") {
            var n = playerNextYoutubeIndex()
            if (n >= 0) { var it = ytResults.get(n); playYouTube(it.vid, it.title, it.channelId, it.channel) }
        }
    }

    // Show the in-widget mpv player (the embedded MpvItem fills the widget).
    function enterPlayer(title) {
        if (title && title !== "") window.selectedTitle = title
        playerView.ytPageOff = 0   // any new playback starts scrolled to the video
        // slang is only a LOAD-TIME hint so something reasonable shows in the
        // first second; the player poll's applySubLangNow() is what actually
        // decides the track (deterministically, for every language).
        embeddedMpv.setProperty("slang", (window.subLangCodes[window.subLang] || []).join(","))
        window.subAutoApplied = false; window.subApplyTicks = 0
        window.playerStatus = "Finding source…"
        window.commentsOpen = false       // comments start closed; open via the toggle
        window.playerFullscreen = false
        window.playerSettingsOpen = false
        window.playerSpeed = 1.0; window.playerRes = "Auto"   // subsOn persists across plays
        window.sbSegments = []; window.playerPrevPos = 0
        window.aiOpen = false; window.aiText = ""; window.aiMsg = ""; window.aiLoading = false
        window.currentVideoChannel = ""; window.currentVideoDescription = ""
        window.currentVideoChannelId = ""; window.currentVideoDate = ""
        window.playerPos = 0; window.playerDur = 0; window.playerPaused = false
        window.autoAdvanced = false
        window.videoAspect = 0
        commentsModel.clear()
        window.currentView = "player"
        saveUiState()
    }

    // Called by each play path once the source context is set: prefetch comments
    // in the background ("cache on start") so the panel opens instantly. Music has
    // no comments, so skip it there.
    function refreshPlayerComments() {
        if (window.currentView === "player" && window.playerKind !== "music") fetchComments()
    }

    // Poll mpv for position / duration / pause so the seek bar + play-pause
    // glyph stay in sync. Runs only while the player view is up.
    Timer {
        id: playerPollTimer
        interval: 400; repeat: true
        running: window.currentView === "player"
        onTriggered: {
            var dur = embeddedMpv.getProperty("duration")
            window.playerDur = (typeof dur === "number" && dur > 0) ? dur : 0
            // Subtitle selection on (re)load: once the file is up (duration
            // known), pick the preferred track ourselves — and once more ~2s
            // later for caption tracks that trickle in after the demuxer opens.
            if (window.playerDur > 0) {
                if (!window.subAutoApplied) {
                    window.subAutoApplied = true
                    window.subApplyTicks = 5
                    applySubLangNow()
                } else if (window.subApplyTicks > 0 && --window.subApplyTicks === 0) {
                    applySubLangNow()
                }
            } else {
                window.subAutoApplied = false; window.subApplyTicks = 0
            }
            if (!window.seekDragging) {
                var pos = embeddedMpv.getProperty("time-pos")
                window.playerPos = (typeof pos === "number" && pos >= 0) ? pos : 0
            }
            window.playerPaused = embeddedMpv.getProperty("pause") === true
            // SponsorBlock auto-skip: only on NATURAL forward entry (the playhead
            // crosses the segment start between polls), once per segment. A
            // backward scrub never triggers this — see seekMouse.onReleased.
            if (window.autoSkip && !window.seekDragging && window.sbSegments.length > 0) {
                for (var sbi = 0; sbi < window.sbSegments.length; sbi++) {
                    var sg = window.sbSegments[sbi]
                    if (!sg.skipped && window.playerPrevPos < sg.start + 0.5
                            && window.playerPos >= sg.start && window.playerPos < sg.end) {
                        sg.skipped = true
                        window.sbSegmentsChanged()
                        embeddedMpv.command(["seek", String(sg.end), "absolute"])
                        window.playerPos = sg.end
                        break
                    }
                }
            }
            window.playerPrevPos = window.playerPos
            // Auto-advance: keep-open=yes pauses at EOF with eof-reached=true. Advance to the
            // next episode/video — but only if it won't conflict with the watch limit.
            if (embeddedMpv.getProperty("eof-reached") === true) {
                maybeCompleteSeries()   // ran to the very end (idempotent: only fires once)
                if (!window.autoAdvanced && playerHasNext() && mediaAutoAdvanceOk()) {
                    window.autoAdvanced = true
                    playerPlayNext()
                }
            } else if (window.autoAdvanced) {
                window.autoAdvanced = false   // new media playing → re-arm
            }
            // Display dims (post-aspect); update only on real change so Main.qml
            // resizes the window to the movie ratio once per video, not every tick.
            var dw = embeddedMpv.getProperty("dwidth")
            var dh = embeddedMpv.getProperty("dheight")
            if (typeof dw === "number" && dw > 0 && typeof dh === "number" && dh > 0) {
                var a = dw / dh
                if (Math.abs(a - window.videoAspect) > 0.001) window.videoAspect = a
            }
        }
    }

    function fmtTime(sec) {
        if (!sec || sec < 0) return "0:00"
        var s = Math.floor(sec % 60), m = Math.floor((sec / 60) % 60), h = Math.floor(sec / 3600)
        var ss = (s < 10 ? "0" : "") + s
        if (h > 0) { var mm = (m < 10 ? "0" : "") + m; return h + ":" + mm + ":" + ss }
        return m + ":" + ss
    }

    function seekToFraction(frac) {
        if (window.playerDur <= 0) return
        frac = Math.max(0, Math.min(1, frac))
        embeddedMpv.command(["seek", String(frac * window.playerDur), "absolute"])
        window.playerPos = frac * window.playerDur
    }

    // --- Comments side panel ---
    // Per-section source: YouTube → yt-dlp; movies/TV → Trakt; anime → Reddit
    // (r/anime episode-discussion threads). All emit the same NDJSON of
    // {author,text,likes[,spoiler]} consumed by handleCommentLine().
    ListModel { id: commentsModel }
    function handleCommentLine(line) {
        let l = (line || "").trim()
        if (l === "") return
        if (l === "__NOYTDLP__") { window.commentsLoading = false; window.commentsMsg = "yt-dlp is not installed."; return }
        if (l === "__NOKEY__")   {
            window.commentsLoading = false
            window.commentsMsg = window.playerKind === "anime"
                ? "Add \"reddit_client_id\" to ~/.config/hypr/config.json to enable anime comments."
                : "Add \"trakt_client_id\" to ~/.config/hypr/config.json to enable comments."
            return
        }
        if (l === "__ERR__")     { window.commentsLoading = false; window.commentsMsg = "Couldn't load comments."; return }
        if (l === "__NONE__")    { window.commentsLoading = false; window.commentsMsg = "No comments found."; return }
        try {
            let c = JSON.parse(l)
            commentsModel.append({ author: c.author || "", text: c.text || "", likes: c.likes || 0, spoiler: c.spoiler || false })
            window.commentsLoading = false
            window.commentsMsg = ""
        } catch(e) {}
    }
    function commentsProcDone(proc) {
        if (!proc.running && window.commentsLoading && commentsModel.count === 0 && window.commentsMsg === "") {
            window.commentsMsg = "No comments found."
            window.commentsLoading = false
        }
    }

    Process {
        id: ytCommentsProc
        property string vid: ""
        command: ["bash", window.pipDir + "/yt_comments.sh", vid]
        running: false
        stdout: SplitParser { onRead: (line) => window.handleCommentLine(line) }
        onRunningChanged: window.commentsProcDone(ytCommentsProc)
    }
    Process {
        id: traktCommentsProc
        property string kind: ""   // movie | show
        property string imdb: ""
        property string season: ""
        property string episode: ""
        command: ["bash", window.pipDir + "/trakt_comments.sh", kind, imdb, season, episode]
        running: false
        stdout: SplitParser { onRead: (line) => window.handleCommentLine(line) }
        onRunningChanged: window.commentsProcDone(traktCommentsProc)
    }
    Process {
        id: redditCommentsProc
        property string title: ""
        property string episode: ""
        command: ["bash", window.pipDir + "/reddit_comments.sh", title, episode]
        running: false
        stdout: SplitParser { onRead: (line) => window.handleCommentLine(line) }
        onRunningChanged: window.commentsProcDone(redditCommentsProc)
    }

    function fetchComments() {
        commentsModel.clear()
        window.commentsMsg = ""
        ytCommentsProc.running = false
        traktCommentsProc.running = false
        redditCommentsProc.running = false
        window.commentsLoading = true

        if (window.playerKind === "youtube" || window.currentYtId !== "") {
            ytCommentsProc.vid = window.currentYtId
            ytCommentsProc.running = true
        } else if (window.playerKind === "movie") {
            if (window.playerImdb === "") { window.commentsLoading = false; window.commentsMsg = "No comments source for this title."; return }
            traktCommentsProc.kind = "movie"; traktCommentsProc.imdb = window.playerImdb
            traktCommentsProc.season = ""; traktCommentsProc.episode = ""
            traktCommentsProc.running = true
        } else if (window.playerKind === "tv") {
            if (window.playerImdb === "") { window.commentsLoading = false; window.commentsMsg = "No comments source for this title."; return }
            traktCommentsProc.kind = "show"; traktCommentsProc.imdb = window.playerImdb
            traktCommentsProc.season = String(window.playerSeason); traktCommentsProc.episode = String(window.playerEpisode)
            traktCommentsProc.running = true
        } else if (window.playerKind === "anime") {
            redditCommentsProc.title = window.selectedTitle
            redditCommentsProc.episode = String(window.playerEpisode)
            redditCommentsProc.running = true
        } else {
            window.commentsLoading = false
            window.commentsMsg = "No comments available."
        }
    }
    // Toggle the comments panel. Comments are prefetched on video start, so this
    // only fetches if that hasn't run yet (no cache, not loading, no result msg).
    function toggleComments() {
        window.commentsOpen = !window.commentsOpen
        if (window.commentsOpen) { window.aiOpen = false; window.upNextOpen = false }   // one right panel at a time
        if (window.commentsOpen && commentsModel.count === 0 && !window.commentsLoading && window.commentsMsg === "") fetchComments()
    }

    // ── "Up next" side list: rest of the series (TV/anime) or more videos (YouTube) ──
    property bool upNextOpen: false
    ListModel { id: upNextModel }
    function toggleUpNext() {
        // Up next lives in the below-video page for every kind — the toggle
        // scrolls the page open/closed (the old side panel is retired).
        if (window.playerKind === "music") return
        if (playerView.ytPageOff > 0) playerView.ytPageOff = 0
        else {
            buildUpNext()
            window.commentsOpen = false; window.aiOpen = false
            playerView.ytPageOff = Math.min(playerView.ytPageMax, playerView.height * 0.62)
        }
    }
    // Pull the playing video's channel + description from YouTubio's meta endpoint.
    function fetchVideoInfo(vid) {
        window.currentVideoDescription = ""
        if (!vid || !window.youtubioReady) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", window.youtubioBase + "/meta/YouTube/yt_id:" + encodeURIComponent(vid) + ".json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var m = (JSON.parse(xhr.responseText).meta) || {}
                window.currentVideoDescription = m.description || ""
                window.currentVideoDate = ytRelDate(m.released || "")
                var ch = ytMetaChannel(m)
                if (ch.id && window.currentVideoChannelId === "") window.currentVideoChannelId = ch.id
                if (ch.name && window.currentVideoChannel === "") window.currentVideoChannel = ch.name
            } catch (e) {}
        }
        xhr.send()
    }
    function buildUpNext() {
        upNextModel.clear()
        if (window.playerKind === "tv" || window.playerKind === "anime") {
            for (var i = 0; i < episodeModel.count; i++) {
                var ep = episodeModel.get(i)
                if (ep.epNum > window.playerEpisode)
                    upNextModel.append({ kind: "episode", epNum: ep.epNum, vid: "",
                        title: (ep.hasRealTitle && ep.epTitle) ? ep.epTitle : ("Episode " + ep.epNum),
                        sub: "Episode " + ep.epNum, channelId: "", channel: "",
                        thumb: ep.epThumb || "", dur: "", dateStr: "", imdbId: "", poster: "" })
            }
        } else if (window.playerKind === "youtube") {
            for (var j = 0; j < ytResults.count; j++) {
                var v = ytResults.get(j)
                if (v.vid && v.vid !== window.currentYtId)
                    upNextModel.append({ kind: "video", epNum: 0, vid: v.vid,
                        title: v.title, sub: v.channel || "", channelId: v.channelId || "", channel: v.channel || "",
                        thumb: v.thumb || "", dur: v.duration || "", dateStr: v.dateStr || "", imdbId: "", poster: "" })
            }
        } else if (window.playerKind === "movie") {
            // Movies: "up next" = more movies — hero/top catalog first (has
            // backdrops for the 16:9 cards), topped up from the trending grid.
            var mh = (homeCategories["movie"] || [])[0]
            if (mh) homeFetchCat(mh.key, mh.url)   // warm the catalog if the homepage never ran
            var seenM = ({})
            var heroItems = homeCatItems("m-hero")
            for (var h = 0; h < heroItems.length && upNextModel.count < 12; h++) {
                var hm = heroItems[h]
                if (hm.imdbId === window.playerImdb || seenM[hm.imdbId]) continue
                seenM[hm.imdbId] = true
                upNextModel.append({ kind: "movie", epNum: 0, vid: "",
                    title: hm.title, sub: (hm.year || "") + (hm.rating > 0 ? "  ·  ★ " + hm.rating.toFixed(1) : ""),
                    channelId: "", channel: "",
                    thumb: hm.background || hm.poster || "", dur: "", dateStr: "",
                    imdbId: hm.imdbId, poster: hm.poster || "" })
            }
            for (var t = 0; t < cachedTrendingMovies.count && upNextModel.count < 12; t++) {
                var tm = cachedTrendingMovies.get(t)
                if (tm.imdbId === window.playerImdb || seenM[tm.imdbId]) continue
                seenM[tm.imdbId] = true
                upNextModel.append({ kind: "movie", epNum: 0, vid: "",
                    title: tm.title, sub: tm.year || "", channelId: "", channel: "",
                    thumb: tm.poster || "", dur: "", dateStr: "",
                    imdbId: tm.imdbId, poster: tm.poster || "" })
            }
        }
    }
    function upNextPlay(kind, epNum, vid, title, channelId, channel, imdbId, poster) {
        if (kind === "episode") playSelectedEpisode(epNum)
        else if (kind === "video") playYouTube(vid, title, channelId, channel)
        else if (kind === "movie" && imdbId) {
            addToWatchHistory({ imdbId: imdbId, title: title, poster: poster || "", type: "movie" })
            window.playerImdb = imdbId
            fetchMovieMeta(imdbId)
            enterPlayer(title)
            playFromStart("movie", title, 0, 0)
        }
    }

    // Movie synopsis for the player's below-video page (movies play straight
    // from a card, so nothing else loads their description).
    function fetchMovieMeta(imdbId) {
        window.selectedDescription = ""
        if (!imdbId) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "https://v3-cinemeta.strem.io/meta/movie/" + imdbId + ".json")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var m = (JSON.parse(xhr.responseText).meta) || {}
                if (window.playerImdb === imdbId) window.selectedDescription = m.description || ""
            } catch (e) {}
        }
        xhr.send()
    }

    // ── AI: "parse this video" via the local agent (web tools server-side) ──
    Process {
        id: aiParseProc
        property string kind: ""
        property string arg: ""
        property string question: ""   // empty = initial summary (no web); set = follow-up (web)
        command: question === ""
            ? ["bash", window.pipDir + "/ai_parse.sh", kind, arg]
            : ["bash", window.pipDir + "/ai_parse.sh", "--ask", question, kind, arg]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var t = (this.text || "").trim()
                window.aiLoading = false
                var wasAsk = aiParseProc.question !== ""
                var err = ""
                if (t === "") err = "No response."
                else if (t === "__NOAI__") err = "Local model is offline (llama.cpp :11434)."
                else if (t === "__WARMING__") err = "Local model is warming up (cold start — give it a couple minutes, then try again)."
                else if (t === "__ERR__") err = "AI request failed (check the model / transcript)."
                if (err !== "") {
                    if (wasAsk && window.aiText !== "")
                        window.aiText = window.aiText + "\n\n> ⚠ " + err
                    else window.aiMsg = err
                    aiParseProc.question = ""
                    return
                }
                if (wasAsk) {
                    window.aiText = window.aiText
                        + "\n\n---\n\n**You — " + aiParseProc.question + "**\n\n" + t
                } else {
                    window.aiText = t
                }
                window.aiMsg = ""
                aiParseProc.question = ""
            }
        }
    }
    function aiParse() {
        if (window.aiText !== "" || window.aiLoading) return   // cached / in flight
        window.aiMsg = ""; window.aiLoading = true
        aiParseProc.running = false
        aiParseProc.question = ""
        if (window.playerKind === "youtube" && window.currentYtId !== "") {
            aiParseProc.kind = "youtube"; aiParseProc.arg = window.currentYtId
        } else {
            aiParseProc.kind = window.playerKind || "video"; aiParseProc.arg = window.selectedTitle
        }
        aiParseProc.running = true
    }
    function aiAsk(q) {
        q = (q || "").trim()
        if (q === "" || window.aiLoading || window.aiText === "") return
        window.aiMsg = ""; window.aiLoading = true
        aiParseProc.running = false
        if (window.playerKind === "youtube" && window.currentYtId !== "") {
            aiParseProc.kind = "youtube"; aiParseProc.arg = window.currentYtId
        } else {
            aiParseProc.kind = window.playerKind || "video"; aiParseProc.arg = window.selectedTitle
        }
        aiParseProc.question = q
        aiParseProc.running = true
    }
    function toggleAi() {
        window.aiOpen = !window.aiOpen
        if (window.aiOpen) { window.commentsOpen = false; window.upNextOpen = false; aiParse() }
    }

    // ── Share / playback settings ──────────────────────────────────────────
    function sharePlayer() {
        var link = (window.playerKind === "youtube" && window.currentYtId !== "")
            ? "https://www.youtube.com/watch?v=" + window.currentYtId
            : window.selectedTitle
        if (!link || link === "") return
        Quickshell.execDetached(["wl-copy", "--", link])
        Quickshell.execDetached(["notify-send", "Copied to clipboard", link])
    }
    function setSpeed(v) {
        window.playerSpeed = v
        embeddedMpv.setProperty("speed", v)
    }
    property real playerVolume: 100
    function setVolume(v) {
        window.playerVolume = v
        embeddedMpv.setProperty("volume", v)
    }
    function toggleSubs() {
        window.subsOn = !window.subsOn
        embeddedMpv.setProperty("sub-visibility", window.subsOn)
        // Turning subs ON when no track got picked at load (slang mismatch, or
        // the language was changed mid-play): select the matching track now.
        if (window.subsOn) applySubLangNow()
    }
    // Resolution = re-pick the YouTube quality (ytdl-format) and reload at the
    // current position. Only meaningful for YouTube; movies/anime are a single
    // resolved stream.
    function setResolution(label, maxH) {
        if (window.playerKind !== "youtube" || window.currentYtId === "") return
        window.playerRes = label
        embeddedMpv.setProperty("ytdl-format", maxH > 0
            ? ("bestvideo[height<=?" + maxH + "]+bestaudio/best[height<=?" + maxH + "]")
            : "bestvideo+bestaudio/best")
        var pos = embeddedMpv.getProperty("time-pos")
        window._resumePos = (typeof pos === "number" && pos > 0) ? pos : 0
        Quickshell.execDetached(["bash", window.videoCli, "play", "youtube", window.currentYtId])
        resumeSeekTimer.tries = 0
        resumeSeekTimer.restart()
    }
    Timer {
        id: resumeSeekTimer
        interval: 1200; repeat: true
        property int tries: 0
        onTriggered: {
            tries++
            if (embeddedMpv.getProperty("idle-active") === false && embeddedMpv.getProperty("duration") > 0) {
                if (window._resumePos > 1) embeddedMpv.command(["seek", String(window._resumePos), "absolute"])
                stop()
            } else if (tries > 25) stop()
        }
    }

    // Hand the current stream off to a standalone floating mpv PiP window, then
    // drop back to browsing. Triggered by dragging the player's top bar down.
    function popOutToPip() {
        var url = embeddedMpv.getProperty("path")
        if (!url || url === "") return
        var pos = embeddedMpv.getProperty("time-pos")
        var start = (typeof pos === "number" && pos > 0) ? Math.floor(pos) : 0
        embeddedMpv.command(["stop"])
        Quickshell.execDetached(["bash", window.videoCli, "popout", String(url), String(start)])
        window.playerStatus = ""
        window.commentsOpen = false
        window.currentView = "search"
        saveUiState()
    }

    // While in the player with no media yet, poll mpv's idle state to show
    // "Finding source…" and, after a while, a "no source" hint (e.g. mov-cli
    // has no scraper). Clears as soon as a file actually loads.
    Timer {
        id: playerStatusTimer
        interval: 700; repeat: true
        running: window.currentView === "player"
        property int elapsed: 0
        onRunningChanged: { elapsed = 0; if (running) window.playerStatus = "Finding source…" }
        onTriggered: {
            var idle = embeddedMpv.getProperty("idle-active")
            if (idle === false) { window.playerStatus = ""; elapsed = 0; return }
            elapsed += interval
            window.playerStatus = elapsed > 35000
                ? "No source found.\nAnime uses ani-cli (works); movies/TV need a working mov-cli scraper plugin."
                : "Finding source…"
        }
    }
    function closePlayer() {
        maybeCompleteSeries()   // exiting during the end credits counts as finished
        recordWatchPos(); flushWatchPos()
        embeddedMpv.command(["stop"])
        window.playerStatus = ""
        window.commentsOpen = false
        window.playerFullscreen = false
        window.aiOpen = false
        window.currentYtId = ""
        // Go back where you came from: TV/anime → the series/episode page; otherwise
        // the search/movies grid.
        if ((window.playerKind === "tv" || window.playerKind === "anime") && window.selectedImdbId !== "") {
            window.currentView = "series"
        } else {
            window.currentView = "search"
            searchInput.forceActiveFocus()
        }
        saveUiState()
    }

    function updateEpisodes(seasonNum) {
        window.seasonSwitching = true
        seasonContentSwapTimer.targetSeason = seasonNum
        seasonContentSwapTimer.restart()
    }

    Timer {
        id: seasonContentSwapTimer
        property int targetSeason: 1
        interval: 220
        repeat: false
        onTriggered: {
            episodeModel.clear()
            let eps = window.seriesDataMap[targetSeason]
            if (eps) {
                eps.sort((a, b) => a.ep - b.ep)
                // Anime: cap the list at the selected mode's episode count —
                // dubs lag subs, so "latest" differs per mode.
                let cap = 0
                if (window.selectedIsAnime) cap = window.animeDub ? window.animeDubEps : window.animeSubEps
                for (let i = 0; i < eps.length; i++) {
                    if (cap > 0 && eps[i].ep > cap) continue
                    episodeModel.append({ epNum: eps[i].ep, epTitle: eps[i].title, hasRealTitle: eps[i].hasRealTitle || false, epDesc: eps[i].overview || "", epThumb: eps[i].thumb || "" })
                }
            }
            epList.currentIndex = 0
            epList.positionViewAtBeginning()
            seasonFadeInTimer.restart()
        }
    }

    Timer { id: seasonFadeInTimer; interval: 30; repeat: false; onTriggered: window.seasonSwitching = false }

    function getActiveGrid() {
        if (window.mediaType === "games") return null
        if (window.mediaType === "books") return booksGrid
        if (window.mediaType === "youtube") return ytGrid
        if (window.mediaType === "music") return musicGrid
        if (window.isSearchMode) return searchGrid
        if (window.mediaType === "movie") return movieGrid
        if (window.mediaType === "anime") return animeGrid
        return tvGrid
    }

    // Live page filter: on the YouTube history / playlists pages the search
    // box filters the page as you type (no Enter needed). The Channels page
    // instead searches channels through the normal debounce → runSearch path.
    readonly property string ytPageFilter:
        (window.mediaType === "youtube"
         && (window.ytView === "history" || window.ytView === "playlists"))
            ? searchInput.text.trim().toLowerCase() : ""

    // Dispatch the shared search box to the right backend for the active section.
    function runSearch(query) {
        // Every real search lands in recents — that feeds the typing dropdown.
        // Only movies/tv/anime recorded before, so the dropdown sat empty on
        // YouTube/music/books. The yt live-filter pages don't count as searches.
        var ytFilterPage = window.mediaType === "youtube"
                           && (window.ytView === "history" || window.ytView === "playlists")
        if (!ytFilterPage && window.mediaType !== "games") addSearchHistory(query)
        if (window.mediaType === "youtube") {
            // Search WHAT'S OPEN: the Channels page searches channels; the
            // filter pages (history/playlists) already filtered live, so Enter
            // keeps you there instead of yanking you to a video search.
            if (window.ytView === "channels") youtubioChannelSearch(query)
            else if (window.ytView === "history" || window.ytView === "playlists") { /* live filter */ }
            else ytSearchDispatch(query)
        }
        else if (window.mediaType === "music") musicSearch(query)
        else if (window.mediaType === "books") booksSearch(query)
        else if (window.mediaType === "games") { /* placeholder */ }
        else doSearch(query)
    }

    // Open a grid item per section: movie → background play now; tv/anime →
    // open the series/episode page, then a chosen episode plays in the PiP.
    function openItem(item, ret) {
        if (!item) return
        // Where the series page's Back should return to. Overlay openers (View
        // All page, Library browse) pass their context; everywhere else Back
        // falls through to the home/search view as before.
        window.seriesReturn = ret || null
        if (window.mediaType === "books") { openBook(item); return }
        // Resume: with the Continue Watching row gone, the watch history still
        // remembers where you were — reopen a tracked series on that season.
        for (var rh = 0; rh < watchHistoryModel.count; rh++) {
            var h = watchHistoryModel.get(rh)
            if (h.imdbId === item.imdbId && (h.type === "tv" || h.type === "anime")) { openHistoryItem(h); return }
        }
        if (window.mediaType === "anime") { loadAnimeDetails(item); return }
        if (window.mediaType === "movie" || item.type === "movie") {
            addToWatchHistory({ imdbId: item.imdbId, title: item.title, poster: item.poster, type: "movie" })
            window.playerImdb = item.imdbId || ""
            fetchMovieMeta(item.imdbId || "")   // synopsis for the below-video page
            enterPlayer(item.title)
            playFromStart("movie", item.title, 0, 0)
            return
        }
        loadSeriesDetails(item.imdbId, item.title, item.poster)
    }

    // Continue-watching items carry their own type + season, so resume by type:
    // movies replay; tv/anime reopen the series page at the season you were on.
    function openHistoryItem(item) {
        if (!item) return
        if (item.type === "movie") {
            addToWatchHistory(item)
            window.playerImdb = item.imdbId || ""
            fetchMovieMeta(item.imdbId || "")
            enterPlayer(item.title)
            playFromStart("movie", item.title, 0, 0)
            return
        }
        window.selectedIsAnime = (item.type === "anime")
        fetchSeriesData(item.imdbId, item.season || 1, item.title, item.poster, false)
    }

    // Play a YouTube result (by video id) into the embedded player.
    function playYouTube(vid, title, channelId, channelName) {
        if (!vid) return
        ytMarkSeen(vid, channelId || "", channelName || "")   // "never seen" + discovery taste
        ytRecordWatch(vid, title || "", channelName || "", channelId || "")   // full watch history (all videos)
        enterPlayer(title || "YouTube")
        window.currentYtId = vid
        window.playerKind = "youtube"
        window.currentVideoChannel = channelName || ""
        window.currentVideoChannelId = channelId || ""
        window.currentVideoDate = ""   // filled by fetchVideoInfo's meta
        fetchVideoInfo(vid)
        fetchSbSegments(vid)   // SponsorBlock: skip segments + timeline markings
        refreshPlayerComments()
        if (window.upNextOpen) buildUpNext()
        // Pull YouTube captions down via the ytdl hook so the subtitle toggle has
        // a track to show — dict form (string form doesn't parse for this prop).
        // Cookies ride along when a browser profile was found: YouTube bot-checks
        // bare yt-dlp on this IP ("Sign in to confirm you're not a bot"), which
        // made every load stall into "No source found". Reading cookies LIVE from
        // the browser keeps them fresh (no static-export rotation problem).
        // Request every offered language up front (captions only become mpv
        // tracks for langs listed here, so mid-play switching needs them all) —
        // but ONLY the exact codes from subLangCodes. NO ".*" globs: those also
        // matched every translated permutation (es-en, ja-pt-BR, …), 30+ tracks
        // whose URLs mpv probes at load → YouTube throttling → failed loads and
        // no subtitles at all. 639-2 codes (eng/jpn) mean nothing to YouTube —
        // skip them here.
        var allLangs = []
        for (var sli = 0; sli < window.subLangChoices.length; sli++) {
            var codes = window.subLangCodes[window.subLangChoices[sli].key]
            if (!codes) continue
            for (var ci = 0; ci < codes.length; ci++)
                if (codes[ci].length !== 3) allLangs.push(codes[ci])
        }
        var ytRawOpts = {
            "write-auto-subs": "", "write-subs": "",
            "sub-langs": allLangs.join(",")
        }
        if (window.ytCookieSpec !== "") ytRawOpts["cookies-from-browser"] = window.ytCookieSpec
        embeddedMpv.setProperty("sub-auto", "all")
        embeddedMpv.setProperty("sub-visibility", window.subsOn)
        // ytdl-raw-options is a MAP property — QML setProperty silently drops
        // map values on the floor (the live player showed {}), which meant the
        // ytdl hook requested NO captions and YouTube had zero subtitle tracks.
        // Send it over the IPC socket instead (dict sets verified working
        // there), sequenced strictly BEFORE the load so the hook sees it.
        var optsJson = JSON.stringify({ command: ["set_property", "ytdl-raw-options", ytRawOpts] })
        Quickshell.execDetached(["bash", "-c", 'bash "$1" "$2"; exec bash "$3" play youtube "$4"', "_",
                                 window.pipIpcSh, optsJson, window.videoCli, vid])
        maybeAutoAi()   // auto-summarise (if enabled) after you settle on the video
    }

    // ── Automatic AI parsing (builds the summary + history without opening the panel) ──
    // YouTube auth for yt-dlp (mpv's ytdl hook + transcript pulls): cookies read
    // LIVE from the Zen browser profile (firefox-compatible store). Discovered at
    // startup so the profile id is never hardcoded.
    property string ytCookieSpec: ""
    Process {
        running: true
        command: ["bash", "-c", "ls -d \"$HOME\"/.config/zen/*/cookies.sqlite 2>/dev/null | head -1"]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim()
            if (p !== "") window.ytCookieSpec = "firefox:" + p.replace(/\/cookies\.sqlite$/, "")
        } }
    }

    property bool autoAiParse: true
    Process {
        id: autoAiReader; running: true
        command: ["bash", "-c", "cat ~/.cache/qs_auto_ai.txt 2>/dev/null || echo 1"]
        stdout: StdioCollector { onStreamFinished: { window.autoAiParse = (this.text || "1").trim() !== "0" } }
    }
    function setAutoAi(v) {
        window.autoAiParse = v
        Quickshell.execDetached(["bash", "-c", "echo " + (v ? "1" : "0") + " > ~/.cache/qs_auto_ai.txt"])
        if (!v) autoAiTimer.stop()
    }
    // Debounced so it only summarises a video you actually stay on (not quick skips).
    Timer {
        id: autoAiTimer; interval: 8000; repeat: false
        onTriggered: {
            if (!window.autoAiParse) return
            // NEVER auto-load the model in gaming mode: the 12.5 GB model on top of a
            // game exhausts the 16 GB VRAM and crashes the compositor (2026-06-25).
            if (window.focusMode === "gaming") return
            if (window.currentView !== "player" || window.playerKind !== "youtube") return
            if (window.currentYtId === "" || window.aiText !== "" || window.aiLoading) return
            aiParse()
        }
    }
    function maybeAutoAi() {
        if (window.autoAiParse && window.playerKind === "youtube" && window.focusMode !== "gaming")
            autoAiTimer.restart()
    }

    // --- SHARED STYLES ---
    component CustomComboBox: ComboBox {
        id: control
        font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
        delegate: ItemDelegate {
            width: control.width; height: window.s(36)
            contentItem: Text { text: modelData || model.name; color: window.text; font: control.font; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: control.highlightedIndex === index ? window.surface1 : "transparent"; radius: window.s(10) }
        }
        indicator: Canvas {
            id: canvas
            x: control.width - width - control.rightPadding; y: control.topPadding + (control.availableHeight - height) / 2
            width: 12; height: 8; contextType: "2d"
            Connections { target: control; function onPressedChanged() { canvas.requestPaint() } }
            onPaint: { var ctx = canvas.getContext("2d"); ctx.reset(); ctx.moveTo(0, 0); ctx.lineTo(width, 0); ctx.lineTo(width / 2, height); ctx.fillStyle = window.subtext0; ctx.fill() }
        }
        contentItem: Text { leftPadding: window.s(10); rightPadding: control.indicator.width + control.spacing; text: control.currentText; font: control.font; color: window.text; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
        background: Rectangle { implicitWidth: window.s(180); implicitHeight: window.s(36); color: window.surface0; border.color: control.activeFocus ? window.surface2 : window.surface1; border.width: control.visualFocus ? 2 : 1; radius: window.s(10) }
        popup: Popup {
            y: control.height + window.s(4); width: control.width; implicitHeight: contentItem.implicitHeight; padding: window.s(4)
            contentItem: ListView { clip: true; implicitHeight: contentHeight; model: control.popup.visible ? control.delegateModel : null; currentIndex: control.highlightedIndex; ScrollIndicator.vertical: ScrollIndicator { } }
            background: Rectangle { color: window.crust; border.color: window.surface1; radius: window.s(14) }
        }
    }

    component PosterDelegate: Item {
        id: posterCard
        width: window.s(120); height: width * 1.5
        property bool isHovered: frontMouse.containsMouse
        // Right-click flips the card to a "remove from Continue Watching" back face.
        property bool flipped: false
        transform: Rotation {
            id: posterFlip
            origin.x: posterCard.width / 2; origin.y: posterCard.height / 2
            axis { x: 0; y: 1; z: 0 }
            angle: posterCard.flipped ? 180 : 0
            Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
        }
        // ── FRONT: poster (visible for the first half of the flip) ──
        Rectangle {
            anchors.fill: parent; radius: window.s(10); color: window.crust; clip: true
            visible: posterFlip.angle < 90
            Image {
                id: posterImg
                anchors.fill: parent
                source: model.poster !== "" ? model.poster : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                cache: true
                sourceSize.width: window.s(240)
                sourceSize.height: window.s(360)
                visible: status === Image.Ready
            }
            Rectangle {
                anchors.fill: parent
                color: window.surface0
                visible: model.poster === "" || posterImg.status === Image.Error || posterImg.status === Image.Null
                radius: window.s(10)
                Column {
                    anchors.centerIn: parent
                    width: parent.width - window.s(10)
                    spacing: window.s(6)
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: model.type === "tv" ? "📺" : "🎬"
                        font.pixelSize: window.s(22)
                    }
                    Text {
                        width: parent.width
                        text: model.title || "Unknown"; textFormat: Text.PlainText
                        color: window.subtext0
                        font.family: "JetBrains Mono"
                        font.pixelSize: window.s(11)
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        maximumLineCount: 4
                        elide: Text.ElideRight
                    }
                }
            }
            Rectangle {
                anchors.fill: parent; radius: window.s(10)
                color: window.sectionAccent
                opacity: posterCard.isHovered ? 0.3 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            // Continue-watching progress badge (last-watched season · episode).
            Rectangle {
                visible: (model.ep || 0) > 0
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: window.s(22)
                color: Qt.rgba(0, 0, 0, 0.78)
                Text {
                    anchors.centerIn: parent
                    text: (model.season || 0) > 0 ? ("S" + model.season + " · E" + model.ep) : ("E" + model.ep)
                    color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                }
            }
            // Front clicks: left = play, right = flip to the remove face.
            MouseArea {
                id: frontMouse; anchors.fill: parent; hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton; cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) posterCard.flipped = true
                    else { window.seriesReturn = null; openHistoryItem(model) }
                }
            }
        }
        // ── BACK: remove panel (counter-rotated so it reads correctly) ──
        Rectangle {
            anchors.fill: parent; radius: window.s(10)
            color: window.surface0
            border.color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.5); border.width: 1
            visible: posterFlip.angle >= 90
            transform: Rotation {
                origin.x: width / 2; origin.y: height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: 180
            }
            // Click anywhere on the back (except the X) flips it back to the poster.
            MouseArea {
                anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: posterCard.flipped = false
            }
            Column {
                anchors.centerIn: parent; spacing: window.s(10); width: parent.width - window.s(16)
                // X button → remove this item from Continue Watching.
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: window.s(46); height: window.s(46); radius: width / 2
                    color: xMouse.containsMouse ? window.red : Qt.rgba(window.red.r, window.red.g, window.red.b, 0.18)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text { anchors.centerIn: parent; text: "󰅖"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(22)
                        color: xMouse.containsMouse ? window.crust : window.red }
                    MouseArea {
                        id: xMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { posterCard.flipped = false; window.removeFromContinue(model.imdbId) }
                    }
                }
                Text {
                    width: parent.width; text: "Remove"
                    color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    // Reusable "Move to" back face for any flipping poster card: fills the
    // (rotating) poster rect, counter-rotated 180°, opaque — so it fully covers
    // the front past 90° without the front needing visibility gates. The host
    // card provides the item fields, binds `shown` to its flip angle, and
    // closes on done().
    component LibFlipBack: Rectangle {
        id: flipBack
        property string fImdb: ""
        property string fTitle: ""
        property string fPoster: ""
        property string fType: ""
        property bool shown: false
        signal done()
        anchors.fill: parent
        radius: window.s(8); color: window.surface0
        border.color: Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.5); border.width: 1
        visible: shown
        transform: Rotation {
            origin.x: flipBack.width / 2; origin.y: flipBack.height / 2
            axis.x: 0; axis.y: 1; axis.z: 0
            angle: 180
        }
        MouseArea { anchors.fill: parent; onClicked: flipBack.done() }
        Column {
            anchors.centerIn: parent; spacing: window.s(4); width: parent.width - window.s(14)
            Text { width: parent.width; text: "Move to"; color: window.subtext0
                   font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold
                   horizontalAlignment: Text.AlignHCenter; bottomPadding: window.s(2) }
            Repeater {
                model: window.malStatuses
                delegate: Rectangle {
                    width: parent.width; height: window.s(22); radius: window.s(6)
                    property bool cur: modelData.key === window.libStatusOf(flipBack.fImdb)
                    color: cur ? window.sectionAccent : (fbStM.containsMouse ? window.surface2 : window.surface1)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { anchors.centerIn: parent; text: modelData.label
                           color: parent.cur ? window.crust : window.text
                           font.family: "JetBrains Mono"; font.pixelSize: window.s(9)
                           font.weight: parent.cur ? Font.Bold : Font.Normal }
                    MouseArea { id: fbStM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            window.libSet({ imdbId: flipBack.fImdb, title: flipBack.fTitle,
                                            poster: flipBack.fPoster, type: flipBack.fType }, modelData.key)
                            flipBack.done()
                        } }
                }
            }
        }
    }

    // MyAnimeList card: poster on the front; right-click flips to the MAL list
    // statuses (Watching / Plan / Completed / On Hold / Dropped) so you can move
    // the entry between lists. Left-click opens it in the anime browser.
    component MalCard: Item {
        id: malCard
        width: window.s(120); height: width * 1.5
        property bool isHovered: malFrontMouse.containsMouse
        property bool flipped: false
        // Captured from the delegate model so the back-face Repeater (whose own
        // `model` is the status list) can still reach this card's anime.
        property string cardMalId: model.malId
        property string malCardStatus: model.status || window.malStatus
        transform: Rotation {
            id: malFlip
            origin.x: malCard.width / 2; origin.y: malCard.height / 2
            axis { x: 0; y: 1; z: 0 }
            angle: malCard.flipped ? 180 : 0
            Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
        }
        // ── FRONT ──
        Rectangle {
            anchors.fill: parent; radius: window.s(10); color: window.crust; clip: true
            visible: malFlip.angle < 90
            Image {
                id: malPoster; anchors.fill: parent
                source: model.poster !== "" ? model.poster : ""
                fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true; cache: true
                sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                visible: status === Image.Ready
            }
            Rectangle {
                anchors.fill: parent; radius: window.s(10); color: window.surface0
                visible: model.poster === "" || malPoster.status !== Image.Ready
                Text {
                    anchors.centerIn: parent; width: parent.width - window.s(12)
                    text: model.title || "Unknown"; textFormat: Text.PlainText; color: window.subtext0
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                    wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                    maximumLineCount: 5; elide: Text.ElideRight
                }
            }
            // Title gradient at the bottom.
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: window.s(42)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.82) }
                }
                Text {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: window.s(6) }
                    text: model.title || ""; textFormat: Text.PlainText; color: "white"
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(10); font.weight: Font.Bold
                    elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.WordWrap
                }
            }
            Rectangle {
                anchors.fill: parent; radius: window.s(10); color: window.green
                opacity: malCard.isHovered ? 0.28 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            MouseArea {
                id: malFrontMouse; anchors.fill: parent; hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton; cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) malCard.flipped = true
                    else openMalAnime(model)
                }
            }
        }
        // ── BACK: MAL status options ──
        Rectangle {
            anchors.fill: parent; radius: window.s(10); color: window.surface0
            border.color: Qt.rgba(window.green.r, window.green.g, window.green.b, 0.5); border.width: 1
            visible: malFlip.angle >= 90
            transform: Rotation {
                origin.x: width / 2; origin.y: height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: 180
            }
            MouseArea { anchors.fill: parent; onClicked: malCard.flipped = false }
            Column {
                anchors.centerIn: parent; spacing: window.s(4); width: parent.width - window.s(12)
                Text {
                    width: parent.width; text: "Move to"; color: window.subtext0
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold
                    horizontalAlignment: Text.AlignHCenter; bottomPadding: window.s(2)
                }
                Repeater {
                    model: window.malStatuses
                    delegate: Rectangle {
                        width: parent.width; height: window.s(22); radius: window.s(6)
                        property bool current: modelData.key === malCard.malCardStatus
                        property bool hov: statusMouse.containsMouse
                        color: current ? window.green
                            : hov ? Qt.rgba(window.green.r, window.green.g, window.green.b, 0.22) : window.surface1
                        Behavior on color { ColorAnimation { duration: 130 } }
                        Text {
                            anchors.centerIn: parent; text: modelData.label
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(10); font.weight: current ? Font.Bold : Font.Medium
                            color: current ? window.crust : window.text
                        }
                        MouseArea {
                            id: statusMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { malCard.flipped = false; if (!parent.current) window.malSetStatus(malCard.cardMalId, modelData.key) }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: dashboardHeaderComp
        Item {
            id: dashHeader
            width: GridView.view.width
            // (Continue Watching row removed — watched items auto-shelve into
            //  the Library's "Watching" list instead; resume from there.)
            // MAL list row: only in the anime section, once the addon is configured.
            property bool hasMal: window.mediaType === "anime" && window.malReady
            // Library row: movie/tv/anime, once anything has been tracked (★).
            property bool hasLib: (window.mediaType === "movie" || window.mediaType === "tv" || window.mediaType === "anime") && window.libraryAll.length > 0
            // HiAnime-style home: hero spotlight + themed category rows (movie/tv/anime).
            property bool hasHome: window.mediaType === "movie" || window.mediaType === "tv" || window.mediaType === "anime"
            readonly property var homeHero: hasHome ? window.homeCatItems(window.homeHeroKey) : []
            readonly property real heroSectionH: homeHero.length > 0 ? (window.s(350) + window.s(24)) : 0
            readonly property real homeRowH: window.s(24) + window.s(12) + window.s(200) + window.s(28)
            readonly property real homeRowsH: hasHome ? window.homeRows.length * homeRowH : 0
            readonly property real malSectionH: hasMal ? (window.s(34) + window.s(12) + window.s(200) + window.s(28)) : 0
            readonly property real libSectionH: hasLib ? (window.s(34) + window.s(12) + window.s(200) + window.s(28)) : 0
            readonly property real popularLabelH: window.s(16) + window.s(16)
            height: heroSectionH + malSectionH + libSectionH + homeRowsH + popularLabelH
            // The hero/category rows arrive async and inflate the header ABOVE the
            // viewport, which GridView compensates by keeping contentY — leaving the
            // view "pre-scrolled". If the user is still within the header region,
            // re-anchor to the top; deep-scrolled positions are left alone.
            onHeightChanged: {
                var gv = GridView.view
                if (gv && gv.contentY < height) gv.positionViewAtBeginning()
            }
            // Kick every catalog fetch for the current section (hero + rows).
            // Cheap: homeFetchCat no-ops when cached or in flight, so the three
            // grid headers can all call this safely.
            function kickHomeFetches() {
                if (!hasHome) return
                var cats = window.homeCategories[window.mediaType] || []
                for (var i = 0; i < cats.length; i++) window.homeFetchCat(cats[i].key, cats[i].url)
            }
            Component.onCompleted: kickHomeFetches()
            Connections {
                target: window
                function onMediaTypeChanged() { dashHeader.kickHomeFetches() }
            }
            Column {
                // Grid cards sit s(5) inside their cells (cardRect margins), so the
                // header content gets the same inset — hero, rows and labels line up
                // exactly with the Popular grid's card edges.
                x: window.s(5)
                width: parent.width - window.s(10)
                spacing: 0
                // ── HERO SPOTLIGHT: rotating banner (HiAnime style) ──
                Item {
                    width: parent.width
                    height: dashHeader.heroSectionH
                    visible: dashHeader.heroSectionH > 0
                    Rectangle {
                        id: heroCard
                        width: parent.width
                        height: window.s(350)
                        radius: window.s(12)
                        // Transparent: the art is drawn by the window-level
                        // heroBackdrop (which extends up behind the tabs/search).
                        color: "transparent"
                        clip: true
                        property int idx: 0
                        readonly property int slideCount: Math.min(dashHeader.homeHero.length, 8)
                        readonly property var cur: (slideCount > 0 && idx < slideCount) ? dashHeader.homeHero[idx] : null
                        onSlideCountChanged: idx = 0
                        // Publish the current slide's art for the backdrop; only the
                        // VISIBLE header drives it (all three grid headers share
                        // window.mediaType, so the hidden ones must stay silent).
                        onCurChanged: if (visible && window.currentView === "search") window.heroArtUrl = cur ? (cur.background || cur.poster) : ""
                        onVisibleChanged: if (visible && cur) window.heroArtUrl = cur.background || cur.poster
                        // Auto-advance: gated on actually being on screen and not hovered.
                        Timer {
                            interval: 15000
                            repeat: true
                            running: heroCard.visible && window.visible && heroCard.slideCount > 1 && !heroHover.hovered
                            onTriggered: heroCard.idx = (heroCard.idx + 1) % heroCard.slideCount
                        }
                        // Prefetch the NEXT slide's banner while the current one is
                        // still up, so the swap never pops in unloaded.
                        Image {
                            visible: false
                            readonly property var nxt: heroCard.slideCount > 1
                                ? dashHeader.homeHero[(heroCard.idx + 1) % heroCard.slideCount] : null
                            source: nxt ? (nxt.background || nxt.poster) : ""
                            sourceSize.width: window.s(1100)
                            asynchronous: true; cache: true
                        }
                        // (art lives in heroBackdrop — see the window-level Item)
                        // (left legibility gradient lives on heroBackdrop now, so it
                        //  covers the full art — including behind the tabs/search)
                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: window.s(22)
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * 0.58
                            spacing: window.s(8)
                            Text {
                                text: "✦ SPOTLIGHT"
                                color: window.sectionAccent
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(10); font.weight: Font.Bold
                                font.letterSpacing: window.s(2)
                            }
                            Text {
                                width: parent.width
                                text: heroCard.cur ? heroCard.cur.title : ""
                                textFormat: Text.PlainText
                                color: window.text
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(23); font.weight: Font.Bold
                                wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: heroCard.cur
                                    ? ((heroCard.cur.rating > 0 ? "★ " + heroCard.cur.rating.toFixed(1) + "   " : "")
                                       + (heroCard.cur.year !== "" ? heroCard.cur.year + "   " : "")
                                       + heroCard.cur.genres)
                                    : ""
                                textFormat: Text.PlainText
                                color: window.subtext0
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: heroCard.cur ? heroCard.cur.description : ""
                                textFormat: Text.PlainText
                                color: window.subtext0
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                            }
                            Row {
                                spacing: window.s(10)
                                Rectangle {
                                    width: heroPlayT.width + window.s(28)
                                    height: window.s(32)
                                    radius: window.s(16)
                                    color: heroPlayM.containsMouse ? Qt.lighter(window.sectionAccent, 1.12) : window.sectionAccent
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Text {
                                        id: heroPlayT; anchors.centerIn: parent
                                        text: window.mediaType === "movie" ? "▶  Watch Now" : "▶  Open"
                                        color: window.crust
                                        font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                    }
                                    MouseArea {
                                        id: heroPlayM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (heroCard.cur) window.openItem(heroCard.cur)
                                    }
                                }
                                Rectangle {
                                    width: heroLibT.width + window.s(24)
                                    height: window.s(32)
                                    radius: window.s(16)
                                    color: heroLibM.containsMouse ? window.surface1 : window.surface0
                                    border.color: window.surface2; border.width: 1
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    property bool tracked: heroCard.cur ? window.libInLibrary(heroCard.cur.imdbId) : false
                                    Text {
                                        id: heroLibT; anchors.centerIn: parent
                                        text: parent.tracked ? "✓ In Library" : "＋ List"
                                        color: window.text
                                        font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                    }
                                    MouseArea {
                                        id: heroLibM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (!heroCard.cur || parent.tracked) return
                                            window.libSet({ imdbId: heroCard.cur.imdbId, title: heroCard.cur.title,
                                                            poster: heroCard.cur.poster,
                                                            type: window.mediaType === "anime" ? "anime" : heroCard.cur.type },
                                                          "plan_to_watch")
                                        }
                                    }
                                }
                            }
                        }
                        // Slide dots (clickable).
                        Row {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: window.s(14)
                            spacing: window.s(6)
                            Repeater {
                                model: heroCard.slideCount
                                Rectangle {
                                    width: window.s(8); height: window.s(8); radius: window.s(4)
                                    color: heroCard.idx === index ? window.sectionAccent
                                         : Qt.rgba(window.text.r, window.text.g, window.text.b, 0.35)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: heroCard.idx = index }
                                }
                            }
                        }
                        HoverHandler { id: heroHover }
                    }
                }
                // (Recent Searches row removed — recents live in the dropdown
                //  under the search box while typing.)
                // (Continue Watching row removed — the Library "Watching" shelf
                //  below carries everything in progress, auto-populated on play.)
                // ── MyAnimeList row: status slider + flip cards ──
                Item {
                    width: parent.width
                    height: parent.parent.malSectionH
                    visible: parent.parent.hasMal
                    Column {
                        width: parent.width
                        spacing: window.s(12)
                        // Header: title + the "slider" between the MAL lists.
                        Row {
                            width: parent.width; height: window.s(34); spacing: window.s(14)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "MyAnimeList"; color: window.text
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(16)
                            }
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: window.s(6)
                                Repeater {
                                    model: window.malStatuses
                                    delegate: Rectangle {
                                        height: window.s(28); radius: window.s(8)
                                        width: pillText.width + window.s(22)
                                        property bool active: modelData.key === window.malStatus
                                        color: active ? window.green : (pillMouse.containsMouse ? window.surface1 : window.surface0)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Text {
                                            id: pillText; anchors.centerIn: parent; text: modelData.label
                                            font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                            font.weight: active ? Font.Bold : Font.Medium
                                            color: active ? window.crust : window.text
                                        }
                                        MouseArea {
                                            id: pillMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: selectMalStatus(modelData.key)
                                        }
                                    }
                                }
                            }
                        }
                        Item {
                            width: parent.width; height: window.s(200)
                            ListView {
                                anchors.fill: parent
                                orientation: ListView.Horizontal; spacing: window.s(15)
                                model: malModel; clip: true
                                delegate: MalCard {}
                                ScrollBar.horizontal: ScrollBar {
                                    active: true
                                    contentItem: Rectangle { radius: window.s(2); color: window.surface2 }
                                }
                            }
                            // Empty / loading / error hint over the cards area.
                            Text {
                                anchors.centerIn: parent
                                visible: malModel.count === 0
                                text: window.malLoading ? "Loading your " + window.malLabelFor(window.malStatus) + " list…"
                                    : window.malError === "fetch" ? "Couldn't reach the MAL addon — check mal_addon_url."
                                    : "Nothing in your " + window.malLabelFor(window.malStatus) + " list."
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
                // ── Library row: MAL-style status slider + your tracked posters ──
                Item {
                    width: parent.width
                    height: parent.parent.libSectionH
                    visible: parent.parent.hasLib
                    Column {
                        width: parent.width
                        spacing: window.s(12)
                        // Header: title + the status "slider" (same statuses as MAL)
                        // + "View All ↗" opening the browse overlay, like the topics.
                        Item {
                            width: parent.width; height: window.s(34)
                            Row {
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                spacing: window.s(14)
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Library"; color: window.text
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(16)
                                }
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: window.s(6)
                                    Repeater {
                                        model: window.malStatuses
                                        delegate: Rectangle {
                                            height: window.s(28); radius: window.s(8)
                                            width: libPillText.width + window.s(22)
                                            property bool active: modelData.key === window.libStatus
                                            color: active ? window.sectionAccent : (libPillMouse.containsMouse ? window.surface1 : window.surface0)
                                            Behavior on color { ColorAnimation { duration: 150 } }
                                            Text {
                                                id: libPillText; anchors.centerIn: parent; text: modelData.label
                                                font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                                font.weight: parent.active ? Font.Bold : Font.Medium
                                                color: parent.active ? window.crust : window.text
                                            }
                                            MouseArea {
                                                id: libPillMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: window.libSetBrowseStatus(modelData.key)
                                            }
                                        }
                                    }
                                }
                            }
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                spacing: window.s(6)
                                // Same ‹ › paging arrows as the topic rows.
                                Rectangle {
                                    width: window.s(28); height: window.s(22); radius: window.s(6)
                                    color: libLM.containsMouse ? window.surface1 : window.surface0
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Text { anchors.centerIn: parent; text: "‹"; color: window.text; font.pixelSize: window.s(14); font.weight: Font.Bold }
                                    MouseArea { id: libLM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: libRowLv.scrollByPage(-1) }
                                }
                                Rectangle {
                                    width: window.s(28); height: window.s(22); radius: window.s(6)
                                    color: libRM.containsMouse ? window.surface1 : window.surface0
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Text { anchors.centerIn: parent; text: "›"; color: window.text; font.pixelSize: window.s(14); font.weight: Font.Bold }
                                    MouseArea { id: libRM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: libRowLv.scrollByPage(1) }
                                }
                                Rectangle {
                                    width: libAllT.width + window.s(18); height: window.s(22); radius: window.s(6)
                                    color: libAllM.containsMouse ? window.sectionAccent : window.surface0
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Text { id: libAllT; anchors.centerIn: parent; text: "View All ↗"
                                           color: libAllM.containsMouse ? window.crust : window.subtext0
                                           font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                                    MouseArea { id: libAllM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: window.openLibrary() }
                                }
                            }
                        }
                        Item {
                            width: parent.width; height: window.s(200)
                            ListView {
                                id: libRowLv
                                anchors.fill: parent
                                orientation: ListView.Horizontal; spacing: window.s(15)
                                model: libraryModel; clip: true
                                function scrollByPage(dir) {
                                    libRowAnim.stop()
                                    var target = Math.max(0, Math.min(contentWidth - width, contentX + dir * width * 0.85))
                                    libRowAnim.from = contentX
                                    libRowAnim.to = target
                                    libRowAnim.start()
                                }
                                NumberAnimation { id: libRowAnim; target: libRowLv; property: "contentX"
                                                  duration: 320; easing.type: Easing.OutQuart }
                                ScrollBar.horizontal: ScrollBar {
                                    active: true
                                    contentItem: Rectangle { radius: window.s(2); color: window.surface2 }
                                }
                                delegate: Item {
                                    id: libRowCard
                                    width: window.s(126); height: window.s(190)
                                    // Right-click flips to the same "Move to" status picker as
                                    // the MAL cards / library overlay.
                                    property bool rowFlipped: false
                                    property string cardImdb: model.imdbId || ""
                                    property string cardTitle: model.title || ""
                                    property string cardPoster: model.poster || ""
                                    property string cardType: model.type || ""
                                    property string cardStatus: model.status || ""
                                    Rectangle {
                                        id: libRowPoster
                                        anchors.fill: parent; radius: window.s(8); color: window.crust; clip: true
                                        transform: Rotation {
                                            id: libRowFlip
                                            origin.x: libRowPoster.width / 2; origin.y: libRowPoster.height / 2
                                            axis.x: 0; axis.y: 1; axis.z: 0
                                            angle: libRowCard.rowFlipped ? 180 : 0
                                            Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
                                        }
                                        Image {
                                            anchors.fill: parent; source: model.poster || ""; fillMode: Image.PreserveAspectCrop
                                            asynchronous: true; smooth: true; cache: true
                                            sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                                            visible: status === Image.Ready && libRowFlip.angle < 90
                                        }
                                        Rectangle {
                                            anchors.fill: parent; color: window.surface0; radius: window.s(8)
                                            visible: (model.poster || "") === "" && libRowFlip.angle < 90
                                            Text { anchors.centerIn: parent; width: parent.width - window.s(10); text: model.title || ""
                                                   textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                                   wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; maximumLineCount: 5; elide: Text.ElideRight }
                                        }
                                        // title gradient
                                        Rectangle {
                                            visible: libRowFlip.angle < 90
                                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                            height: window.s(42)
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: "transparent" }
                                                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.82) }
                                            }
                                            Text { anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: window.s(6) }
                                                   text: model.title || ""; textFormat: Text.PlainText; color: "white"
                                                   font.family: "JetBrains Mono"; font.pixelSize: window.s(10); font.weight: Font.Bold
                                                   elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.WordWrap }
                                        }
                                        // type badge (top-left)
                                        Rectangle {
                                            visible: libRowFlip.angle < 90
                                            anchors { top: parent.top; left: parent.left; margins: window.s(6) }
                                            width: libBadgeT.width + window.s(10); height: window.s(18); radius: window.s(5); color: Qt.rgba(0, 0, 0, 0.62)
                                            Text { id: libBadgeT; anchors.centerIn: parent
                                                   text: model.type === "movie" ? "MOVIE" : (model.type === "anime" ? "ANIME" : "TV")
                                                   color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(8); font.weight: Font.Bold }
                                        }
                                        Rectangle {
                                            anchors.fill: parent; radius: window.s(8); color: window.sectionAccent
                                            opacity: libRowMouse.containsMouse && libRowFlip.angle < 90 ? 0.28 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                        // ── BACK: "Move to" status picker (counter-rotated) ──
                                        Rectangle {
                                            anchors.fill: parent; radius: window.s(8); color: window.surface0
                                            border.color: Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.5); border.width: 1
                                            visible: libRowFlip.angle >= 90
                                            transform: Rotation {
                                                origin.x: libRowPoster.width / 2; origin.y: libRowPoster.height / 2
                                                axis.x: 0; axis.y: 1; axis.z: 0
                                                angle: 180
                                            }
                                            MouseArea { anchors.fill: parent; onClicked: libRowCard.rowFlipped = false }
                                            Column {
                                                anchors.centerIn: parent; spacing: window.s(4); width: parent.width - window.s(14)
                                                Text { width: parent.width; text: "Move to"; color: window.subtext0
                                                       font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold
                                                       horizontalAlignment: Text.AlignHCenter; bottomPadding: window.s(2) }
                                                Repeater {
                                                    model: window.malStatuses
                                                    delegate: Rectangle {
                                                        width: parent.width; height: window.s(22); radius: window.s(6)
                                                        property bool cur: modelData.key === libRowCard.cardStatus
                                                        color: cur ? window.sectionAccent
                                                             : (libRowStM.containsMouse ? window.surface2 : window.surface1)
                                                        Behavior on color { ColorAnimation { duration: 120 } }
                                                        Text { anchors.centerIn: parent; text: modelData.label
                                                               color: parent.cur ? window.crust : window.text
                                                               font.family: "JetBrains Mono"; font.pixelSize: window.s(9)
                                                               font.weight: parent.cur ? Font.Bold : Font.Normal }
                                                        MouseArea { id: libRowStM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                libRowCard.rowFlipped = false
                                                                window.libSet({ imdbId: libRowCard.cardImdb, title: libRowCard.cardTitle,
                                                                                poster: libRowCard.cardPoster, type: libRowCard.cardType }, modelData.key)
                                                            } }
                                                    }
                                                }
                                            }
                                        }
                                        MouseArea { id: libRowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            enabled: libRowFlip.angle < 90   // let the back's pills take clicks when flipped
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onClicked: (m) => {
                                                if (m.button === Qt.RightButton) libRowCard.rowFlipped = true
                                                else openItem(model)
                                            } }
                                    }
                                }
                            }
                            // Empty hint when the selected status list has nothing yet.
                            Text {
                                anchors.centerIn: parent
                                visible: libraryModel.count === 0
                                text: "Nothing in your " + window.libLabel(window.libStatus) + " list."
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
                // ── Themed category rows (Top Rated / New / genres …) ──
                Repeater {
                    model: dashHeader.hasHome ? window.homeRows : []
                    delegate: Item {
                        width: parent.width
                        height: dashHeader.homeRowH
                        // modelData = { key, title, url } from homeCategories.
                        Column {
                            width: parent.width
                            spacing: window.s(12)
                            // Row header: title + scroll arrows + "View All" (full page).
                            Item {
                                width: parent.width; height: window.s(24)
                                Text {
                                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.title
                                    color: window.text
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(16)
                                }
                                Row {
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    spacing: window.s(6)
                                    Rectangle {
                                        width: window.s(28); height: window.s(22); radius: window.s(6)
                                        color: catLM.containsMouse ? window.surface1 : window.surface0
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Text { anchors.centerIn: parent; text: "‹"; color: window.text; font.pixelSize: window.s(14); font.weight: Font.Bold }
                                        MouseArea { id: catLM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: catRowLv.scrollByPage(-1) }
                                    }
                                    Rectangle {
                                        width: window.s(28); height: window.s(22); radius: window.s(6)
                                        color: catRM.containsMouse ? window.surface1 : window.surface0
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Text { anchors.centerIn: parent; text: "›"; color: window.text; font.pixelSize: window.s(14); font.weight: Font.Bold }
                                        MouseArea { id: catRM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: catRowLv.scrollByPage(1) }
                                    }
                                    Rectangle {
                                        width: catAllT.width + window.s(18); height: window.s(22); radius: window.s(6)
                                        color: catAllM.containsMouse ? window.sectionAccent : window.surface0
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Text { id: catAllT; anchors.centerIn: parent; text: "View All ↗"
                                               color: catAllM.containsMouse ? window.crust : window.subtext0
                                               font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                                        MouseArea { id: catAllM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: window.openCatPage(modelData) }
                                    }
                                }
                            }
                            Item {
                                width: parent.width; height: window.s(200)
                                ListView {
                                    id: catRowLv
                                    anchors.fill: parent
                                    orientation: ListView.Horizontal; spacing: window.s(15)
                                    model: window.homeCatItems(modelData.key)
                                    clip: true
                                    // Scrolling to the row's end pulls the next catalog
                                    // page in, so the strip keeps growing. JS-array models
                                    // reset the view when they grow, so hold the position
                                    // and restore it once the new delegates are in.
                                    property real keepX: -1
                                    onAtXEndChanged: if (atXEnd && count > 0) { keepX = contentX; window.homeCatMore(modelData.key, modelData.url) }
                                    onCountChanged: if (keepX >= 0) { contentX = keepX; keepX = -1 }
                                    // Button-driven paging (the ‹ › arrows in the header).
                                    function scrollByPage(dir) {
                                        catRowAnim.stop()
                                        var target = Math.max(0, Math.min(contentWidth - width, contentX + dir * width * 0.85))
                                        catRowAnim.from = contentX
                                        catRowAnim.to = target
                                        catRowAnim.start()
                                    }
                                    NumberAnimation { id: catRowAnim; target: catRowLv; property: "contentX"
                                                      duration: 320; easing.type: Easing.OutQuart }
                                    ScrollBar.horizontal: ScrollBar {
                                        active: true
                                        contentItem: Rectangle { radius: window.s(2); color: window.surface2 }
                                    }
                                    delegate: Item {
                                        id: catRowCard
                                        width: window.s(126); height: window.s(190)
                                        // Right-click flips to the "Move to" shelf picker.
                                        property bool rcFlipped: false
                                        Rectangle {
                                            id: catRowPoster
                                            anchors.fill: parent; radius: window.s(8); color: window.crust; clip: true
                                            transform: Rotation {
                                                id: catRowFlip
                                                origin.x: catRowPoster.width / 2; origin.y: catRowPoster.height / 2
                                                axis.x: 0; axis.y: 1; axis.z: 0
                                                angle: catRowCard.rcFlipped ? 180 : 0
                                                Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
                                            }
                                            Image {
                                                anchors.fill: parent; source: modelData.poster || ""; fillMode: Image.PreserveAspectCrop
                                                asynchronous: true; smooth: true; cache: true
                                                sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                                                visible: status === Image.Ready
                                            }
                                            Rectangle {
                                                anchors.fill: parent; color: window.surface0; radius: window.s(8)
                                                visible: (modelData.poster || "") === ""
                                                Text { anchors.centerIn: parent; width: parent.width - window.s(10); text: modelData.title || ""
                                                       textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                                       wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; maximumLineCount: 5; elide: Text.ElideRight }
                                            }
                                            // title gradient
                                            Rectangle {
                                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                                height: window.s(42)
                                                gradient: Gradient {
                                                    GradientStop { position: 0.0; color: "transparent" }
                                                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.82) }
                                                }
                                                Text { anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: window.s(6) }
                                                       text: modelData.title || ""; textFormat: Text.PlainText; color: "white"
                                                       font.family: "JetBrains Mono"; font.pixelSize: window.s(10); font.weight: Font.Bold
                                                       elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.WordWrap }
                                            }
                                            // ★ rating chip (top-left)
                                            Rectangle {
                                                visible: (modelData.rating || 0) > 0
                                                anchors { top: parent.top; left: parent.left; margins: window.s(6) }
                                                width: catRateT.width + window.s(10); height: window.s(18); radius: window.s(5)
                                                color: Qt.rgba(0, 0, 0, 0.62)
                                                Text { id: catRateT; anchors.centerIn: parent
                                                       text: "★ " + (modelData.rating || 0).toFixed(1)
                                                       color: "#f9e2af"; font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold }
                                            }
                                            Rectangle {
                                                anchors.fill: parent; radius: window.s(8); color: window.sectionAccent
                                                opacity: catCardM.containsMouse ? 0.28 : 0
                                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                            }
                                            MouseArea { id: catCardM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                enabled: catRowFlip.angle < 90
                                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                                onClicked: (m) => {
                                                    if (m.button === Qt.RightButton) catRowCard.rcFlipped = true
                                                    else window.openItem(modelData)
                                                } }
                                            LibFlipBack {
                                                fImdb: modelData.imdbId; fTitle: modelData.title
                                                fPoster: modelData.poster || ""
                                                fType: window.mediaType === "anime" ? "anime" : (modelData.type || "")
                                                shown: catRowFlip.angle >= 90
                                                onDone: catRowCard.rcFlipped = false
                                            }
                                        }
                                    }
                                }
                                // Loading shimmer hint until this row's catalog lands.
                                Text {
                                    anchors.centerIn: parent
                                    visible: window.homeCatItems(modelData.key).length === 0
                                    text: "Loading " + modelData.title + "…"
                                    color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                                }
                            }
                        }
                    }
                }
                Item {
                    width: parent.width
                    height: parent.parent.popularLabelH
                    Text {
                        anchors.top: parent.top; anchors.topMargin: window.s(4)
                        text: window.mediaType === "movie" ? "Popular Movies"
                            : window.mediaType === "anime" ? "Popular Anime" : "Popular TV Shows"
                        color: window.text
                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(16)
                    }
                }
            }
        }
    }

    // Four-way section slider (YouTube · Anime · TV · Movies). Reused at the top
    // of the search, anime and youtube pages so you can slide between them all.
    component SectionTabs: Rectangle {
        id: tabsRoot
        implicitWidth: window.s(360); implicitHeight: window.s(36)
        radius: window.s(10); color: window.surface0
        readonly property var allSections: [
            { key: "books",   label: "Books",   accent: window.booksAccent },
            { key: "music",   label: "Music",   accent: window.musicAccent },
            { key: "games",   label: "Games",   accent: window.gamesAccent },
            { key: "youtube", label: "YouTube", accent: window.red },
            { key: "anime",   label: "Anime",   accent: window.green },
            { key: "tv",      label: "TV",      accent: window.blue },
            { key: "movie",   label: "Movies",  accent: window.mauve }
        ]
        // Visible set depends on focus mode: Games only in gaming; movies/tv/anime hidden in study.
        readonly property var sections: {
            var out = []
            for (var i = 0; i < allSections.length; i++)
                if (window.isSectionVisible(allSections[i].key)) out.push(allSections[i])
            return out
        }
        readonly property int activeIndex: {
            var k = window.activeSection
            for (var i = 0; i < sections.length; i++) if (sections[i].key === k) return i
            return 0
        }
        readonly property real segW: sections.length > 0 ? width / sections.length : width
        Rectangle {
            id: tabsHi
            width: tabsRoot.segW - window.s(8); height: parent.height - window.s(8)
            y: window.s(4); radius: window.s(8); z: 0
            visible: tabsRoot.sections.length > 0
            color: tabsRoot.sections.length > 0 ? tabsRoot.sections[Math.min(tabsRoot.activeIndex, tabsRoot.sections.length - 1)].accent : window.mauve
            x: tabsRoot.activeIndex * tabsRoot.segW + window.s(4)
            Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
            Behavior on color { ColorAnimation { duration: 250 } }
        }
        Row {
            anchors.fill: parent; z: 1
            Repeater {
                model: tabsRoot.sections
                delegate: Item {
                    width: tabsRoot.segW; height: tabsRoot.height
                    Text {
                        anchors.centerIn: parent; text: modelData.label
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                        font.weight: window.activeSection === modelData.key ? Font.Bold : Font.Medium
                        color: window.activeSection === modelData.key ? window.crust : window.text
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: window.selectSection(modelData.key) }
                }
            }
        }
    }

    // --- UI LAYOUT ---
    Rectangle {
        id: mainBg
        width: parent.width; height: parent.height
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        radius: window.s(14)
        color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.95)
        border.color: Qt.rgba(window.text.r, window.text.g, window.text.b, 0.08)
        border.width: 1
        clip: true
        transform: Translate { y: (1 - window.introPhase) * window.s(50) }
        opacity: window.introPhase

        // ── HERO BACKDROP: the spotlight art bleeds up BEHIND the section tabs
        //    and search bar (full art visible, HiAnime style). Drawn first so
        //    all controls sit on top; fades out as the dashboard scrolls and
        //    blends into the page with a bottom gradient.
        Item {
            id: heroBackdrop
            anchors { left: parent.left; right: parent.right }
            height: window.s(72) + window.s(16) + window.s(350)
            readonly property var dashGrid: window.mediaType === "movie" ? movieGrid
                : window.mediaType === "tv" ? tvGrid
                : window.mediaType === "anime" ? animeGrid : null
            // The SERIES page reuses this backdrop as its top banner (the
            // show's own background art, home-page style, static at the top).
            readonly property bool seriesMode: window.currentView === "series"
            // Scrolls WITH the dashboard: the art tracks the grid's scroll
            // position 1:1, so the banner and the spotlight text move together
            // (the container's clip trims it at the widget edge).
            y: seriesMode ? 0 : (dashGrid ? -(dashGrid.contentY - dashGrid.originY) : 0)
            visible: seriesMode ? window.selectedBackground !== ""
                : (y > -height && window.currentView === "search" && !window.isSearchMode
                   && dashGrid !== null && window.heroArtUrl !== "")
            Image {
                anchors.fill: parent
                source: heroBackdrop.seriesMode ? window.selectedBackground : window.heroArtUrl
                fillMode: Image.PreserveAspectCrop
                // Keep the TOP of the artwork — the default centered crop was
                // cutting the banners' tops off.
                verticalAlignment: Image.AlignTop
                sourceSize.width: window.s(1100)
                asynchronous: true; cache: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 450 } }
            }
            // Left legibility gradient — full height, so it shades the art all
            // the way to the top (behind the tabs and search) as well.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0;  color: Qt.rgba(window.crust.r, window.crust.g, window.crust.b, 0.96) }
                    GradientStop { position: 0.55; color: Qt.rgba(window.crust.r, window.crust.g, window.crust.b, 0.55) }
                    GradientStop { position: 1.0;  color: "transparent" }
                }
            }
            // Blend the art into the page: fade to the base colour at the bottom.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0;  color: "transparent" }
                    GradientStop { position: 0.72; color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.28) }
                    GradientStop { position: 1.0;  color: window.base }
                }
            }
        }

        // While the home page loads, the semi-transparent scrim covers the FULL
        // view — including behind the search bar and section tabs (drawn here,
        // before the controls, so they stay usable on top). The spinner itself
        // stays with the content-area overlay below.
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.8)
            visible: window.showLoadingOverlay && window.currentView === "search"
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            visible: window.currentView === "search"
            Rectangle {
                Layout.alignment: Qt.AlignTop; Layout.fillWidth: true; Layout.preferredHeight: window.s(72); color: "transparent"
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(15); spacing: window.s(10)
                    RowLayout {
                        Layout.fillWidth: true; spacing: window.s(15)
                        // Four-way section slider: YouTube · Anime · TV · Movies
                        SectionTabs { Layout.preferredWidth: window.s(540); Layout.preferredHeight: window.s(36) }
                        TextField {
                        id: searchInput
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(42)
                        background: Rectangle {
                            color: searchInput.activeFocus ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6) : window.surface0
                            radius: window.s(10); border.color: searchInput.activeFocus ? window.surface2 : "transparent"
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }
                        color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); leftPadding: window.s(15)
                        placeholderText: window.mediaType === "youtube" ? "Search YouTube…"
                            : window.mediaType === "music" ? "Search your music…"
                            : window.mediaType === "books" ? "Search your manga & novels…"
                            : window.mediaType === "games" ? "Your Steam library (click a game to launch)…"
                            : window.mediaType === "anime" ? "Search anime…"
                            : window.mediaType === "tv" ? "Search TV shows…"
                            : "Search movies…"
                        placeholderTextColor: window.subtext0; verticalAlignment: TextInput.AlignVCenter
                        // ── Recent-searches dropdown while typing ──
                        Popup {
                            id: searchRecentPopup
                            parent: searchInput
                            y: parent.height + window.s(6)
                            width: Math.min(parent.width, window.s(420))
                            padding: window.s(6)
                            closePolicy: Popup.NoAutoClose   // visibility is fully binding-driven
                            // Recents that match what's typed — only once there IS
                            // typed text (an empty box shows no menu); the exact
                            // current text is excluded so the menu disappears once
                            // you've "arrived".
                            readonly property var hits: {
                                var q = (searchInput.text || "").toLowerCase().trim()
                                if (q === "") return []
                                var out = []
                                for (var i = 0; i < searchHistoryModel.count && out.length < 8; i++) {
                                    var s = searchHistoryModel.get(i).query
                                    var sl = s.toLowerCase()
                                    if (sl !== q && sl.indexOf(q) >= 0) out.push(s)
                                }
                                return out
                            }
                            visible: searchInput.activeFocus && hits.length > 0 && window.currentView === "search"
                            background: Rectangle {
                                radius: window.s(10); color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.97)
                                border.color: window.surface2; border.width: 1
                            }
                            contentItem: Column {
                                spacing: window.s(2)
                                Repeater {
                                    model: searchRecentPopup.hits
                                    delegate: Rectangle {
                                        width: searchRecentPopup.width - window.s(12); height: window.s(30); radius: window.s(7)
                                        color: srItemM.containsMouse ? window.surface1 : "transparent"
                                        Behavior on color { ColorAnimation { duration: 100 } }
                                        Row {
                                            anchors.left: parent.left; anchors.leftMargin: window.s(10)
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: window.s(8)
                                            Text { text: "󰋚"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(13); color: window.subtext0
                                                   anchors.verticalCenter: parent.verticalCenter }
                                            Text { text: modelData; textFormat: Text.PlainText
                                                   color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                                   anchors.verticalCenter: parent.verticalCenter }
                                        }
                                        MouseArea { id: srItemM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                searchInput.text = modelData
                                                // Section-aware: youtube/music/books route to their
                                                // own backends, not just the movie search.
                                                runSearch(modelData)
                                            } }
                                    }
                                }
                            }
                        }
                        onTextChanged: {
                            if (text.trim() === "") {
                                searchResults.clear(); ytResults.clear()
                                window.isSearchingNetwork = false; window.isSearchingYt = false
                                searchDebounceTimer.stop()
                                // YouTube: an empty box returns to the algorithmic home feed.
                                if (window.mediaType === "youtube" && window.ytSearchKind === "videos") {
                                    window.ytView = "home"; youtubeHomeFeed()
                                }
                                // Books: an empty box returns to the full library listing.
                                if (window.mediaType === "books") { window.booksLoaded = false; fetchBooks("") }
                            } else searchDebounceTimer.restart()
                        }
                        Keys.onRightPressed: {
                            window.isKeyboardNav = true; keyboardNavTimer.restart()
                            let g = getActiveGrid()
                            if (g && g.count > 0 && g.currentIndex < g.count - 1) g.currentIndex++
                            event.accepted = true
                        }
                        Keys.onLeftPressed: {
                            window.isKeyboardNav = true; keyboardNavTimer.restart()
                            let g = getActiveGrid()
                            if (g && g.count > 0 && g.currentIndex > 0) g.currentIndex--
                            event.accepted = true
                        }
                        Keys.onDownPressed: {
                            window.isKeyboardNav = true; keyboardNavTimer.restart()
                            let g = getActiveGrid()
                            if (g && g.count > 0) {
                                let columns = Math.max(1, Math.floor(g.width / g.cellWidth))
                                if (g.currentIndex + columns < g.count) g.currentIndex += columns
                            }
                            event.accepted = true
                        }
                        Keys.onUpPressed: {
                            window.isKeyboardNav = true; keyboardNavTimer.restart()
                            let g = getActiveGrid()
                            if (g && g.count > 0) {
                                let columns = Math.max(1, Math.floor(g.width / g.cellWidth))
                                if (g.currentIndex - columns >= 0) g.currentIndex -= columns
                            }
                            event.accepted = true
                        }
                        // Tab / Shift+Tab cycle through the four sections.
                        Keys.onTabPressed: { window.cycleSection(1); event.accepted = true }
                        Keys.onBacktabPressed: { window.cycleSection(-1); event.accepted = true }
                        Keys.onReturnPressed: {
                            if (window.mediaType === "youtube") {
                                if (window.isKeyboardNav) {
                                    let g = getActiveGrid()
                                    if (g && g.count > 0 && g.currentIndex >= 0 && g.currentIndex < g.count) {
                                        let it = g.model.get(g.currentIndex)
                                        if (it) playYouTube(it.vid, it.title, it.channelId, it.channel)
                                    }
                                } else if (text.trim() !== "") {
                                    ytSearchDispatch(text)
                                }
                            } else if (text.trim() !== "" && searchResults.count === 0 && !window.isSearchingNetwork) {
                                doSearch(text)
                            } else if (window.isKeyboardNav) {
                                let g = getActiveGrid()
                                if (g && g.count > 0 && g.currentIndex >= 0 && g.currentIndex < g.count) {
                                    openItem(g.model.get(g.currentIndex))
                                }
                            }
                            event.accepted = true
                        }
                    }
                        // (top-bar ★ Library button removed — the Library row's
                        //  "View All ↗" opens the browse overlay, like the topics)
                        CustomComboBox {
                            id: filterSelector
                            visible: window.mediaType === "movie" || window.mediaType === "tv" || window.mediaType === "anime"
                            Layout.preferredWidth: window.s(180)
                            model: ["Default", "Year (Newest)", "Year (Oldest)", "Title (A-Z)", "Title (Z-A)", "Rating (Best)", "Rating (Worst)"]
                            onActivated: {
                                window.filterSort = currentText
                                applyFiltersAndPopulate()
                                applyFiltersToPopular()
                            }
                        }
                        // YouTube: Home / Channels / Playlists / History page picker —
                        // same dropdown style as the movie/TV/anime filter (its Popup
                        // renders in the overlay, so it sits in front of the thumbnails).
                        CustomComboBox {
                            id: ytPageDrop
                            visible: window.mediaType === "youtube"
                            Layout.preferredWidth: window.s(150)
                            readonly property var pageKeys: ["home", "channels", "playlists", "history"]
                            model: ["Home", "Channels", "Playlists", "History"]
                            currentIndex: {
                                var v = window.ytView
                                if (v === "channels") return 1
                                if (v === "playlists" || v === "playlist") return 2
                                if (v === "history") return 3
                                return 0   // home, videos(search), channel
                            }
                            onActivated: (idx) => ytGoPage(ytPageDrop.pageKeys[idx])
                        }
                    }
                }
            }
            // (controls↔content separator removed — the hero art flows through)
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                Rectangle {
                    anchors.fill: parent
                    // Tint moved to the window-level scrim (which also covers the
                    // search/selector strip); this layer just hosts the spinner.
                    color: "transparent"
                    visible: window.showLoadingOverlay
                    z: 10
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: window.s(15)
                        Item {
                            Layout.alignment: Qt.AlignHCenter
                            width: window.s(34); height: window.s(34)
                            property real spinAngle: 0
                            NumberAnimation on spinAngle {
                                from: 0; to: 360; duration: 900
                                // Only spin while the loading overlay is actually shown (and the
                                // popup is visible). Was running:true → a 60fps Canvas repaint
                                // forever, even after load finished and while the popup was hidden.
                                loops: Animation.Infinite
                                running: window.visible && window.showLoadingOverlay
                                easing.type: Easing.Linear
                            }
                            Canvas {
                                anchors.fill: parent
                                property real angle: parent.spinAngle
                                onAngleChanged: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.reset()
                                    var cx = width / 2, cy = height / 2, r = width / 2 - 3
                                    var startRad = (parent.spinAngle - 90) * Math.PI / 180
                                    var endRad = startRad + 1.7 * Math.PI
                                    ctx.beginPath()
                                    ctx.arc(cx, cy, r, startRad, endRad)
                                    ctx.strokeStyle = window.mauve
                                    ctx.lineWidth = 3
                                    ctx.lineCap = "round"
                                    ctx.stroke()
                                }
                            }
                        }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "Loading..."; color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(14) }
                    }
                }
                Item {
                    anchors.fill: parent; anchors.margins: window.s(15); visible: !window.isSearchingNetwork
                    Component {
                        id: gridHighlightComp
                        Item {
                            z: 0
                            Rectangle {
                                color: window.surface0; border.color: window.surface1; border.width: 1; radius: window.s(10)
                                property real actX: parent.GridView.view.currentItem ? parent.GridView.view.currentItem.x + window.s(5) : 0
                                property real actY: parent.GridView.view.currentItem ? parent.GridView.view.currentItem.y + window.s(5) : 0
                                x: actX; y: actY; width: parent.GridView.view.cellWidth - window.s(10); height: parent.GridView.view.cellHeight - window.s(10)
                                Behavior on actX { enabled: window.isKeyboardNav; NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                                Behavior on actY { enabled: window.isKeyboardNav; NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                                opacity: parent.GridView.view.count > 0 && parent.GridView.view.currentIndex >= 0 ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 300 } }
                            }
                        }
                    }
                    Component {
                        id: mediaGridDelegate
                        Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0; z: 1
                            Rectangle {
                                id: cardRect
                                anchors.fill: parent; anchors.margins: window.s(5); radius: window.s(10); color: "transparent"
                                property bool isActive: parent.parent && parent.parent.GridView.view ? index === parent.parent.GridView.view.currentIndex : false
                                // ── Library flip (like the MAL card / continue-watching remove):
                                // the ★ flips this card to a status picker on the back. Captured
                                // model fields so the back's Repeater (its own model context) can
                                // still reach this item. ──
                                property bool libFlipped: false
                                property string cardImdb: model.imdbId || ""
                                property string cardTitle: model.title || ""
                                property string cardPoster: model.poster || ""
                                property string cardType: model.type || ""
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: window.s(10); spacing: window.s(8)
                                    Rectangle {
                                        id: posterBox
                                        Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(8); color: window.crust; clip: true
                                        // Flip THIS poster box (not the whole card) so the status back
                                        // lands exactly where the poster was — the title row below stays put.
                                        transform: Rotation {
                                            id: libFlip
                                            origin.x: posterBox.width / 2; origin.y: posterBox.height / 2
                                            axis.x: 0; axis.y: 1; axis.z: 0
                                            angle: cardRect.libFlipped ? 180 : 0
                                            Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
                                        }
                                        scale: parent.parent.isActive && window.isKeyboardNav ? 1.03 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                                        Image {
                                            id: gridImage
                                            anchors.fill: parent
                                            source: model.poster !== "" ? model.poster : ""
                                            fillMode: Image.PreserveAspectCrop
                                            // Decode at card resolution, not the poster's native size.
                                            sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                                            asynchronous: true; smooth: true; cache: true
                                            visible: status === Image.Ready
                                        }
                                        Rectangle {
                                            anchors.fill: parent; color: window.surface0
                                            visible: model.poster === "" || gridImage.status === Image.Error || gridImage.status === Image.Loading
                                            radius: window.s(8)
                                            property bool isLoading: model.poster !== "" && gridImage.status === Image.Loading
                                            Rectangle {
                                                anchors.fill: parent; radius: window.s(8); color: "transparent"
                                                visible: parent.isLoading
                                                Rectangle {
                                                    width: parent.width * 0.4; height: parent.height
                                                    color: Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.4)
                                                    property real shimX: -parent.parent.width
                                                    x: shimX
                                                    NumberAnimation on shimX {
                                                        from: parent && parent.parent ? -parent.parent.width : 0
                                                        to: parent && parent.parent ? parent.parent.width * 1.5 : 0
                                                        duration: 1200; loops: Animation.Infinite
                                                        running: (parent && parent.parent && parent.parent.parent && parent.parent.parent.isLoading) === true
                                                        easing.type: Easing.InOutSine
                                                    }
                                                }
                                            }
                                            Text { anchors.centerIn: parent; width: parent.width - window.s(10); text: model.title || "Unknown"; textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; visible: !parent.isLoading }
                                        }
                                        Rectangle {
                                            anchors.fill: parent; radius: window.s(8)
                                            color: window.sectionAccent
                                            opacity: parent.parent.parent.isActive ? 0.2 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                        // ── BACK: status picker. Fills the poster box (same rect as
                                        // the poster) + counter-rotated, so it lands exactly where the
                                        // poster was. On top → covers the front when flipped. ──
                                        Rectangle {
                                            anchors.fill: parent; radius: window.s(8)
                                            color: window.surface0; border.width: 1
                                            border.color: Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.5)
                                            visible: libFlip.angle >= 90
                                            transform: Rotation { origin.x: posterBox.width / 2; origin.y: posterBox.height / 2; axis.x: 0; axis.y: 1; axis.z: 0; angle: 180 }
                                            MouseArea { anchors.fill: parent; onClicked: cardRect.libFlipped = false }
                                            Column {
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: window.s(8); anchors.rightMargin: window.s(8)
                                                spacing: window.s(5)
                                                Text { width: parent.width
                                                       text: window.libInLibrary(cardRect.cardImdb) ? "Move to" : "Add to Library"
                                                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(9)
                                                       font.weight: Font.Bold; horizontalAlignment: Text.AlignHCenter; bottomPadding: window.s(2) }
                                                Repeater {
                                                    model: window.malStatuses
                                                    delegate: Rectangle {
                                                        width: parent.width; height: window.s(24); radius: window.s(6)
                                                        property bool current: modelData.key === window.libStatusOf(cardRect.cardImdb)
                                                        color: current ? window.sectionAccent
                                                            : stMouse.containsMouse ? Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.22)
                                                            : window.surface1
                                                        Behavior on color { ColorAnimation { duration: 130 } }
                                                        Text { anchors.centerIn: parent; text: modelData.label
                                                               font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                                               font.weight: parent.current ? Font.Bold : Font.Medium
                                                               color: parent.current ? window.crust : window.text }
                                                        MouseArea { id: stMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: { cardRect.libFlipped = false
                                                                window.libSet({ imdbId: cardRect.cardImdb, title: cardRect.cardTitle,
                                                                                poster: cardRect.cardPoster, type: cardRect.cardType }, modelData.key) } }
                                                    }
                                                }
                                                Rectangle {
                                                    width: parent.width; height: window.s(20); radius: window.s(6)
                                                    visible: window.libInLibrary(cardRect.cardImdb)
                                                    color: rmMouse2.containsMouse ? Qt.rgba(window.red.r, window.red.g, window.red.b, 0.28) : "transparent"
                                                    Text { anchors.centerIn: parent; text: "✕ Remove"; font.family: "JetBrains Mono"; font.pixelSize: window.s(9); color: window.red }
                                                    MouseArea { id: rmMouse2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                        onClicked: { cardRect.libFlipped = false; window.libRemove(cardRect.cardImdb) } }
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true; text: model.title; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                        color: parent.parent.isActive ? window.text : window.subtext0
                                        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; lineHeight: 1.1; horizontalAlignment: Text.AlignHCenter
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                    Text { Layout.fillWidth: true; text: model.year !== "N/A" ? model.year : ""; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.surface2; horizontalAlignment: Text.AlignHCenter; visible: text !== "" }
                                }
                                MouseArea {
                                    anchors.fill: parent; hoverEnabled: true
                                    enabled: libFlip.angle < 90
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onEntered: { window.isKeyboardNav = false; parent.parent.GridView.view.currentIndex = index }
                                    // Right-click = same shelf picker the ★ opens.
                                    onClicked: (m) => {
                                        if (m.button === Qt.RightButton) cardRect.libFlipped = true
                                        else openItem(model)
                                    }
                                }
                                // (★ bookmark removed — right-click on the card opens the
                                //  same shelf picker on every home surface now)
                            }
                        }
                    }
                    GridView {
                        id: searchGrid
                        anchors.fill: parent; visible: window.isSearchMode && window.mediaType !== "youtube"
                        model: searchResults; cellWidth: Math.floor(width / 5); cellHeight: cellWidth * 1.5 + window.s(60)
                        boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        add: Transition { ParallelAnimation { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 400; easing.type: Easing.OutQuart } NumberAnimation { property: "y"; from: y + window.s(30); duration: 500; easing.type: Easing.OutQuart } NumberAnimation { property: "scale"; from: 0.9; to: 1; duration: 500; easing.type: Easing.OutBack } } }
                        highlight: gridHighlightComp; delegate: mediaGridDelegate
                    }
                    GridView {
                        id: movieGrid
                        anchors.fill: parent; visible: !window.isSearchMode && window.mediaType === "movie"
                        model: cachedTrendingMovies; cellWidth: Math.floor(width / 10); cellHeight: cellWidth * 1.5 + window.s(60)
                        header: dashboardHeaderComp; boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        highlight: gridHighlightComp; delegate: mediaGridDelegate
                    }
                    GridView {
                        id: tvGrid
                        anchors.fill: parent; visible: !window.isSearchMode && window.mediaType === "tv"
                        model: cachedTrendingTv; cellWidth: Math.floor(width / 10); cellHeight: cellWidth * 1.5 + window.s(60)
                        header: dashboardHeaderComp; boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        highlight: gridHighlightComp; delegate: mediaGridDelegate
                    }
                    GridView {
                        id: animeGrid
                        anchors.fill: parent; visible: !window.isSearchMode && window.mediaType === "anime"
                        model: cachedTrendingAnime; cellWidth: Math.floor(width / 10); cellHeight: cellWidth * 1.5 + window.s(60)
                        header: dashboardHeaderComp; boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        highlight: gridHighlightComp; delegate: mediaGridDelegate
                    }
                    // YouTube results delegate — 16:9 thumbnail card.
                    Component {
                        id: ytGridDelegate
                        Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0; z: 1
                            Rectangle {
                                anchors.fill: parent; anchors.margins: window.s(6); radius: window.s(10); color: "transparent"
                                property bool isActive: parent.parent && parent.parent.GridView.view ? index === parent.parent.GridView.view.currentIndex : false
                                // Play-on-click area — declared FIRST so it's the BOTTOM
                                // layer: the channel-name and ＋playlist MouseAreas inside
                                // the column stack above it and take their own clicks
                                // (declared after the column, it swallowed them all).
                                MouseArea {
                                    anchors.fill: parent; hoverEnabled: true
                                    onEntered: { window.isKeyboardNav = false; parent.parent.GridView.view.currentIndex = index }
                                    onClicked: playYouTube(model.vid, model.title, model.channelId, model.channel)
                                }
                                ColumnLayout {
                                    id: ytCardCol
                                    anchors.fill: parent; anchors.margins: window.s(6); spacing: window.s(6)
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: width * 9 / 16
                                        radius: window.s(8); color: window.crust; clip: true
                                        scale: parent.parent.isActive && window.isKeyboardNav ? 1.03 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                                        Image {
                                            id: ytThumb
                                            anchors.fill: parent
                                            // Prefer YouTubio's higher-res poster (WebP — renders now that the Qt
                                            // WebP plugin is installed); fall back to the clean vid-derived JPEG.
                                            source: (model.thumb && model.thumb !== "") ? model.thumb
                                                : (model.vid ? ("https://i.ytimg.com/vi/" + model.vid + "/hqdefault.jpg") : "")
                                            fillMode: Image.PreserveAspectCrop
                                            sourceSize.width: window.s(400); sourceSize.height: window.s(225)
                                            asynchronous: true; smooth: true; cache: true
                                            visible: status === Image.Ready
                                        }
                                        Rectangle {
                                            anchors.fill: parent; color: window.surface0; radius: window.s(8)
                                            visible: ytThumb.status !== Image.Ready
                                            Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(24); color: window.red }
                                        }
                                        Rectangle {
                                            visible: model.duration !== ""
                                            anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: window.s(5)
                                            radius: window.s(4); color: Qt.rgba(0, 0, 0, 0.8)
                                            width: ytDurTxt.width + window.s(10); height: ytDurTxt.height + window.s(4)
                                            Text { id: ytDurTxt; anchors.centerIn: parent; text: ytDurationLabel(model.duration); color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(10) }
                                        }
                                        // Watch progress (YouTube-style red bar along the bottom).
                                        Rectangle {
                                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                            height: window.s(3)
                                            color: Qt.rgba(1, 1, 1, 0.14)
                                            visible: ytProgFill.frac > 0
                                            Rectangle {
                                                id: ytProgFill
                                                readonly property real frac: window.watchFrac("yt:" + model.vid)
                                                width: parent.width * frac; height: parent.height
                                                color: window.red
                                            }
                                        }
                                        Rectangle {
                                            anchors.fill: parent; radius: window.s(8); color: window.red
                                            opacity: parent.parent.parent.isActive ? 0.18 : 0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }
                                        // Add-to-playlist (＋), top-left of the thumbnail.
                                        Rectangle {
                                            anchors.left: parent.left; anchors.top: parent.top; anchors.margins: window.s(5)
                                            width: window.s(26); height: window.s(26); radius: width / 2; z: 6
                                            color: addPlMouse.containsMouse ? window.red : Qt.rgba(0, 0, 0, 0.6)
                                            Text { anchors.centerIn: parent; text: "+"; font.family: "JetBrains Mono"; font.pixelSize: window.s(17); font.weight: Font.Bold; color: "white" }
                                            MouseArea { id: addPlMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: ytOpenAddPicker(model.vid, model.title, model.channelId, model.channel, model.thumb) }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true; text: model.title; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                        color: parent.parent.isActive ? window.text : window.subtext0
                                        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; lineHeight: 1.1
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: window.s(6)
                                        visible: (model.channel || "") !== "" || (model.dateStr || "") !== ""
                                        Text {
                                            id: chCellText
                                            Layout.fillWidth: false
                                            // Cap against the card column, not the RowLayout itself —
                                            // reading the row's own width from a child recurses layout.
                                            Layout.maximumWidth: ytCardCol.width * 0.7
                                            text: model.channel; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                            color: chCellMouse.containsMouse ? window.red : window.surface2; elide: Text.ElideRight; visible: text !== ""
                                            MouseArea {
                                                id: chCellMouse; anchors.fill: parent; hoverEnabled: true; z: 5
                                                cursorShape: Qt.PointingHandCursor; enabled: (model.channelId || "") !== ""
                                                onClicked: openYoutubeChannel(model.channelId, model.channel)
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            visible: (model.dateStr || "") !== ""
                                            text: ((model.channel || "") !== "" ? "· " : "") + (model.dateStr || "")
                                            font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                            color: window.surface2; elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }
                    GridView {
                        id: ytGrid
                        anchors.fill: parent
                        anchors.topMargin: window.mediaType !== "youtube" ? 0
                            : (window.ytView === "videos" && ytChannels.count > 0) ? window.s(98)
                            : (window.ytView === "channel" || window.ytView === "playlist" || window.youtubioBrowseCatalogs.length > 0) ? window.s(46) : 0
                        visible: window.mediaType === "youtube" && window.ytView !== "channels" && window.ytView !== "playlists" && window.ytView !== "history"
                        model: ytResults; cellWidth: Math.floor(width / 4); cellHeight: Math.floor(cellWidth * 9 / 16) + window.s(82)
                        boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        // Infinite scroll: reaching the bottom pulls the next batch and
                        // shows a loading footer while it lands.
                        onAtYEndChanged: if (atYEnd && count > 0 && visible) window.ytLoadMore()
                        footer: Item {
                            width: ytGrid.width
                            height: window.ytMoreLoading ? window.s(64) : 0
                            visible: window.ytMoreLoading
                            Row {
                                anchors.centerIn: parent; spacing: window.s(10)
                                BusyIndicator { running: window.ytMoreLoading; implicitWidth: window.s(26); implicitHeight: window.s(26); anchors.verticalCenter: parent.verticalCenter }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Loading more videos…"
                                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                            }
                        }
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        // No `add` transition: the home feed loads ~100 items from cache in one
                        // synchronous burst, and animating them all at once made the tiles pile
                        // up at the origin before settling into the grid.
                        highlight: gridHighlightComp; delegate: ytGridDelegate
                    }
                    // YouTubio catalog chips — your configured channels / playlists.
                    ListView {
                        id: ytCatBar
                        visible: window.mediaType === "youtube" && window.ytSource === "youtubio" && window.youtubioBrowseCatalogs.length > 0
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: window.s(40); z: 6
                        orientation: ListView.Horizontal; spacing: window.s(8); clip: true
                        model: window.youtubioBrowseCatalogs
                        delegate: Rectangle {
                            height: window.s(32); y: (ytCatBar.height - height) / 2
                            width: chipText.width + window.s(26); radius: window.s(8)
                            property bool sel: window.youtubioCatalog === modelData.id
                            color: sel ? window.red : (chipMouse.containsMouse ? window.surface1 : window.surface0)
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                id: chipText; anchors.centerIn: parent; text: modelData.name
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                font.weight: parent.sel ? Font.Bold : Font.Medium
                                color: parent.sel ? window.crust : window.text
                            }
                            MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: youtubioLoadCatalog(modelData.id) }
                        }
                    }

                    // Channel-search results — square cards with Subscribe + open.
                    // ── Channels page (subscriptions): channel rail on the left,
                    //    every subscribed channel's uploads newest-first on the right ──
                    Item {
                        visible: window.mediaType === "youtube" && window.ytView === "channels" && window.ytChannelsIsSubs
                        anchors.fill: parent
                        ListView {
                            id: ytSubsRail
                            width: window.s(230)
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            model: ytChannels; spacing: window.s(6); clip: true
                            ScrollBar.vertical: ScrollBar { contentItem: Rectangle { radius: window.s(2); color: window.surface2; implicitWidth: window.s(4) } }
                            delegate: Rectangle {
                                width: ytSubsRail.width - window.s(8); height: window.s(52); radius: window.s(10)
                                color: railMouse.containsMouse ? window.surface1 : window.surface0
                                Behavior on color { ColorAnimation { duration: 150 } }
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: window.s(10); anchors.rightMargin: window.s(10)
                                    spacing: window.s(10)
                                    Rectangle {
                                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                                        radius: width / 2; color: window.crust; clip: true
                                        Image { anchors.fill: parent; source: model.thumb || ""
                                                fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true; cache: true
                                                visible: status === Image.Ready }
                                        Text { anchors.centerIn: parent; visible: (model.thumb || "") === ""
                                               text: (model.name || "?").charAt(0).toUpperCase()
                                               font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold; color: window.red }
                                    }
                                    Text { Layout.fillWidth: true; text: model.name; textFormat: Text.PlainText
                                           font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Medium
                                           color: window.text; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap }
                                }
                                MouseArea { id: railMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: openYoutubeChannel(model.channelId, model.name) }
                            }
                            Text {
                                anchors.centerIn: parent; width: parent.width - window.s(16)
                                visible: ytChannels.count === 0
                                text: "No subscriptions yet — search a creator and hit Subscribe."
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                            }
                        }
                        GridView {
                            id: ytSubsGrid
                            anchors { left: ytSubsRail.right; leftMargin: window.s(14)
                                      right: parent.right; top: parent.top; bottom: parent.bottom }
                            model: ytSubsVideos
                            cellWidth: Math.floor(width / 3); cellHeight: Math.floor(cellWidth * 9 / 16) + window.s(82)
                            boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                            highlight: gridHighlightComp; delegate: ytGridDelegate
                            Text {
                                anchors.centerIn: parent
                                visible: ytSubsVideos.count === 0 && !window.isSearchingYt && ytChannels.count > 0
                                text: "Loading your subscriptions feed failed — reopen the page to retry."
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                            }
                        }
                    }
                    GridView {
                        id: ytChannelGrid
                        anchors.fill: parent
                        visible: window.mediaType === "youtube" && window.ytView === "channels" && !window.ytChannelsIsSubs
                        model: ytChannels; cellWidth: Math.floor(width / 5); cellHeight: cellWidth + window.s(76)
                        boundsBehavior: Flickable.StopAtBounds; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        delegate: Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0
                            readonly property bool subbed: window.isSubscribed(model.channelId)
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(6)
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: parent.width - window.s(28); Layout.preferredHeight: Layout.preferredWidth
                                    radius: width / 2; color: window.crust; clip: true
                                    Image { anchors.fill: parent; source: model.thumb; fillMode: Image.PreserveAspectCrop; sourceSize.width: window.s(320); sourceSize.height: window.s(180); asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready }
                                    Text { anchors.centerIn: parent; visible: model.thumb === ""; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(26); color: window.red }
                                    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: openYoutubeChannel(model.channelId, model.name) }
                                }
                                Text { Layout.fillWidth: true; text: model.name; horizontalAlignment: Text.AlignHCenter; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight; maximumLineCount: 1 }
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: window.s(104); Layout.preferredHeight: window.s(28); radius: window.s(8)
                                    color: subbed ? window.surface1 : window.red
                                    Text { anchors.centerIn: parent; text: subbed ? "Subscribed" : "Subscribe"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold; color: subbed ? window.subtext0 : window.crust }
                                    MouseArea {
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (subbed) unsubscribeChannel(model.channelId)
                                            else subscribeChannel(model.channelId, model.name, model.thumb)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Channel-view header — name + Subscribe toggle + back.
                    Rectangle {
                        id: chHeader
                        visible: window.mediaType === "youtube" && window.ytView === "channel"
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: window.s(40); z: 6; color: "transparent"
                        readonly property bool subbed: window.isSubscribed(window.ytChannelId)
                        RowLayout {
                            anchors.fill: parent; spacing: window.s(10)
                            Rectangle {
                                Layout.preferredWidth: window.s(34); Layout.preferredHeight: window.s(30); radius: window.s(8)
                                color: chBackMouse.containsMouse ? window.surface1 : window.surface0
                                Text { anchors.centerIn: parent; text: "←"; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); color: window.text }
                                MouseArea { id: chBackMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { ytResults.clear(); if (window.ytReturnView === "channels") ytShowSubscribedChannels(); else { window.ytView = "home"; youtubeHomeFeed() } } }
                            }
                            Text { Layout.fillWidth: true; text: window.ytChannelName; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight }
                            Rectangle {
                                Layout.preferredWidth: window.s(110); Layout.preferredHeight: window.s(30); radius: window.s(8)
                                color: chHeader.subbed ? window.surface1 : window.red
                                Text { anchors.centerIn: parent; text: chHeader.subbed ? "Subscribed" : "Subscribe"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold; color: chHeader.subbed ? window.subtext0 : window.crust }
                                MouseArea {
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (chHeader.subbed) unsubscribeChannel(window.ytChannelId)
                                        else subscribeChannel(window.ytChannelId, window.ytChannelName, "")
                                    }
                                }
                            }
                        }
                    }

                    // Search results: a strip of matching channels above the videos.
                    ListView {
                        id: ytSearchChStrip
                        visible: window.mediaType === "youtube" && window.ytView === "videos" && ytChannels.count > 0
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: window.s(92); z: 6
                        orientation: ListView.Horizontal; spacing: window.s(8); clip: true
                        model: ytChannels
                        delegate: Item {
                            width: window.s(78); height: ytSearchChStrip.height
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: window.s(4); spacing: window.s(4)
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: window.s(56); Layout.preferredHeight: window.s(56)
                                    radius: width / 2; color: window.crust; clip: true
                                    Image { anchors.fill: parent; source: model.thumb; fillMode: Image.PreserveAspectCrop; sourceSize.width: window.s(320); sourceSize.height: window.s(180); asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready }
                                    Text { anchors.centerIn: parent; visible: model.thumb === ""; text: "󰗃"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(20); color: window.red }
                                }
                                Text { Layout.fillWidth: true; text: model.name; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1; font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0 }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: openYoutubeChannel(model.channelId, model.name) }
                        }
                    }

                    // Playlist-view header — back + name + delete.
                    Rectangle {
                        visible: window.mediaType === "youtube" && window.ytView === "playlist"
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: window.s(40); z: 6; color: "transparent"
                        RowLayout {
                            anchors.fill: parent; spacing: window.s(10)
                            Rectangle {
                                Layout.preferredWidth: window.s(34); Layout.preferredHeight: window.s(30); radius: window.s(8)
                                color: plBackMouse.containsMouse ? window.surface1 : window.surface0
                                Text { anchors.centerIn: parent; text: "←"; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); color: window.text }
                                MouseArea { id: plBackMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { ytResults.clear(); ytGoPage("playlists") } }
                            }
                            Text { Layout.fillWidth: true; text: window.ytPlaylistName; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight }
                            Rectangle {
                                Layout.preferredWidth: window.s(84); Layout.preferredHeight: window.s(30); radius: window.s(8)
                                color: plDelMouse.containsMouse ? window.red : window.surface0
                                Text { anchors.centerIn: parent; text: "Delete"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold; color: plDelMouse.containsMouse ? window.crust : window.subtext0 }
                                MouseArea { id: plDelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: ytPlaylistDelete(window.ytPlaylistId) }
                            }
                        }
                    }

                    // Playlists page — your local playlists + New.
                    Flickable {
                        visible: window.mediaType === "youtube" && window.ytView === "playlists"
                        anchors.fill: parent; clip: true
                        contentHeight: plCol.implicitHeight + window.s(8)
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        ColumnLayout {
                            id: plCol
                            x: window.s(2); width: parent.width - window.s(8); spacing: window.s(8)
                            Rectangle {
                                Layout.preferredWidth: window.s(160); Layout.preferredHeight: window.s(40); radius: window.s(10)
                                color: plNewMouse.containsMouse ? window.red : window.surface0
                                Text { anchors.centerIn: parent; text: "+  New playlist"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; color: plNewMouse.containsMouse ? window.crust : window.text }
                                MouseArea { id: plNewMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: ytPlaylistCreate("Playlist " + (window.ytPlaylists.length + 1)) }
                            }
                            Repeater {
                                model: window.ytPlaylists
                                delegate: Rectangle {
                                    // Search box filters playlists live by name.
                                    visible: window.ytPageFilter === ""
                                             || (modelData.name || "").toLowerCase().indexOf(window.ytPageFilter) >= 0
                                    Layout.fillWidth: true; Layout.preferredHeight: window.s(56); radius: window.s(10)
                                    color: plRowMouse.containsMouse ? window.surface1 : window.surface0
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: window.s(14); anchors.rightMargin: window.s(14); spacing: window.s(12)
                                        Text { text: "󰐑"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(20); color: window.red }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 0
                                            Text { Layout.fillWidth: true; text: modelData.name; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight }
                                            Text { text: (modelData.items ? modelData.items.length : 0) + " videos"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0 }
                                        }
                                        Text { text: "󰅂"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(16); color: window.subtext0 }
                                    }
                                    MouseArea { id: plRowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ytPlaylistOpen(modelData.id) }
                                }
                            }
                            Text { visible: window.ytPlaylists.length === 0; Layout.fillWidth: true; Layout.topMargin: window.s(24)
                                text: "No playlists yet. Make one, then add videos with the ＋ on each tile."
                                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13) }
                        }
                    }

                    // History page — your AI watch-history summaries (newest first).
                    Flickable {
                        visible: window.mediaType === "youtube" && window.ytView === "history"
                        anchors.fill: parent; clip: true
                        contentHeight: histCol.implicitHeight + window.s(8)
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        ColumnLayout {
                            id: histCol
                            x: window.s(2); width: parent.width - window.s(8); spacing: window.s(8)
                            Repeater {
                                model: ytHistoryModel
                                delegate: Rectangle {
                                    // Search box filters the page live (title/channel/summary).
                                    visible: window.ytPageFilter === ""
                                             || (model.title + " " + model.channel + " " + model.summary).toLowerCase().indexOf(window.ytPageFilter) >= 0
                                    Layout.fillWidth: true; Layout.preferredHeight: histRow.implicitHeight + window.s(20); radius: window.s(10)
                                    color: histRowMouse.containsMouse ? window.surface1 : window.surface0
                                    RowLayout {
                                        id: histRow
                                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: window.s(14); rightMargin: window.s(14) }
                                        spacing: window.s(12)
                                        Rectangle {
                                            visible: model.vid !== ""
                                            Layout.preferredWidth: window.s(96); Layout.preferredHeight: window.s(54); radius: window.s(6); color: window.crust; clip: true
                                            Image { anchors.fill: parent; source: model.vid ? ("https://i.ytimg.com/vi/" + model.vid + "/mqdefault.jpg") : ""
                                                fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready }
                                            // Watch progress — same red bar as the video grids.
                                            Rectangle {
                                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                                height: window.s(3)
                                                color: Qt.rgba(1, 1, 1, 0.14)
                                                visible: histProgFill.frac > 0
                                                Rectangle {
                                                    id: histProgFill
                                                    readonly property real frac: window.watchFrac("yt:" + model.vid)
                                                    width: parent.width * frac; height: parent.height
                                                    color: window.red
                                                }
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: window.s(3)
                                            Text { Layout.fillWidth: true; text: model.title; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight; maximumLineCount: 1 }
                                            Text {
                                                Layout.fillWidth: true; visible: model.channel !== ""; text: model.channel
                                                font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                                color: histChM.containsMouse ? window.red : window.surface2
                                                Behavior on color { ColorAnimation { duration: 120 } }
                                                elide: Text.ElideRight; maximumLineCount: 1
                                                // Channel name → that channel's uploads. Old history
                                                // entries predate the stored channel id — fall back to
                                                // a search for the channel name (its chip appears in
                                                // the strip above the results).
                                                MouseArea {
                                                    id: histChM; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if ((model.cid || "") !== "") openYoutubeChannel(model.cid, model.channel)
                                                        else { searchInput.text = model.channel; ytSearchDispatch(model.channel) }
                                                    }
                                                }
                                            }
                                            Text { Layout.fillWidth: true; visible: model.summary !== ""; text: model.summary; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                                        }
                                    }
                                    MouseArea { id: histRowMouse; anchors.fill: parent; hoverEnabled: true
                                        z: -1   // under the channel-name MouseArea
                                        cursorShape: model.vid !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: { if (model.vid !== "") playYouTube(model.vid, model.title, model.cid || "", model.channel || "") } }
                                }
                            }
                            Text { visible: ytHistoryModel.count === 0 && !window.ytHistoryLoading; Layout.fillWidth: true; Layout.topMargin: window.s(24)
                                text: "No history yet. Use the AI “Parse this video” button in the player — each summary is saved here and your AI can search it."
                                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                                color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13) }
                        }
                    }

                    ColumnLayout {
                        anchors.centerIn: parent; spacing: window.s(12)
                        visible: window.mediaType === "youtube" && window.ytView !== "playlists" && window.ytView !== "history" && ytResults.count === 0 && ytChannels.count === 0 && !window.isSearchingYt
                        Text { Layout.alignment: Qt.AlignHCenter; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(44); color: window.red }
                        Text {
                            Layout.alignment: Qt.AlignHCenter; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            Layout.maximumWidth: window.s(460)
                            text: window.ytView === "channel" ? "This channel has no videos to show"
                                : (window.ytView === "home" && window.youtubeSubs.length === 0 && window.ytWatchedChannels.length === 0)
                                    ? "Home learns from what you watch. Search for videos/creators and play something, or Subscribe to channels."
                                : "No videos — try a search"
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
                        }
                        Text { Layout.alignment: Qt.AlignHCenter; text: "Plays in the embedded player"; color: window.surface2; font.family: "JetBrains Mono"; font.pixelSize: window.s(11) }
                    }

                    // ── Music: album grid (Navidrome / Subsonic) ──
                    GridView {
                        id: musicGrid
                        anchors.fill: parent
                        visible: window.mediaType === "music"
                        model: musicAlbums; cellWidth: Math.floor(width / 5); cellHeight: cellWidth + window.s(64)
                        boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        add: Transition { ParallelAnimation { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 400; easing.type: Easing.OutQuart } NumberAnimation { property: "scale"; from: 0.9; to: 1; duration: 500; easing.type: Easing.OutBack } } }
                        delegate: Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(6)
                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: width
                                    radius: window.s(10); color: window.crust; clip: true
                                    Image {
                                        id: albCover; anchors.fill: parent
                                        source: model.cover; fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: window.s(300); sourceSize.height: window.s(300)
                                        asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready
                                    }
                                    Text { anchors.centerIn: parent; visible: albCover.status !== Image.Ready
                                        text: "󰎈"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(30); color: window.musicAccent }
                                    Rectangle { anchors.fill: parent; radius: window.s(10); color: window.musicAccent
                                        opacity: albMouse.containsMouse ? 0.16 : 0; Behavior on opacity { NumberAnimation { duration: 180 } } }
                                }
                                Text { Layout.fillWidth: true; text: model.name; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                    color: window.text; elide: Text.ElideRight; maximumLineCount: 1 }
                                Text { Layout.fillWidth: true; text: model.artist; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                    color: window.subtext0; elide: Text.ElideRight; visible: text !== "" }
                            }
                            MouseArea { id: albMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: openAlbum(model.albumId, model.name, model.artist, model.cover) }
                        }
                    }
                    // Music empty / not-configured state.
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: window.s(12)
                        visible: window.mediaType === "music" && musicAlbums.count === 0 && !window.isSearchingMusic
                        Text { Layout.alignment: Qt.AlignHCenter; text: "󰎈"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(44); color: window.musicAccent }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: window.subsonicReady ? "No albums — search your library above" : "Add navidrome_url / _user / _pass to ~/.config/hypr/config.json"
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            Layout.maximumWidth: window.s(420)
                        }
                    }
                    // ── Games: Steam library (local files), Big-Picture-style capsules ──
                    GridView {
                        id: gamesGrid
                        anchors.fill: parent
                        visible: window.mediaType === "games" && gamesModel.count > 0
                        model: gamesModel
                        cellWidth: Math.floor(width / 6); cellHeight: Math.floor(cellWidth * 1.5) + window.s(34)
                        boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        // No `add` transition: the whole library loads in one synchronous burst,
                        // and animating every card at once stacked them before they settled.
                        delegate: Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(6)
                                Rectangle {
                                    id: capsule
                                    Layout.fillWidth: true; Layout.preferredHeight: width * 1.5
                                    radius: window.s(10); color: window.crust; clip: true
                                    scale: gameMouse.containsMouse ? 1.04 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                    Image {
                                        id: gameArt; anchors.fill: parent
                                        source: model.art; fillMode: Image.PreserveAspectCrop
                                        asynchronous: true; smooth: true; cache: true
                                        sourceSize.width: window.s(300); sourceSize.height: window.s(450)
                                        visible: status === Image.Ready
                                    }
                                    // Fallback tile when no art resolves (e.g. unreleased title).
                                    Rectangle {
                                        anchors.fill: parent; visible: gameArt.status !== Image.Ready
                                        radius: window.s(10)
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(window.gamesAccent.r, window.gamesAccent.g, window.gamesAccent.b, 0.28) }
                                            GradientStop { position: 1.0; color: window.crust }
                                        }
                                        ColumnLayout {
                                            anchors.centerIn: parent; width: parent.width - window.s(20); spacing: window.s(8)
                                            Text { Layout.alignment: Qt.AlignHCenter; text: "󰓓"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(34); color: window.gamesAccent }
                                            Text { Layout.fillWidth: true; text: model.name; color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight }
                                        }
                                    }
                                    // Hover: dim + play affordance.
                                    Rectangle {
                                        anchors.fill: parent; radius: window.s(10); color: "black"
                                        opacity: gameMouse.containsMouse ? 0.42 : 0
                                        Behavior on opacity { NumberAnimation { duration: 160 } }
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: window.s(52); height: window.s(52); radius: width / 2
                                        color: Qt.rgba(window.gamesAccent.r, window.gamesAccent.g, window.gamesAccent.b, 0.92)
                                        opacity: gameMouse.containsMouse ? 1 : 0
                                        scale: gameMouse.containsMouse ? 1 : 0.6
                                        Behavior on opacity { NumberAnimation { duration: 160 } }
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                                        Text { anchors.centerIn: parent; text: "󰐊"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(26); color: window.crust }
                                    }
                                    // accent ring on hover
                                    Rectangle { anchors.fill: parent; radius: window.s(10); color: "transparent"
                                        border.width: gameMouse.containsMouse ? 2 : 0; border.color: window.gamesAccent }
                                }
                                Text { Layout.fillWidth: true; text: model.name; visible: text !== ""; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                    color: gameMouse.containsMouse ? window.gamesAccent : window.text; elide: Text.ElideRight; maximumLineCount: 1; horizontalAlignment: Text.AlignHCenter }
                            }
                            MouseArea { id: gameMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: launchGame(model.appid) }
                        }
                    }
                    // Games loading / empty / not-found state.
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: window.s(12)
                        visible: window.mediaType === "games" && gamesModel.count === 0
                        BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: window.gamesLoading; visible: window.gamesLoading
                            implicitWidth: window.s(40); implicitHeight: window.s(40) }
                        Text { Layout.alignment: Qt.AlignHCenter; visible: !window.gamesLoading; text: "󰓓"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(48); color: window.gamesAccent }
                        Text { Layout.alignment: Qt.AlignHCenter; text: window.gamesLoading ? "Reading your Steam library…" : "Steam Library"
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(18); font.weight: Font.Bold; color: window.text }
                        Text {
                            Layout.alignment: Qt.AlignHCenter; visible: !window.gamesLoading
                            text: "No installed games found in your local Steam libraries."
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            Layout.maximumWidth: window.s(420)
                        }
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter; visible: !window.gamesLoading
                            Layout.preferredWidth: window.s(120); Layout.preferredHeight: window.s(38); radius: window.s(10)
                            color: gamesReloadMouse.containsMouse ? window.surface2 : window.surface1
                            Text { anchors.centerIn: parent; text: "󰑐  Refresh"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); color: window.text }
                            MouseArea { id: gamesReloadMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: loadSteamGames(true) }
                        }
                    }
                    // ── Books: Kavita manga + novels, portrait covers ──
                    GridView {
                        id: booksGrid
                        anchors.fill: parent
                        visible: window.mediaType === "books" && booksModel.count > 0
                        model: booksModel
                        cellWidth: Math.floor(width / 6); cellHeight: Math.floor(cellWidth * 1.5) + window.s(46)
                        boundsBehavior: Flickable.StopAtBounds; highlightFollowsCurrentItem: false; clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        Behavior on contentY { NumberAnimation { duration: 300; easing.type: Easing.OutQuart } }
                        delegate: Item {
                            width: GridView.view ? GridView.view.cellWidth : 0; height: GridView.view ? GridView.view.cellHeight : 0
                            property bool isActive: index === GridView.view.currentIndex
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(6)
                                Rectangle {
                                    id: bookCard
                                    Layout.fillWidth: true; Layout.preferredHeight: width * 1.5
                                    radius: window.s(10); color: window.crust; clip: true
                                    scale: bookMouse.containsMouse ? 1.04 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                    Image {
                                        id: bookArt; anchors.fill: parent
                                        source: model.cover; fillMode: Image.PreserveAspectCrop
                                        asynchronous: true; smooth: true; cache: true
                                        sourceSize.width: window.s(300); sourceSize.height: window.s(450)
                                        visible: status === Image.Ready
                                    }
                                    // Fallback tile when no cover resolves.
                                    Rectangle {
                                        anchors.fill: parent; visible: bookArt.status !== Image.Ready
                                        radius: window.s(10)
                                        gradient: Gradient {
                                            GradientStop { position: 0.0; color: Qt.rgba(window.booksAccent.r, window.booksAccent.g, window.booksAccent.b, 0.28) }
                                            GradientStop { position: 1.0; color: window.crust }
                                        }
                                        ColumnLayout {
                                            anchors.centerIn: parent; width: parent.width - window.s(20); spacing: window.s(8)
                                            Text { Layout.alignment: Qt.AlignHCenter; text: "󰗚"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(34); color: window.booksAccent }
                                            Text { Layout.fillWidth: true; text: model.name; color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight }
                                        }
                                    }
                                    // Manga / Novel chip.
                                    Rectangle {
                                        anchors.top: parent.top; anchors.left: parent.left; anchors.margins: window.s(6)
                                        radius: window.s(6); height: window.s(18); width: typeChip.width + window.s(12)
                                        color: Qt.rgba(0, 0, 0, 0.55)
                                        Text { id: typeChip; anchors.centerIn: parent; text: model.type === "novel" ? "Novel" : "Manga"
                                            font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold; color: window.booksAccent }
                                    }
                                    // Hover: dim + open affordance.
                                    Rectangle {
                                        anchors.fill: parent; radius: window.s(10); color: "black"
                                        opacity: bookMouse.containsMouse ? 0.42 : 0
                                        Behavior on opacity { NumberAnimation { duration: 160 } }
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: window.s(52); height: window.s(52); radius: width / 2
                                        color: Qt.rgba(window.booksAccent.r, window.booksAccent.g, window.booksAccent.b, 0.92)
                                        opacity: bookMouse.containsMouse ? 1 : 0
                                        scale: bookMouse.containsMouse ? 1 : 0.6
                                        Behavior on opacity { NumberAnimation { duration: 160 } }
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                                        Text { anchors.centerIn: parent; text: "󰗚"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(24); color: window.crust }
                                    }
                                    // accent ring on hover / keyboard focus
                                    Rectangle { anchors.fill: parent; radius: window.s(10); color: "transparent"
                                        border.width: (bookMouse.containsMouse || isActive) ? 2 : 0; border.color: window.booksAccent }
                                }
                                Text { Layout.fillWidth: true; text: model.name; visible: text !== ""; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                                    color: bookMouse.containsMouse ? window.booksAccent : window.text; elide: Text.ElideRight; maximumLineCount: 1; horizontalAlignment: Text.AlignHCenter }
                            }
                            MouseArea { id: bookMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onEntered: { window.isKeyboardNav = false; parent.GridView.view.currentIndex = index }
                                onClicked: openBook(model) }
                        }
                    }
                    // Books loading / empty / not-configured state.
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: window.s(12)
                        visible: window.mediaType === "books" && booksModel.count === 0
                        BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: window.booksLoading; visible: window.booksLoading
                            implicitWidth: window.s(40); implicitHeight: window.s(40) }
                        Text { Layout.alignment: Qt.AlignHCenter; visible: !window.booksLoading; text: "󰗚"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(48); color: window.booksAccent }
                        Text { Layout.alignment: Qt.AlignHCenter; visible: !window.booksLoading
                            text: window.booksError === "no-key" || !window.kavitaReady ? "Kavita not configured"
                                : window.booksError === "auth" ? "Kavita rejected the API key"
                                : window.isSearchingBooks ? "No matches" : "Manga & Novels"
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(18); font.weight: Font.Bold; color: window.text }
                        Text {
                            Layout.alignment: Qt.AlignHCenter; visible: !window.booksLoading
                            text: window.booksError === "no-key" || !window.kavitaReady
                                    ? "Add your Kavita API key as \"kavita_api_key\" in ~/.config/hypr/config.json (Kavita → Settings → Account → API Key)."
                                : window.booksError === "auth"
                                    ? "The API key in config.json was rejected. Re-copy it from Kavita → Settings → Account → API Key."
                                : window.isSearchingBooks ? "No manga or novels match your search."
                                : "No manga or novels found in your Kavita libraries."
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            Layout.maximumWidth: window.s(440)
                        }
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter; visible: !window.booksLoading
                            Layout.preferredWidth: window.s(120); Layout.preferredHeight: window.s(38); radius: window.s(10)
                            color: booksReloadMouse.containsMouse ? window.surface2 : window.surface1
                            Text { anchors.centerIn: parent; text: "󰑐  Refresh"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); color: window.text }
                            MouseArea { id: booksReloadMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { window.booksLoaded = false; fetchBooks(searchInput.text) } }
                        }
                    }
                }
            }
        }
        // ==========================================
        // ALBUM VIEW  (track list for the selected album)
        // ==========================================
        RowLayout {
            anchors.fill: parent; anchors.margins: window.s(20); spacing: window.s(25)
            visible: window.currentView === "album"
            ColumnLayout {
                Layout.preferredWidth: window.s(240); Layout.minimumWidth: window.s(240); Layout.maximumWidth: window.s(240)
                Layout.fillHeight: true; spacing: window.s(14)
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(240); radius: window.s(14); color: window.crust; clip: true
                    Image { anchors.fill: parent; source: window.selectedAlbumCover; fillMode: Image.PreserveAspectCrop
                        asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready }
                    Text { anchors.centerIn: parent; text: "󰎈"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(48); color: window.musicAccent
                        visible: window.selectedAlbumCover === "" }
                }
                Text { Layout.fillWidth: true; text: window.selectedAlbumName; font.family: "JetBrains Mono"; font.pixelSize: window.s(18); font.weight: Font.Bold; color: window.text; wrapMode: Text.WordWrap }
                Text { Layout.fillWidth: true; text: window.selectedAlbumArtist; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); color: window.subtext0; wrapMode: Text.WordWrap; visible: text !== "" }
                Rectangle {
                    Layout.preferredWidth: window.s(120); Layout.preferredHeight: window.s(40); radius: window.s(10)
                    color: albBackMouse.containsMouse ? window.surface2 : window.surface1
                    Behavior on color { ColorAnimation { duration: 180 } }
                    Text { anchors.centerIn: parent; text: "← Back"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Medium; color: window.text }
                    MouseArea { id: albBackMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { window.currentView = "search"; saveUiState() } }
                }
                Item { Layout.fillHeight: true }
            }
            ListView {
                id: trackList
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true; spacing: window.s(4); model: musicTracks
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                delegate: Rectangle {
                    width: trackList.width; height: window.s(46); radius: window.s(8)
                    color: trkMouse.containsMouse ? window.surface1 : "transparent"
                    Behavior on color { ColorAnimation { duration: 150 } }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: window.s(14); anchors.rightMargin: window.s(14); spacing: window.s(12)
                        Text { text: String(model.track); font.family: "JetBrains Mono"; font.pixelSize: window.s(12); color: window.subtext0
                            Layout.preferredWidth: window.s(26); horizontalAlignment: Text.AlignRight }
                        Text { text: "󰐊"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(14); color: window.musicAccent; visible: trkMouse.containsMouse }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text { Layout.fillWidth: true; text: model.title; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Medium; color: window.text; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: model.artist; font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0; elide: Text.ElideRight; visible: text !== "" }
                        }
                        Text { text: window.fmtTime(model.duration); font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0 }
                    }
                    MouseArea { id: trkMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: playMusic(model.songId, model.title) }
                }
            }
        }
        // ==========================================
        // SERIES VIEW
        // ==========================================
        ColumnLayout {
            anchors.fill: parent; anchors.margins: window.s(20); spacing: window.s(12)
            visible: window.currentView === "series"
            // Top block: button stack left, title + synopsis right. The stack
            // sets the block's height, so the season row starts level with the
            // bottom of the MAL buttons and the episode list below runs the
            // FULL width of the page. fillHeight must be forced off — nested
            // layouts default it to true, which let this block eat the page.
            RowLayout {
                Layout.fillWidth: true; Layout.fillHeight: false; spacing: window.s(25)
            ColumnLayout {
                Layout.preferredWidth: window.s(220); Layout.minimumWidth: window.s(220); Layout.maximumWidth: window.s(220)
                Layout.alignment: Qt.AlignTop; spacing: window.s(12)
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(45); radius: window.s(10)
                    property bool isHovered: backMouse.containsMouse
                    color: isHovered ? window.surface2 : window.surface1
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Text { anchors.centerIn: parent; text: "← Back"; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Medium; color: window.text }
                    MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: true
                        onClicked: {
                            // Return to the page this series was opened FROM: the
                            // View All page or Library overlay if that's where we
                            // came from, otherwise the home/search view.
                            var r = window.seriesReturn
                            window.seriesReturn = null
                            window.currentView = "search"
                            if (r && r.kind === "catpage") window.openCatPage({ key: r.key, title: r.title, url: r.url })
                            else if (r && r.kind === "library") window.openLibrary()
                            else searchInput.forceActiveFocus()
                            saveUiState()
                        } }
                }
                // ── Anime: Sub / Dub source toggle (separate episode counts —
                //    the list caps at the selected mode's latest episode).
                //    Two slim half-width buttons just below Back (MAL-pill height). ──
                RowLayout {
                    Layout.fillWidth: true
                    visible: window.selectedIsAnime
                    spacing: window.s(6)
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(28); radius: window.s(8)
                        color: !window.animeDub ? window.sectionAccent : (subPillM.containsMouse ? window.surface2 : window.surface1)
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text { anchors.centerIn: parent
                               text: "Sub" + (window.animeSubEps > 0 ? " · " + window.animeSubEps : "")
                               font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                               font.weight: !window.animeDub ? Font.Bold : Font.Medium
                               color: !window.animeDub ? window.crust : window.text }
                        MouseArea { id: subPillM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: window.setAnimeDub(false) }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(28); radius: window.s(8)
                        property bool hasDub: window.animeDubEps > 0
                        color: window.animeDub ? window.sectionAccent : (dubPillM.containsMouse ? window.surface2 : window.surface1)
                        opacity: hasDub || window.animeDub ? 1 : 0.45
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text { anchors.centerIn: parent
                               text: "Dub" + (window.animeDubEps > 0 ? " · " + window.animeDubEps : "")
                               font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                               font.weight: window.animeDub ? Font.Bold : Font.Medium
                               color: window.animeDub ? window.crust : window.text }
                        MouseArea { id: dubPillM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: window.setAnimeDub(true) }
                    }
                }
                // ── MAL-style shelving straight from the series page ──
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: window.s(6)
                    Repeater {
                        model: window.malStatuses
                        delegate: Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: window.s(28); radius: window.s(8)
                            property bool cur: modelData.key === window.libStatusOf(window.selectedImdbId)
                            color: cur ? window.sectionAccent : (serStM.containsMouse ? window.surface1 : window.surface0)
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text { anchors.centerIn: parent; text: modelData.label
                                   font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                   font.weight: parent.cur ? Font.Bold : Font.Medium
                                   color: parent.cur ? window.crust : window.text }
                            MouseArea { id: serStM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: window.libSet({ imdbId: window.selectedImdbId, title: window.selectedTitle,
                                                           poster: window.selectedPoster,
                                                           type: window.selectedIsAnime ? "anime" : "tv" }, modelData.key) }
                        }
                    }
                }
            }
            // Title + long-paragraph synopsis fill the space right of the
            // buttons. The Flickable reports no implicit height, so a long
            // synopsis can't stretch the block past the button stack — it
            // scrolls within that height instead.
            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; spacing: window.s(8)
                Text {
                    Layout.fillWidth: true
                    text: window.selectedTitle
                    textFormat: Text.PlainText
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(22); font.weight: Font.Bold
                    color: window.text
                    wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                }
                Flickable {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    visible: window.selectedDescription !== ""
                    clip: true; contentHeight: seriesDescText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { contentItem: Rectangle { radius: window.s(2); color: window.surface2; implicitWidth: window.s(3) } }
                    Text {
                        id: seriesDescText
                        width: parent.width - window.s(10)
                        text: window.selectedDescription; textFormat: Text.PlainText
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                        color: window.subtext0; wrapMode: Text.WordWrap; lineHeight: 1.4
                    }
                }
                // Season tabs live at the bottom of the top block — on the
                // same horizontal band as the MAL stack to their left.
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(44)
                    ListView {
                        id: seasonList
                        anchors.fill: parent
                        orientation: ListView.Horizontal; model: seasonModel; spacing: window.s(8); clip: true
                        Behavior on contentX { NumberAnimation { duration: 350; easing.type: Easing.OutQuart } }
                        delegate: Rectangle {
                            width: seasonLabelText.width + window.s(28); height: window.s(38); radius: window.s(10)
                            property bool isActive: window.currentSeason === model.seasonNum
                            color: isActive ? window.sectionAccent : window.surface0
                            border.color: isActive ? color : window.surface1; border.width: 1
                            Behavior on color { ColorAnimation { duration: 280; easing.type: Easing.OutQuart } }
                            Behavior on border.color { ColorAnimation { duration: 280; easing.type: Easing.OutQuart } }
                            scale: isActive ? 1.04 : 1.0
                            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                            Text {
                                id: seasonLabelText
                                anchors.centerIn: parent
                                text: "S" + model.seasonNum
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: isActive ? Font.Bold : Font.Medium
                                color: isActive ? window.crust : window.text
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    if (window.currentSeason !== model.seasonNum) {
                                        window.currentSeason = model.seasonNum
                                        updateEpisodes(model.seasonNum)
                                        saveUiState()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.5) }
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        id: epList
                        anchors.fill: parent
                        model: episodeModel; spacing: window.s(6); clip: true
                        opacity: window.seasonSwitching ? 0 : 1
                        Behavior on opacity {
                            NumberAnimation {
                                duration: window.seasonSwitching ? 180 : 250
                                easing.type: window.seasonSwitching ? Easing.InQuad : Easing.OutQuad
                            }
                        }
                        transform: Translate {
                            y: window.seasonSwitching ? window.s(8) : 0
                            Behavior on y {
                                NumberAnimation {
                                    duration: window.seasonSwitching ? 180 : 280
                                    easing.type: window.seasonSwitching ? Easing.InQuad : Easing.OutQuart
                                }
                            }
                        }
                        ScrollBar.vertical: ScrollBar { active: true; contentItem: Rectangle { radius: window.s(2); color: window.surface2; implicitWidth: window.s(4) } }
                        Text {
                            anchors.centerIn: parent
                            visible: window.isLoadingSeries
                            text: "Fetching episodes..."
                            color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                        }
                        highlight: Rectangle {
                            color: window.surface0; border.color: window.surface2; border.width: 1; radius: window.s(10); z: 0
                            Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutQuart } }
                        }
                        highlightFollowsCurrentItem: true
                        highlightMoveVelocity: -1
                        delegate: Item {
                            id: epRow
                            width: ListView.view.width
                            // Expands to reveal the episode synopsis when the TITLE
                            // area is clicked (the ▶ badge is what plays).
                            property bool expanded: false
                            height: window.s(58) + (expanded && epDescT.visible ? epDescT.implicitHeight + window.s(14) : 0)
                            Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutQuart } }
                            clip: true
                            z: 1
                            property bool isCurrent: ListView.isCurrentItem
                            Rectangle {
                                anchors.fill: parent; radius: window.s(10)
                                color: epMouse.containsMouse || epPlayM.containsMouse || isCurrent ? window.surface0 : "transparent"
                                border.color: epMouse.containsMouse || epPlayM.containsMouse || isCurrent ? window.surface2 : "transparent"; border.width: 1
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                RowLayout {
                                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: window.s(10) }
                                    height: window.s(38)
                                    spacing: window.s(12)
                                    // ▶ play badge — shows the episode number, morphs to a
                                    // play glyph on hover. This is the ONLY play trigger.
                                    Rectangle {
                                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                                        radius: window.s(8)
                                        color: isCurrent || epPlayM.containsMouse ? window.blue : window.surface1
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                        Text {
                                            anchors.centerIn: parent
                                            text: epPlayM.containsMouse ? "▶" : model.epNum
                                            font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold
                                            color: isCurrent || epPlayM.containsMouse ? window.crust : window.subtext0
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                        MouseArea {
                                            id: epPlayM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                epList.currentIndex = index
                                                playSelectedEpisode(model.epNum)
                                            }
                                        }
                                    }
                                    Column {
                                        Layout.fillWidth: true; spacing: window.s(2)
                                        Text {
                                            width: parent.width
                                            text: model.epTitle + ((model.epDesc || "") !== "" ? (epRow.expanded ? "  ▴" : "  ▾") : "")
                                            font.family: "JetBrains Mono"
                                            font.pixelSize: model.hasRealTitle ? window.s(13) : window.s(12)
                                            font.weight: model.hasRealTitle ? Font.Medium : Font.Normal
                                            color: model.hasRealTitle ? window.text : window.subtext0
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                                // Synopsis dropdown (title-area click).
                                Text {
                                    id: epDescT
                                    anchors { top: parent.top; left: parent.left; right: parent.right }
                                    anchors.topMargin: window.s(52)
                                    anchors.leftMargin: window.s(58); anchors.rightMargin: window.s(12)
                                    visible: (model.epDesc || "") !== ""
                                    opacity: epRow.expanded ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                    text: model.epDesc || ""
                                    textFormat: Text.PlainText
                                    color: window.subtext0
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                    wrapMode: Text.WordWrap; lineHeight: 1.3
                                }
                                // Watch progress — how far into this episode you got.
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: window.s(10); rightMargin: window.s(10); bottomMargin: window.s(3) }
                                    height: window.s(3); radius: height / 2
                                    color: Qt.rgba(1, 1, 1, 0.10)
                                    visible: epProgFill.frac > 0
                                    Rectangle {
                                        id: epProgFill
                                        readonly property real frac: window.watchFrac(window.selectedImdbId + ":s" + window.currentSeason + "e" + model.epNum)
                                        width: parent.width * frac; height: parent.height; radius: height / 2
                                        color: window.sectionAccent
                                    }
                                }
                                // Title area: toggles the synopsis instead of playing.
                                // Sits UNDER the play badge's MouseArea (declared after it in
                                // the layout, but this area starts past the badge column).
                                MouseArea {
                                    id: epMouse
                                    anchors { top: parent.top; left: parent.left; right: parent.right }
                                    anchors.leftMargin: window.s(56)
                                    height: window.s(58)
                                    hoverEnabled: true
                                    cursorShape: (model.epDesc || "") !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: {
                                        epList.currentIndex = index
                                        if ((model.epDesc || "") !== "") epRow.expanded = !epRow.expanded
                                        else playSelectedEpisode(model.epNum)   // no synopsis → keep old behaviour
                                    }
                                }
                            }
                        }
                    }
                }
        }
        // ==========================================
        // PiP VIEW  (control surface for the mpv PiP sibling window)
        // ==========================================
        ColumnLayout {
            id: pipView
            anchors.fill: parent; anchors.margins: window.s(28); spacing: window.s(18)
            visible: window.currentView === "pip"

            readonly property string pipDir: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip"
            readonly property string videoCli: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/movies/video/video"
            function pipExec(args) { Quickshell.execDetached(["bash"].concat(args)) }

            RowLayout {
                Layout.fillWidth: true; spacing: window.s(12)
                Text {
                    text: "󰍹"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(26); color: window.mauve
                }
                ColumnLayout {
                    spacing: 0
                    Text { text: "Picture-in-Picture"; font.family: "JetBrains Mono"; font.pixelSize: window.s(20); font.weight: Font.Bold; color: window.text }
                    Text { text: "One floating mpv — YouTube · anime · streams · files"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0 }
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: window.s(90); Layout.preferredHeight: window.s(38); radius: window.s(10)
                    color: pipBackMouse.containsMouse ? window.surface2 : window.surface1
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Text { anchors.centerIn: parent; text: "← Back"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Medium; color: window.text }
                    MouseArea { id: pipBackMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { window.currentView = "search"; searchInput.forceActiveFocus(); saveUiState() } }
                }
            }

            // URL / file entry + load
            RowLayout {
                Layout.fillWidth: true; spacing: window.s(12)
                TextField {
                    id: pipUrlInput
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(46)
                    background: Rectangle {
                        color: pipUrlInput.activeFocus ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6) : window.surface0
                        radius: window.s(10); border.color: pipUrlInput.activeFocus ? window.surface2 : "transparent"
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); leftPadding: window.s(15)
                    placeholderText: "YouTube / yt-dlp link, stream, or file path…"
                    placeholderTextColor: window.subtext0; verticalAlignment: TextInput.AlignVCenter
                    onAccepted: pipOpenBtn.go()
                }
                Rectangle {
                    id: pipOpenBtn
                    Layout.preferredWidth: window.s(150); Layout.preferredHeight: window.s(46); radius: window.s(10)
                    color: pipOpenMouse.containsMouse ? window.mauve : Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.85)
                    Behavior on color { ColorAnimation { duration: 200 } }
                    function go() {
                        var u = pipUrlInput.text.trim()
                        if (u === "") return
                        // Universal router: ensures the PiP is up, loads via IPC
                        // (mpv resolves YouTube/yt-dlp links through its ytdl hook).
                        pipView.pipExec([pipView.videoCli, "load", u])
                    }
                    Text { anchors.centerIn: parent; text: "Open in PiP"; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Bold; color: window.crust }
                    MouseArea { id: pipOpenMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pipOpenBtn.go() }
                }
            }

            // Sources — launch a content browser that streams into the PiP
            RowLayout {
                Layout.fillWidth: true; spacing: window.s(12)
                Repeater {
                    model: [
                        { glyph: "󰕷", title: "Anime", sub: "ani-cli", kind: "anime" },
                        { glyph: "󰿎", title: "Movies / TV", sub: "mov-cli", kind: "movie" }
                    ]
                    delegate: Rectangle {
                        Layout.preferredWidth: window.s(160); Layout.preferredHeight: window.s(58); radius: window.s(12)
                        color: srcMouse.containsMouse ? window.surface1 : window.surface0
                        border.color: srcMouse.containsMouse ? window.mauve : "transparent"; border.width: 1
                        Behavior on color { ColorAnimation { duration: 180 } }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(16); spacing: window.s(12)
                            Text { text: modelData.glyph; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(22); color: srcMouse.containsMouse ? window.mauve : window.text }
                            ColumnLayout {
                                spacing: 0
                                Text { text: modelData.title; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Bold; color: window.text }
                                Text { text: modelData.sub; font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0 }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        MouseArea {
                            id: srcMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: pipView.pipExec([pipView.videoCli, "browse", modelData.kind])
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            // Quick controls
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: window.s(12); rowSpacing: window.s(12)
                Repeater {
                    model: [
                        { glyph: "", label: "Play / Pause", cmd: ["pip_load.sh"], special: "playpause" },
                        { glyph: "󰈸", label: "Click-through", cmd: ["pip_passthrough.sh"], special: "" },
                        { glyph: "󰖳", label: "Show / Hide", cmd: ["pip_toggle.sh", "toggle"], special: "" },
                        { glyph: "", label: "Close", cmd: ["pip_toggle.sh", "close"], special: "" }
                    ]
                    delegate: Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(56); radius: window.s(12)
                        color: ctlMouse.containsMouse ? window.surface1 : window.surface0
                        Behavior on color { ColorAnimation { duration: 180 } }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(18); spacing: window.s(14)
                            Text { text: modelData.glyph; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(20); color: ctlMouse.containsMouse ? window.mauve : window.text }
                            Text { text: modelData.label; font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Medium; color: window.text }
                            Item { Layout.fillWidth: true }
                        }
                        MouseArea {
                            id: ctlMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var dir = Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/"
                                if (modelData.special === "playpause") {
                                    // toggle pause over IPC (no-op if the player isn't running)
                                    Quickshell.execDetached(["bash", window.videoCli, "ipc", "{\"command\":[\"cycle\",\"pause\"]}"])
                                    return
                                }
                                var c = ["bash", dir + modelData.cmd[0]]
                                for (var i = 1; i < modelData.cmd.length; i++) c.push(modelData.cmd[i])
                                Quickshell.execDetached(c)
                            }
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            Text {
                Layout.fillWidth: true
                text: "Everything streams into one floating mpv. Paste a YouTube/yt-dlp link or file above; Anime (ani-cli) and Movies/TV (mov-cli) open in a terminal; the Movies/TV grid plays the selected title/episode straight in here. SUPER+SHIFT+P toggles click-through.\nNeeds: yt-dlp (sudo pacman -S yt-dlp), ani-cli (paru -S ani-cli), mov-cli + a scraper plugin (see the mov-cli wiki)."
                font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0
                wrapMode: Text.WordWrap; lineHeight: 1.4
            }
        }
        // ==========================================
        // EMBEDDED PLAYER VIEW  (in-widget mpv via PipMpv/MpvItem)
        // ==========================================
        Item {
            id: playerView
            anchors.fill: parent
            z: 50
            property real popHint: 0   // px dragged down on the top bar (drag-to-PiP)
            // YouTube-style page scroll: wheel-down slides the whole video UP,
            // revealing title/description/up-next below — all ONE continuous
            // page (no inner scrollbars): more scrolling keeps sliding video +
            // content together, up to the full content height.
            property real ytPageOff: 0
            readonly property real ytPageMax: Math.max(0, ytBelowCol.implicitHeight + window.s(40))
            readonly property real ytPageStep: window.s(160)
            function ytPageScroll(dir) {
                var v = ytPageOff + dir * ytPageStep
                ytPageOff = Math.max(0, Math.min(ytPageMax, v))
            }
            Behavior on ytPageOff { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
            onVisibleChanged: if (!visible) ytPageOff = 0
            Connections {
                target: window
                // New video (up-next click / autoplay) → scroll back up, YouTube-style.
                function onCurrentYtIdChanged() { playerView.ytPageOff = 0 }
            }
            // MpvItem stays instantiated so its IPC socket (the one ani-cli /
            // mov-cli / pip_mpv.sh target) is live whenever the widget is loaded;
            // we just reveal it for the player view.
            visible: window.currentView === "player"

            Rectangle { anchors.fill: parent; color: "black" }
            // The video surface slides up by ytPageOff (size unchanged — only the
            // margins shift it), revealing the below-video panel.
            MpvItem { id: embeddedMpv; anchors.fill: parent
                      anchors.topMargin: -playerView.ytPageOff; anchors.bottomMargin: playerView.ytPageOff }

            // Music has no video: show the album art centred behind the chrome.
            Image {
                visible: window.playerKind === "music" && window.selectedAlbumCover !== ""
                source: window.playerKind === "music" ? window.selectedAlbumCover : ""
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -playerView.ytPageOff
                width: Math.min(parent.width, parent.height) * 0.62
                height: width
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 640; sourceSize.height: 640
                asynchronous: true; smooth: true; cache: true
            }

            // Status overlay while there's no media yet (finding source / failed).
            ColumnLayout {
                anchors.centerIn: parent; width: parent.width * 0.7; spacing: window.s(10); z: 4
                anchors.verticalCenterOffset: -playerView.ytPageOff
                visible: window.playerStatus !== ""
                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: visible && window.playerStatus === "Finding source…"
                    visible: window.playerStatus === "Finding source…"
                    implicitWidth: window.s(40); implicitHeight: window.s(40)
                }
                Text {
                    Layout.fillWidth: true
                    text: window.playerStatus
                    color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(14)
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; lineHeight: 1.3
                }
            }

            // Chrome auto-hides after a few seconds of no input. Any pointer movement
            // (tracked passively by the HoverHandler so it works over the buttons too)
            // or a click reveals it and restarts the idle countdown.
            HoverHandler { id: chromeHover }
            property bool chromeActive: true
            property point chromePos: chromeHover.point.position
            onChromePosChanged: { playerView.chromeActive = true; chromeIdleTimer.restart() }
            Timer { id: chromeIdleTimer; interval: 3000; onTriggered: playerView.chromeActive = false }
            Connections {
                target: window
                function onCurrentViewChanged() {
                    if (window.currentView === "player") { playerView.chromeActive = true; chromeIdleTimer.restart() }
                }
            }
            // Chrome stays hidden while the page is scrolled down (video slid up).
            readonly property bool chromeShown: (playerView.chromeActive || playerView.popHint > 0) && playerView.ytPageOff < 1

            // Click on the bare video toggles play/pause (and wakes the chrome).
            MouseArea {
                id: playerHover
                // Tracks the VIDEO surface (slides up with it), so play/pause
                // clicks only land on the video itself — never the revealed
                // page area below it.
                anchors.fill: parent
                anchors.topMargin: -playerView.ytPageOff; anchors.bottomMargin: playerView.ytPageOff
                onClicked: { playerView.chromeActive = true; chromeIdleTimer.restart(); embeddedMpv.command(["cycle", "pause"]) }
                // YouTube: scroll down slides the WHOLE video up and reveals the
                // description + up-next section below (fullscreen-YouTube style);
                // scroll up slides it back. TV/anime keep the up-next side panel.
                // Panels sit above this, so they keep their own scroll.
                onWheel: (w) => {
                    if (window.playerKind === "music") return
                    if (playerView.ytPageOff === 0 && w.angleDelta.y < 0) buildUpNext()
                    playerView.ytPageScroll(w.angleDelta.y < 0 ? 1 : -1)
                }
            }

            // YouTube-mobile look: dim the video while the controls are up.
            Rectangle {
                anchors.fill: parent; z: 1
                anchors.topMargin: -playerView.ytPageOff; anchors.bottomMargin: playerView.ytPageOff
                color: Qt.rgba(0, 0, 0, 0.38)
                opacity: playerView.chromeShown ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            // Centre transport: −10s · play/pause · +10s. The play/pause sits in
            // the middle, the seek buttons sit halfway out toward the edges. The
            // area excludes the (always-open) comments panel on the right.
            Item {
                id: centerControls
                z: 4
                // Full-width: the transport stays PUT when the AI/comments panels
                // open (no re-centering shuffle). The seek button that would sit
                // under an open panel hides instead (see the visibles below).
                anchors { top: parent.top; bottom: parent.bottom; left: parent.left; right: parent.right
                          topMargin: -playerView.ytPageOff; bottomMargin: playerView.ytPageOff }
                opacity: playerView.chromeShown ? 1 : 0
                visible: opacity > 0 && window.playerStatus === ""
                Behavior on opacity { NumberAnimation { duration: 180 } }

                // −10s — a quarter of the way across (halfway to the left edge).
                // Hidden only when the OPEN AI panel actually overlaps it.
                Rectangle {
                    visible: !(window.aiOpen && (parent.width * 0.25 - width / 2) < aiPanel.width + window.s(8))
                    width: window.s(65); height: window.s(65); radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * 0.25 - width / 2
                    color: bkM.containsMouse ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(0, 0, 0, 0.45)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text { anchors.centerIn: parent; text: "󰴪"; font.family: "Iosevka Nerd Font"; color: "white"; font.pixelSize: window.s(28) }
                    MouseArea { id: bkM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: embeddedMpv.command(["seek", "-10"]) }
                }
                // play / pause — centre, 20% larger.
                Rectangle {
                    width: window.s(86); height: window.s(86); radius: width / 2
                    anchors.centerIn: parent
                    color: ppM.containsMouse ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(0, 0, 0, 0.45)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text { anchors.centerIn: parent; text: window.playerPaused ? "󰐊" : "󰏤"; font.family: "Iosevka Nerd Font"; color: "white"; font.pixelSize: window.s(40) }
                    MouseArea { id: ppM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: embeddedMpv.command(["cycle", "pause"]) }
                }
                // +10s — three quarters across (halfway to the right edge).
                // Hidden only when the OPEN comments panel actually overlaps it.
                Rectangle {
                    visible: !(window.commentsOpen && (parent.width * 0.75 + width / 2) > parent.width - commentsPanel.width - window.s(8))
                    width: window.s(65); height: window.s(65); radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * 0.75 - width / 2
                    color: fwM.containsMouse ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(0, 0, 0, 0.45)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text { anchors.centerIn: parent; text: "󰵱"; font.family: "Iosevka Nerd Font"; color: "white"; font.pixelSize: window.s(28) }
                    MouseArea { id: fwM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: embeddedMpv.command(["seek", "10"]) }
                }
            }

            // ── BELOW-VIDEO PAGE (YouTube page-scroll): title · channel · date,
            //    the FULL description, and home-style up-next cards — one
            //    continuous column that slides with the video (no inner
            //    scrollbars; wheel anywhere keeps scrolling the whole page).
            Rectangle {
                id: ytBelowPanel
                anchors.left: parent.left; anchors.right: parent.right
                height: ytBelowCol.implicitHeight + window.s(40)
                y: parent.height - playerView.ytPageOff
                visible: y < parent.height - 1
                z: 5
                color: window.base
                // YouTube videos describe themselves; movies/TV/anime use the
                // title's synopsis (movies fetch it via fetchMovieMeta on play).
                readonly property string pageDesc: window.playerKind === "youtube"
                    ? window.currentVideoDescription : window.selectedDescription
                // TV/anime playback: the page also carries the series page
                // (season tabs + episode list) below the Up Next cards.
                readonly property bool seriesKind: window.playerKind === "tv" || window.playerKind === "anime"
                MouseArea {
                    anchors.fill: parent
                    // Consume clicks too (a bare Rectangle lets them fall through
                    // to the video's play/pause area) + scroll the page on wheel.
                    onClicked: {}
                    onWheel: (w) => playerView.ytPageScroll(w.angleDelta.y < 0 ? 1 : -1)
                }
                ColumnLayout {
                    id: ytBelowCol
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: window.s(18) }
                    spacing: window.s(10)
                    Text {
                        Layout.fillWidth: true
                        text: window.selectedTitle
                        textFormat: Text.PlainText; color: window.text
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(16); font.weight: Font.Bold
                        wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: window.currentVideoChannel !== "" || window.currentVideoDate !== ""
                        text: window.currentVideoChannel
                              + (window.currentVideoDate !== "" ? "   ·  " + window.currentVideoDate : "")
                        color: ytBpChM.containsMouse ? window.red : window.sectionAccent
                        Behavior on color { ColorAnimation { duration: 150 } }
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                        elide: Text.ElideRight
                        MouseArea {
                            id: ytBpChM; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; enabled: window.currentVideoChannelId !== ""
                            onClicked: {
                                var cid = window.currentVideoChannelId, cname = window.currentVideoChannel
                                window.closePlayer()
                                openYoutubeChannel(cid, cname)
                            }
                        }
                    }
                    // Description — part of the page, scrolls with the video.
                    // YouTube videos use the video's description; movies/TV/anime
                    // use the title's synopsis. Collapsed = exactly 3 lines with a
                    // plain "more" expander; expanded swaps to a selectable text.
                    Text {
                        id: ytBpDescText
                        property bool expanded: false
                        Layout.fillWidth: true
                        visible: ytBelowPanel.pageDesc !== "" && !expanded
                        text: ytBelowPanel.pageDesc; textFormat: Text.PlainText
                        color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                        wrapMode: Text.WordWrap; lineHeight: 1.3
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        onTextChanged: expanded = false   // collapse for each new video/title
                    }
                    TextEdit {
                        // Expanded description: real TextEdit so the text is selectable.
                        Layout.fillWidth: true
                        visible: ytBelowPanel.pageDesc !== "" && ytBpDescText.expanded
                        text: ytBelowPanel.pageDesc; textFormat: TextEdit.PlainText
                        readOnly: true; selectByMouse: true
                        color: window.subtext0; selectionColor: window.sectionAccent; selectedTextColor: window.crust
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                        wrapMode: TextEdit.WordWrap
                    }
                    Text {
                        visible: ytBelowPanel.pageDesc !== "" && (ytBpDescText.truncated || ytBpDescText.expanded)
                        text: ytBpDescText.expanded ? "less" : "more"
                        color: ytBpMoreM.containsMouse ? window.text : window.subtext0
                        Behavior on color { ColorAnimation { duration: 120 } }
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                        MouseArea { id: ytBpMoreM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: ytBpDescText.expanded = !ytBpDescText.expanded }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6); visible: upNextModel.count > 0 }
                    Text {
                        text: "Up Next"
                        visible: upNextModel.count > 0
                        color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold
                    }
                    // Home-style cards: big 16:9 thumbnails, duration chip,
                    // title + channel · date — rows of 3. (Grid, not Flow: Flow
                    // reports no implicitHeight inside a ColumnLayout, which
                    // collapsed the page's scroll range.)
                    Grid {
                        Layout.fillWidth: true
                        columns: 3
                        columnSpacing: window.s(12); rowSpacing: window.s(12)
                        visible: upNextModel.count > 0
                        Repeater {
                            model: upNextModel
                            delegate: Column {
                                readonly property real cardW: Math.floor((ytBelowCol.width - window.s(24)) / 3)
                                width: cardW
                                spacing: window.s(5)
                                Rectangle {
                                    width: parent.width; height: Math.floor(width * 9 / 16); radius: window.s(8); color: window.crust; clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: (model.thumb && model.thumb !== "") ? model.thumb
                                            : (model.vid ? ("https://i.ytimg.com/vi/" + model.vid + "/hqdefault.jpg") : "")
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: window.s(400); sourceSize.height: window.s(225)
                                        asynchronous: true; smooth: true; cache: true
                                    }
                                    Rectangle {
                                        visible: (model.dur || "") !== ""
                                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: window.s(5)
                                        radius: window.s(4); color: Qt.rgba(0, 0, 0, 0.8)
                                        width: ytBpDur.width + window.s(10); height: ytBpDur.height + window.s(4)
                                        Text { id: ytBpDur; anchors.centerIn: parent; text: ytDurationLabel(model.dur)
                                               color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(10) }
                                    }
                                    Rectangle {
                                        anchors.fill: parent; radius: window.s(8); color: window.red
                                        opacity: ytBpNextM.containsMouse ? 0.2 : 0
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                    }
                                    MouseArea { id: ytBpNextM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: upNextPlay(model.kind, model.epNum, model.vid, model.title, model.channelId, model.channel, model.imdbId, model.poster) }
                                }
                                Text { width: parent.width; text: model.title; textFormat: Text.PlainText
                                       color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold
                                       wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; lineHeight: 1.1 }
                                Text { width: parent.width
                                       visible: (model.sub || "") !== "" || (model.dateStr || "") !== ""
                                       text: (model.sub || "") + ((model.dateStr || "") !== "" ? "  ·  " + model.dateStr : "")
                                       textFormat: Text.PlainText
                                       color: upNxtChM.containsMouse && (model.channelId || "") !== "" ? window.red : window.surface2
                                       Behavior on color { ColorAnimation { duration: 120 } }
                                       font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                       elide: Text.ElideRight
                                       // channel name → that channel's uploads (YouTube kind only)
                                       MouseArea { id: upNxtChM; anchors.fill: parent; hoverEnabled: true
                                           enabled: (model.channelId || "") !== ""
                                           cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                           onClicked: {
                                               var cid = model.channelId, cname = model.channel
                                               window.closePlayer()
                                               openYoutubeChannel(cid, cname)
                                           } } }
                            }
                        }
                    }
                    // ── Series page in the player (tv/anime): season tabs +
                    //    the episode list, so the whole series is browsable
                    //    without leaving playback. Episodes are virtualized
                    //    (One Piece is 1000+ rows) — the list scrolls itself
                    //    inside a capped height.
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 1
                        color: Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                        visible: ytBelowPanel.seriesKind && episodeModel.count > 0
                    }
                    Text {
                        visible: ytBelowPanel.seriesKind && episodeModel.count > 0
                        text: "Episodes"
                        color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold
                    }
                    Item {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(38)
                        visible: ytBelowPanel.seriesKind && seasonModel.count > 1
                        ListView {
                            anchors.fill: parent
                            orientation: ListView.Horizontal; model: seasonModel; spacing: window.s(8); clip: true
                            delegate: Rectangle {
                                width: bpSeasonT.width + window.s(26); height: window.s(34); radius: window.s(9)
                                property bool isActive: window.currentSeason === model.seasonNum
                                color: isActive ? window.sectionAccent : window.surface0
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Text { id: bpSeasonT; anchors.centerIn: parent; text: "S" + model.seasonNum
                                       font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                       font.weight: parent.isActive ? Font.Bold : Font.Medium
                                       color: parent.isActive ? window.crust : window.text }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (window.currentSeason !== model.seasonNum) {
                                        window.currentSeason = model.seasonNum
                                        updateEpisodes(model.seasonNum)
                                        saveUiState()
                                    } }
                            }
                        }
                    }
                    ListView {
                        id: bpEpList
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(window.s(430), count * (window.s(44) + spacing))
                        visible: ytBelowPanel.seriesKind && episodeModel.count > 0
                        model: episodeModel; spacing: window.s(5); clip: true
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: window.s(8)
                            contentItem: Rectangle { implicitWidth: window.s(6); radius: width / 2; color: window.surface2 } }
                        delegate: Rectangle {
                            width: bpEpList.width - window.s(12); height: window.s(44); radius: window.s(9)
                            property bool isCurrent: window.playerEpisode === model.epNum
                                                     && (!window.playerSeason || window.playerSeason === window.currentSeason)
                            color: isCurrent ? Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.22)
                                 : (bpEpM.containsMouse ? window.surface1 : window.surface0)
                            Behavior on color { ColorAnimation { duration: 150 } }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(12)
                                spacing: window.s(12)
                                Text { text: model.epNum; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                       font.weight: Font.Bold; color: parent.parent.isCurrent ? window.sectionAccent : window.subtext0 }
                                Text { Layout.fillWidth: true; text: model.epTitle; textFormat: Text.PlainText
                                       font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                       font.weight: model.hasRealTitle ? Font.Medium : Font.Normal
                                       color: model.hasRealTitle ? window.text : window.subtext0; elide: Text.ElideRight }
                            }
                            // Watch progress along the row's bottom edge.
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                          leftMargin: window.s(10); rightMargin: window.s(10); bottomMargin: window.s(3) }
                                height: window.s(3); radius: height / 2
                                color: Qt.rgba(1, 1, 1, 0.10)
                                visible: bpEpProg.frac > 0
                                Rectangle {
                                    id: bpEpProg
                                    readonly property real frac: window.watchFrac(window.selectedImdbId + ":s" + window.currentSeason + "e" + model.epNum)
                                    width: parent.width * frac; height: parent.height; radius: height / 2
                                    color: window.sectionAccent
                                }
                            }
                            MouseArea { id: bpEpM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: playSelectedEpisode(model.epNum) }
                        }
                    }
                }
            }

            // top bar: back + title + comments toggle.  The bar doubles as a
            // drag handle: drag it down to pop the video out into a floating PiP.
            Rectangle {
                id: topBar
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: window.s(66); z: 2
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.7) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: playerView.chromeShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // Drag-to-PiP handle (sits under the buttons, which are higher z).
                MouseArea {
                    id: topDrag
                    anchors.fill: parent
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real startY: 0
                    onPressed: (m) => { startY = m.y; playerView.popHint = 0 }
                    onPositionChanged: (m) => { if (pressed) playerView.popHint = Math.max(0, m.y - startY) }
                    onReleased: { if (playerView.popHint > window.s(64)) window.popOutToPip(); playerView.popHint = 0 }
                    onCanceled: playerView.popHint = 0
                }
            }
            RowLayout {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: window.s(14) }
                spacing: window.s(12); z: 3
                opacity: playerView.chromeShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                Rectangle {
                    Layout.preferredWidth: window.s(40); Layout.preferredHeight: window.s(36); radius: window.s(10)
                    color: playerBackMouse.containsMouse ? window.surface2 : Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.85)
                    Text { anchors.centerIn: parent; text: "←"; font.family: "JetBrains Mono"; font.pixelSize: window.s(17); font.weight: Font.Medium; color: window.text }
                    MouseArea { id: playerBackMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.closePlayer() }
                }
                Text {
                    Layout.fillWidth: true; text: window.selectedTitle; textFormat: Text.PlainText
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold; color: "white"
                    elide: Text.ElideRight
                }
                // Toolbar: just Fullscreen now. (Settings moved to the bottom seek bar;
                // Share into Settings; Comments/AI/Up-next to the right-edge side tabs.)
                // Fullscreen toggle.
                Rectangle {
                    Layout.preferredWidth: window.s(40); Layout.preferredHeight: window.s(36); radius: window.s(10)
                    color: fsMouse.containsMouse ? window.surface2 : Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.85)
                    Text { anchors.centerIn: parent; text: window.playerFullscreen ? "󰊔" : "󰊓"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(17); color: window.text }
                    MouseArea { id: fsMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.playerFullscreen = !window.playerFullscreen }
                }
            }

            // Settings menu — subtitles / speed / resolution.
            Rectangle {
                id: settingsMenu
                z: 9
                // Fades out with the rest of the chrome on the inactivity
                // timer (and returns with it while still "open").
                opacity: window.playerSettingsOpen && playerView.chromeShown ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                // Rides up with the video when the page scrolls into up-next.
                anchors { bottom: parent.bottom; bottomMargin: window.s(74) + playerView.ytPageOff
                          right: parent.right; rightMargin: window.s(14) }
                width: window.s(286)
                height: settingsCol.implicitHeight + window.s(24)
                radius: window.s(12)
                color: Qt.rgba(0, 0, 0, 0.85)
                border.color: Qt.rgba(1, 1, 1, 0.10); border.width: 1
                // Swallow clicks on the menu background so they never fall
                // through to the video's play/pause area underneath.
                MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
                ColumnLayout {
                    id: settingsCol
                    anchors.fill: parent; anchors.margins: window.s(12); spacing: window.s(12)
                    // Volume
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: window.s(6)
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; text: "Volume"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                            Text { text: Math.round(window.playerVolume) + "%"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                        }
                        Slider {
                            id: volSlider
                            Layout.fillWidth: true
                            // Custom background/handle Rectangles provide no
                            // implicitHeight, so without this the Slider's INPUT
                            // area laid out 0px tall — visuals painted but drags
                            // never registered ("the slider doesn't move").
                            Layout.preferredHeight: window.s(22)
                            from: 0; to: 130; value: window.playerVolume
                            onMoved: window.setVolume(value)
                            background: Rectangle {
                                x: volSlider.leftPadding; y: volSlider.topPadding + volSlider.availableHeight / 2 - height / 2
                                width: volSlider.availableWidth; height: window.s(4); radius: height / 2; color: window.surface1
                                Rectangle { width: volSlider.visualPosition * parent.width; height: parent.height; radius: height / 2; color: window.sectionAccent }
                            }
                            handle: Rectangle {
                                x: volSlider.leftPadding + volSlider.visualPosition * (volSlider.availableWidth - width)
                                y: volSlider.topPadding + volSlider.availableHeight / 2 - height / 2
                                width: window.s(15); height: window.s(15); radius: width / 2
                                color: window.sectionAccent; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.25)
                            }
                        }
                    }
                    // Subtitles: label · current-language dropdown · On/Off
                    RowLayout {
                        Layout.fillWidth: true; spacing: window.s(8)
                        Text { Layout.fillWidth: true; text: "Subtitles"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                        Rectangle {
                            id: subLangBtn
                            Layout.preferredWidth: subLangBtnT.width + window.s(24); Layout.preferredHeight: window.s(26); radius: window.s(13)
                            color: (subLangBtnM.containsMouse || subLangPopup.visible) ? window.surface2 : window.surface1
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text { id: subLangBtnT; anchors.centerIn: parent
                                   text: window.subLangLabel() + "  ▾"
                                   color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            MouseArea { id: subLangBtnM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: subLangPopup.visible ? subLangPopup.close() : subLangPopup.open() }
                            // Language dropdown, anchored to the button.
                            Popup {
                                id: subLangPopup
                                parent: subLangBtn
                                x: parent.width - width
                                y: parent.height + window.s(6)
                                width: window.s(160)
                                padding: window.s(6)
                                background: Rectangle {
                                    radius: window.s(10); color: Qt.rgba(0, 0, 0, 0.92)
                                    border.color: Qt.rgba(1, 1, 1, 0.12); border.width: 1
                                }
                                contentItem: Column {
                                    spacing: window.s(3)
                                    Repeater {
                                        model: window.subLangChoices
                                        delegate: Rectangle {
                                            width: window.s(160) - window.s(12); height: window.s(28); radius: window.s(7)
                                            property bool sel: window.subLang === modelData.key
                                            color: sel ? window.sectionAccent : (slItemM.containsMouse ? window.surface2 : "transparent")
                                            Behavior on color { ColorAnimation { duration: 100 } }
                                            Text { anchors.left: parent.left; anchors.leftMargin: window.s(10); anchors.verticalCenter: parent.verticalCenter
                                                   text: modelData.label
                                                   color: parent.sel ? window.crust : window.text
                                                   font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                                   font.weight: parent.sel ? Font.Bold : Font.Medium }
                                            MouseArea { id: slItemM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { window.setSubLang(modelData.key); subLangPopup.close() } }
                                        }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            Layout.preferredWidth: window.s(56); Layout.preferredHeight: window.s(26); radius: window.s(13)
                            color: window.subsOn ? window.sectionAccent : window.surface1
                            Text { anchors.centerIn: parent; text: window.subsOn ? "On" : "Off"; color: window.subsOn ? window.crust : window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: window.toggleSubs() }
                        }
                    }
                    // Auto AI summary
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: "Auto AI summary"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                        Rectangle {
                            Layout.preferredWidth: window.s(56); Layout.preferredHeight: window.s(26); radius: window.s(13)
                            color: window.autoAiParse ? window.sectionAccent : window.surface1
                            Text { anchors.centerIn: parent; text: window.autoAiParse ? "On" : "Off"; color: window.autoAiParse ? window.crust : window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: window.setAutoAi(!window.autoAiParse) }
                        }
                    }
                    // Auto skip (SponsorBlock segments — sponsors/intros/outros)
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: "Auto skip segments"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                        Rectangle {
                            Layout.preferredWidth: window.s(56); Layout.preferredHeight: window.s(26); radius: window.s(13)
                            color: window.autoSkip ? window.sectionAccent : window.surface1
                            Text { anchors.centerIn: parent; text: window.autoSkip ? "On" : "Off"; color: window.autoSkip ? window.crust : window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: window.setAutoSkip(!window.autoSkip) }
                        }
                    }
                    // Speed — continuous slider, 0.5x … 3x.
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: window.s(6)
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; text: "Speed"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                            Text { text: window.playerSpeed.toFixed(2) + "x"; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                        }
                        Slider {
                            id: spdSlider
                            Layout.fillWidth: true
                            Layout.preferredHeight: window.s(22)   // custom visuals ⇒ explicit input height
                            from: 0.5; to: 3.0; stepSize: 0.05
                            value: window.playerSpeed
                            onMoved: window.setSpeed(Math.round(value * 20) / 20)
                            background: Rectangle {
                                x: spdSlider.leftPadding; y: spdSlider.topPadding + spdSlider.availableHeight / 2 - height / 2
                                width: spdSlider.availableWidth; height: window.s(4); radius: height / 2; color: window.surface1
                                Rectangle { width: spdSlider.visualPosition * parent.width; height: parent.height; radius: height / 2; color: window.sectionAccent }
                                // 1x notch for easy reset orientation
                                Rectangle { x: parent.width * (0.5 / 2.5) - width / 2; y: -window.s(2); width: window.s(2); height: window.s(8); color: Qt.rgba(1, 1, 1, 0.45) }
                            }
                            handle: Rectangle {
                                x: spdSlider.leftPadding + spdSlider.visualPosition * (spdSlider.availableWidth - width)
                                y: spdSlider.topPadding + spdSlider.availableHeight / 2 - height / 2
                                width: window.s(15); height: window.s(15); radius: width / 2
                                color: window.sectionAccent; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.25)
                            }
                        }
                    }
                    // Resolution (YouTube only) — one row: Auto · 1440p · 1080p · 480p.
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: window.s(6)
                        Text { text: window.playerKind === "youtube" ? "Resolution" : "Resolution — YouTube only"; color: window.playerKind === "youtube" ? "white" : window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                        RowLayout {
                            Layout.fillWidth: true; spacing: window.s(6)
                            enabled: window.playerKind === "youtube"; opacity: enabled ? 1 : 0.4
                            Repeater {
                                model: [ { l: "Auto", h: 0 }, { l: "1440p", h: 1440 }, { l: "1080p", h: 1080 }, { l: "480p", h: 480 } ]
                                delegate: Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: window.s(28); radius: window.s(8)
                                    property bool sel: window.playerRes === modelData.l
                                    color: sel ? window.sectionAccent : (resMouse.containsMouse ? window.surface2 : window.surface1)
                                    Text { anchors.centerIn: parent; text: modelData.l; color: parent.sel ? window.crust : window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: parent.sel ? Font.Bold : Font.Medium }
                                    MouseArea { id: resMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.setResolution(modelData.l, modelData.h) }
                                }
                            }
                        }
                    }
                    // Share
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: "Share"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                        Rectangle {
                            Layout.preferredWidth: window.s(96); Layout.preferredHeight: window.s(28); radius: window.s(8)
                            color: shareBtnMouse.containsMouse ? window.sectionAccent : window.surface1
                            Text { anchors.centerIn: parent; text: "󰒖  Copy link"; color: shareBtnMouse.containsMouse ? window.crust : window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            MouseArea { id: shareBtnMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.sharePlayer() }
                        }
                    }
                }
            }

            // Drag-to-PiP hint (grows as you pull the top bar down).
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: window.s(72)
                width: popHintText.implicitWidth + window.s(28); height: window.s(40); radius: window.s(20); z: 6
                color: Qt.rgba(0, 0, 0, 0.78)
                visible: playerView.popHint > 0
                opacity: Math.min(1, playerView.popHint / window.s(64))
                scale: 0.9 + 0.1 * Math.min(1, playerView.popHint / window.s(64))
                Text {
                    id: popHintText
                    anchors.centerIn: parent
                    text: playerView.popHint > window.s(64) ? "󰏝  Release to pop out" : "󰏝  Pull down to pop out"
                    color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Medium
                }
            }

            // ===== bottom control bar: seek bar =====
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: window.s(64); z: 2
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.78) }
                }
                opacity: playerView.chromeShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            // "Skip" — SponsorBlock segment skip (when auto-skip is off, or when
            // sitting in a segment you scrubbed back into), and a Crunchyroll-style
            // "+85s Skip intro" for TV/anime during the opening minutes.
            Rectangle {
                id: skipBtn
                z: 6
                readonly property bool ytMode: window.sbCurrent !== null && (!window.autoSkip || window.sbCurrent.skipped)
                readonly property bool epMode: (window.playerKind === "tv" || window.playerKind === "anime")
                                               && window.playerDur > 300 && window.playerPos > 3 && window.playerPos < 240
                visible: window.currentView === "player" && window.playerStatus === "" && (ytMode || epMode)
                anchors {
                    right: parent.right; bottom: parent.bottom
                    rightMargin: (window.commentsOpen ? commentsPanel.width : (window.aiOpen ? aiPanel.width : 0)) + window.s(18)
                    bottomMargin: window.s(142) + playerView.ytPageOff
                }
                width: skipRow.implicitWidth + window.s(28); height: window.s(42); radius: window.s(12)
                color: skipMouse.containsMouse ? window.sectionAccent : Qt.rgba(0, 0, 0, 0.74)
                border.width: 1; border.color: window.sectionAccent
                Behavior on color { ColorAnimation { duration: 150 } }
                RowLayout {
                    id: skipRow
                    anchors.centerIn: parent; spacing: window.s(8)
                    Text {
                        text: skipBtn.ytMode
                            ? ("Skip " + ({ sponsor: "sponsor", selfpromo: "self-promo", interaction: "reminder",
                                            intro: "intro", outro: "outro", preview: "preview" }[window.sbCurrent.cat] || "segment"))
                            : "Skip intro"
                        color: skipMouse.containsMouse ? window.crust : "white"
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold
                    }
                    Text { text: "󰒭"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(16)
                        color: skipMouse.containsMouse ? window.crust : window.sectionAccent }
                }
                MouseArea {
                    id: skipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (skipBtn.ytMode) {
                            var sg = window.sbCurrent
                            sg.skipped = true; window.sbSegmentsChanged()
                            embeddedMpv.command(["seek", String(sg.end), "absolute"])
                            window.playerPos = sg.end; window.playerPrevPos = sg.end
                        } else {
                            embeddedMpv.command(["seek", "85"])   // classic OP length
                        }
                    }
                }
            }

            // "Up next" — appears near the end (credits/outro) to jump to the next one.
            // Shown regardless of chrome so it's there even when the controls fade out.
            Rectangle {
                id: upNextBtn
                z: 6
                visible: window.currentView === "player" && window.playerNearEnd && playerHasNext()
                anchors {
                    right: parent.right; bottom: parent.bottom
                    rightMargin: (window.commentsOpen ? commentsPanel.width : (window.aiOpen ? aiPanel.width : 0)) + window.s(18)
                    bottomMargin: window.s(88)
                }
                width: upNextRow.implicitWidth + window.s(30); height: window.s(46); radius: window.s(12)
                color: upNextMouse.containsMouse ? window.sectionAccent : Qt.rgba(0, 0, 0, 0.74)
                border.width: 1; border.color: window.sectionAccent
                Behavior on color { ColorAnimation { duration: 150 } }
                RowLayout {
                    id: upNextRow
                    anchors.centerIn: parent; spacing: window.s(8)
                    Text { text: playerNextLabel(); color: upNextMouse.containsMouse ? window.crust : "white"
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold }
                    Text { text: "󰒭"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(18)
                        color: upNextMouse.containsMouse ? window.crust : window.sectionAccent }
                }
                MouseArea { id: upNextMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: playerPlayNext() }
            }
            ColumnLayout {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: window.s(14)
                          // Ride up with the video when the page scrolls into
                          // up-next, so the seek segments stay glued to it.
                          bottomMargin: window.s(14) + playerView.ytPageOff }
                spacing: window.s(8); z: 3
                opacity: playerView.chromeShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // Seek / scrub bar.
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(10)
                    Text {
                        text: window.fmtTime(window.playerPos)
                        color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                        Layout.preferredWidth: window.s(46); horizontalAlignment: Text.AlignRight
                    }
                    Item {
                        id: seekBar
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(16)
                        property real frac: window.playerDur > 0 ? Math.max(0, Math.min(1, window.playerPos / window.playerDur)) : 0
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: window.s(5); radius: height / 2
                            color: Qt.rgba(1, 1, 1, 0.22)
                            Rectangle {
                                width: parent.width * seekBar.frac; height: parent.height; radius: height / 2
                                color: window.sectionAccent
                            }
                            // SponsorBlock segment markings: intro/outro in mauve,
                            // sponsor/self-promo/etc in yellow.
                            Repeater {
                                model: window.sbSegments
                                delegate: Rectangle {
                                    visible: window.playerDur > 0
                                    x: parent.width * (modelData.start / Math.max(1, window.playerDur))
                                    width: Math.max(window.s(2), parent.width * ((modelData.end - modelData.start) / Math.max(1, window.playerDur)))
                                    height: parent.height; radius: height / 2
                                    color: (modelData.cat === "intro" || modelData.cat === "outro")
                                        ? Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.95)
                                        : Qt.rgba(0.976, 0.886, 0.686, 0.95)
                                }
                            }
                        }
                        Rectangle {
                            width: window.s(13); height: window.s(13); radius: width / 2; color: "white"
                            anchors.verticalCenter: parent.verticalCenter
                            x: (parent.width - width) * seekBar.frac
                            visible: window.playerDur > 0
                            scale: seekMouse.containsMouse || window.seekDragging ? 1.2 : 1
                            Behavior on scale { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            id: seekMouse
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => {
                                window.sbPosBeforeDrag = window.playerPos   // scrub direction reference
                                window.seekDragging = true
                                window.playerPos = Math.max(0, Math.min(1, m.x / width)) * window.playerDur
                            }
                            onPositionChanged: (m) => { if (window.seekDragging) window.playerPos = Math.max(0, Math.min(1, m.x / width)) * window.playerDur }
                            onReleased: (m) => {
                                var frac = Math.max(0, Math.min(1, m.x / width))
                                var target = frac * window.playerDur
                                if (window.playerDur > 0 && window.sbSegments.length > 0) {
                                    if (target > window.sbPosBeforeDrag) {
                                        // Forward scrub landing inside a segment clicks
                                        // to the segment's end point.
                                        for (var i = 0; i < window.sbSegments.length; i++) {
                                            var sg = window.sbSegments[i]
                                            if (target >= sg.start && target < sg.end) {
                                                target = sg.end; sg.skipped = true
                                                window.sbSegmentsChanged()
                                                break
                                            }
                                        }
                                    } else {
                                        // Backward scrub = watching by choice: nothing
                                        // from here forward auto-skips this playthrough.
                                        for (var j = 0; j < window.sbSegments.length; j++)
                                            if (window.sbSegments[j].start >= target - 1) window.sbSegments[j].skipped = true
                                        window.sbSegmentsChanged()
                                    }
                                    window.playerPrevPos = target
                                }
                                window.seekToFraction(window.playerDur > 0 ? target / window.playerDur : frac)
                                window.seekDragging = false
                            }
                            onCanceled: window.seekDragging = false
                        }
                    }
                    Text {
                        text: window.fmtTime(window.playerDur)
                        color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                        Layout.preferredWidth: window.s(46)
                    }
                    // Settings (volume / subtitles / speed / resolution / share).
                    Rectangle {
                        Layout.preferredWidth: window.s(34); Layout.preferredHeight: window.s(28); radius: window.s(8)
                        color: window.playerSettingsOpen ? window.sectionAccent
                            : (setMouse.containsMouse ? window.surface2 : Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6))
                        Text { anchors.centerIn: parent; text: "󰒓"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(15); color: window.playerSettingsOpen ? window.crust : window.text }
                        MouseArea { id: setMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.playerSettingsOpen = !window.playerSettingsOpen }
                    }
                }
            }

            // ===== comments side panel (slides in from the right) =====
            Rectangle {
                id: commentsPanel
                z: 7
                // sits below the top bar so the comments toggle stays clickable.
                // No right anchor — x drives the slide (open = flush right, closed
                // = pushed off-screen). Anchoring right would pin it open.
                // Rides up with the video when the page scrolls into up-next.
                anchors { top: parent.top; topMargin: window.s(58) - playerView.ytPageOff
                          bottom: parent.bottom; bottomMargin: window.s(64) + playerView.ytPageOff }
                width: Math.min(window.s(360), parent.width * 0.42)
                // Animate a 0→1 slide, NOT x: with a Behavior on x, a window
                // resize changes parent.width and the "closed" panel visibly
                // sweeps across the video for 220ms. Slide keeps open/close
                // animated while resizes reposition instantly.
                property real slide: window.commentsOpen ? 1 : 0
                Behavior on slide { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                x: parent.width - slide * width
                color: Qt.rgba(0, 0, 0, 0.30)   // ~70% transparent, per request
                // Backdrop click-swallow: panel clicks must never play/pause the video.
                MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

                // soft left edge so it reads against bright video
                Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1,1,1,0.12) }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(10)
                    RowLayout {
                        Layout.fillWidth: true; spacing: window.s(8)
                        Text { text: "Comments"; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            Layout.preferredWidth: window.s(30); Layout.preferredHeight: window.s(30); radius: window.s(8)
                            color: cmtCloseMouse.containsMouse ? Qt.rgba(1,1,1,0.18) : Qt.rgba(1,1,1,0.08)
                            Text { anchors.centerIn: parent; text: "󰅖"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(14); color: "white" }
                            MouseArea { id: cmtCloseMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.commentsOpen = false }
                        }
                    }

                    BusyIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        running: window.commentsLoading; visible: window.commentsLoading
                        implicitWidth: window.s(34); implicitHeight: window.s(34)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !window.commentsLoading && commentsModel.count === 0
                        text: window.commentsMsg !== "" ? window.commentsMsg : "Loading…"
                        color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                        wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                    }

                    ListView {
                        id: commentsList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true; spacing: window.s(12)
                        model: commentsModel
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {
                            id: cmtScroll
                            policy: ScrollBar.AlwaysOn
                            visible: commentsList.contentHeight > commentsList.height
                            width: window.s(9)
                            background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.08) }
                            contentItem: Rectangle {
                                implicitWidth: window.s(7); radius: width / 2
                                color: cmtScroll.pressed ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.40)
                            }
                        }
                        delegate: ColumnLayout {
                            width: commentsList.width
                            spacing: window.s(3)
                            property bool revealed: false
                            RowLayout {
                                Layout.fillWidth: true; spacing: window.s(6)
                                Text { text: model.author; textFormat: Text.PlainText; color: window.sectionAccent; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { visible: model.spoiler; text: "⚠ spoiler"; color: window.red; font.family: "JetBrains Mono"; font.pixelSize: window.s(10) }
                                Text { visible: model.likes > 0; text: "󰔓 " + model.likes; color: Qt.rgba(1,1,1,0.6); font.family: "JetBrains Mono"; font.pixelSize: window.s(10) }
                            }
                            TextEdit {
                                Layout.fillWidth: true
                                text: (model.spoiler && !revealed) ? "Spoiler — tap to reveal" : model.text
                                textFormat: TextEdit.PlainText
                                readOnly: true; selectByMouse: true
                                selectionColor: window.sectionAccent; selectedTextColor: window.crust
                                color: (model.spoiler && !revealed) ? Qt.rgba(1,1,1,0.5) : "white"
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.italic: (model.spoiler && !revealed)
                                wrapMode: TextEdit.WordWrap
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: model.spoiler && !revealed
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: revealed = true
                                }
                            }
                        }
                    }
                }
            }

            // ===== AI "parse this video" panel (slides in from the LEFT) =====
            Rectangle {
                id: aiPanel
                z: 8
                // Rides up with the video when the page scrolls into up-next.
                anchors { top: parent.top; topMargin: window.s(58) - playerView.ytPageOff
                          bottom: parent.bottom; bottomMargin: window.s(64) + playerView.ytPageOff }
                width: Math.min(window.s(440), parent.width * 0.5)
                // Slide-not-x: see commentsPanel — animating x makes resizes
                // drag the closed panel across the screen.
                property real slide: window.aiOpen ? 1 : 0
                Behavior on slide { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                x: (slide - 1) * width
                color: Qt.rgba(0, 0, 0, 0.46)
                Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1,1,1,0.12) }
                // Backdrop click-swallow: panel clicks must never play/pause the video.
                MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(12)

                    // ── loading state ──
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: window.aiLoading
                        spacing: window.s(12)
                        Item { Layout.fillHeight: true }
                        BusyIndicator {
                            Layout.alignment: Qt.AlignHCenter
                            running: window.aiLoading
                            implicitWidth: window.s(38); implicitHeight: window.s(38)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Reading the transcript and searching the web…"
                            color: Qt.rgba(1,1,1,0.65); font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // ── message / error state ──
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: !window.aiLoading && window.aiText === "" && window.aiMsg !== ""
                        spacing: window.s(10)
                        Item { Layout.fillHeight: true }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "󰧑"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(34); color: Qt.rgba(1,1,1,0.25)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: window.aiMsg; color: Qt.rgba(1,1,1,0.8); font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                            wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // ── answer ──
                    Flickable {
                        id: aiFlick
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: !window.aiLoading && window.aiText !== ""
                        clip: true; contentWidth: width; contentHeight: aiBody.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {
                            id: aiScroll
                            policy: ScrollBar.AsNeeded
                            width: window.s(9)
                            background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.08) }
                            contentItem: Rectangle {
                                implicitWidth: window.s(7); radius: width / 2
                                color: aiScroll.pressed ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.40)
                            }
                        }
                        TextEdit {
                            id: aiBody; width: aiFlick.width - window.s(10)
                            text: window.aiText; color: "white"
                            readOnly: true; selectByMouse: true
                            selectionColor: window.sectionAccent; selectedTextColor: window.crust
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                            wrapMode: TextEdit.WordWrap
                            textFormat: TextEdit.MarkdownText
                            onLinkActivated: (l) => Quickshell.execDetached(["xdg-open", l])
                            onTextChanged: aiFlick.contentY = Math.max(0, aiBody.implicitHeight - aiFlick.height)
                        }
                    }

                    // ── ask a follow-up (this is what hits the web) ──
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(40)
                        visible: !window.aiLoading && window.aiText !== ""
                        radius: window.s(10)
                        color: Qt.rgba(1,1,1,0.08)
                        border.width: 1; border.color: aiAskField.activeFocus ? window.sectionAccent : Qt.rgba(1,1,1,0.12)
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(5)
                            spacing: window.s(6)
                            TextField {
                                id: aiAskField
                                Layout.fillWidth: true; Layout.fillHeight: true
                                background: null
                                placeholderText: "Ask a follow-up — searches the web…"
                                placeholderTextColor: Qt.rgba(1,1,1,0.4)
                                color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                verticalAlignment: TextInput.AlignVCenter
                                onAccepted: { window.aiAsk(text); text = "" }
                            }
                            Rectangle {
                                Layout.preferredWidth: window.s(30); Layout.preferredHeight: window.s(30); radius: window.s(8)
                                enabled: aiAskField.text.trim() !== ""
                                opacity: enabled ? 1 : 0.4
                                color: aiSendMouse.containsMouse && enabled
                                    ? Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.30)
                                    : Qt.rgba(1,1,1,0.10)
                                Text { anchors.centerIn: parent; text: "󰒊"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(15); color: window.sectionAccent }
                                MouseArea { id: aiSendMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { window.aiAsk(aiAskField.text); aiAskField.text = "" } }
                            }
                        }
                    }
                }
            }

            // ===== Right-edge side tabs: Comments · Up next =====
            // A vertical strip on the middle of the right edge. It rides the left edge
            // of whichever panel is open, and each tab toggles its panel.
            Column {
                id: sideTabs
                z: 10
                // Auto-hide with the rest of the chrome (like the transport/timer
                // buttons): the Comments + Up-next tabs fade out when the controls
                // idle / the player is out of focus, and return on mouse movement.
                opacity: playerView.chromeShown ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                spacing: window.s(6)
                anchors.verticalCenter: parent.verticalCenter
                // Track the panels' LIVE x (they animate via their slide), so
                // the tabs move 1:1 with them — no own Behavior, no resize lag.
                x: Math.min(commentsPanel.x, upNextPanel.x) - width

                // tab factory
                component SideTab: Rectangle {
                    property string glyph: ""
                    property bool active: false
                    property bool showTab: true
                    visible: showTab
                    width: window.s(28); height: window.s(46)
                    topLeftRadius: window.s(9); bottomLeftRadius: window.s(9)
                    color: active ? window.sectionAccent : (stMouse.containsMouse ? Qt.rgba(1,1,1,0.22) : Qt.rgba(0, 0, 0, 0.55))
                    Behavior on color { ColorAnimation { duration: 150 } }
                    signal tapped()
                    Text { anchors.centerIn: parent; text: glyph; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(17)
                        color: parent.active ? window.crust : "white" }
                    MouseArea { id: stMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.tapped() }
                }
                SideTab { glyph: "󰆉"; active: window.commentsOpen; showTab: window.playerKind !== "music"; onTapped: window.toggleComments() }
                // (up-next side tab removed — up next lives in the below-video
                //  page now: scroll down over the video to reach it)
            }

            // ===== Left-edge AI tab (centered) =====
            Rectangle {
                id: aiSideTab
                z: 10
                // Auto-hide with the chrome, same as the transport buttons + side tabs.
                opacity: playerView.chromeShown ? 1 : 0
                visible: window.playerKind !== "music" && opacity > 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                width: window.s(28); height: window.s(46)
                topRightRadius: window.s(9); bottomRightRadius: window.s(9)
                anchors.verticalCenter: parent.verticalCenter
                // Rides the panel's live edge (panel animates via slide) — no
                // own Behavior, so resizes snap instead of lagging across.
                x: aiPanel.x + aiPanel.width
                color: window.aiOpen ? window.sectionAccent : (aiTabMouse.containsMouse ? Qt.rgba(1,1,1,0.22) : Qt.rgba(0, 0, 0, 0.55))
                Behavior on color { ColorAnimation { duration: 150 } }
                Text { anchors.centerIn: parent; text: "󰚩"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(17); color: window.aiOpen ? window.crust : "white" }
                MouseArea { id: aiTabMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.toggleAi() }
            }

            // ===== Up-next side panel (rest of series / more videos) =====
            Rectangle {
                id: upNextPanel
                z: 9
                anchors { top: parent.top; topMargin: window.s(58); bottom: parent.bottom; bottomMargin: window.s(64) }
                width: Math.min(window.s(380), parent.width * 0.44)
                // Slide-not-x: see commentsPanel (resize flash).
                property real slide: window.upNextOpen ? 1 : 0
                Behavior on slide { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                x: parent.width - slide * width
                color: Qt.rgba(0, 0, 0, 0.40)
                Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1,1,1,0.12) }

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(10)
                    RowLayout {
                        Layout.fillWidth: true; spacing: window.s(8)
                        Text { text: (window.playerKind === "tv" || window.playerKind === "anime") ? "Up next — episodes" : "Up next"
                            color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(15); font.weight: Font.Bold }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            Layout.preferredWidth: window.s(30); Layout.preferredHeight: window.s(30); radius: window.s(8)
                            color: unCloseMouse.containsMouse ? Qt.rgba(1,1,1,0.18) : Qt.rgba(1,1,1,0.08)
                            Text { anchors.centerIn: parent; text: "󰅖"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(14); color: "white" }
                            MouseArea { id: unCloseMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.upNextOpen = false }
                        }
                    }
                    // Now-playing: title · channel · description (YouTube).
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: window.s(4)
                        visible: window.playerKind === "youtube" && (window.currentVideoChannel !== "" || window.currentVideoDescription !== "")
                        Text { Layout.fillWidth: true; text: window.selectedTitle; textFormat: Text.PlainText; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                        Text {
                            Layout.fillWidth: true; visible: window.currentVideoChannel !== ""
                            // channel · upload date — the channel name links to its page
                            text: window.currentVideoChannel + (window.currentVideoDate !== "" ? "   ·  " + window.currentVideoDate : "")
                            color: unChM.containsMouse ? window.red : window.sectionAccent
                            Behavior on color { ColorAnimation { duration: 150 } }
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold; elide: Text.ElideRight
                            MouseArea {
                                id: unChM; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; enabled: window.currentVideoChannelId !== ""
                                onClicked: {
                                    var cid = window.currentVideoChannelId, cname = window.currentVideoChannel
                                    window.closePlayer()
                                    openYoutubeChannel(cid, cname)
                                }
                            }
                        }
                        Flickable {
                            Layout.fillWidth: true; Layout.preferredHeight: Math.min(unDescText.implicitHeight, window.s(130))
                            visible: window.currentVideoDescription !== ""
                            clip: true; contentHeight: unDescText.implicitHeight; boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: window.s(7); contentItem: Rectangle { implicitWidth: window.s(5); radius: width / 2; color: window.surface2 } }
                            Text { id: unDescText; width: parent.width - window.s(8); text: window.currentVideoDescription; textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); wrapMode: Text.WordWrap; lineHeight: 1.25 }
                        }
                        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(1, 1, 1, 0.10) }
                    }
                    Text {
                        Layout.fillWidth: true; visible: upNextModel.count === 0
                        text: "Nothing queued."
                        color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); horizontalAlignment: Text.AlignHCenter
                    }
                    ListView {
                        id: upNextList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true; spacing: window.s(8); model: upNextModel
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                        delegate: Rectangle {
                            width: upNextList.width; height: model.kind === "video" ? window.s(72) : window.s(50)
                            radius: window.s(8); color: unRowMouse.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.05)
                            RowLayout {
                                anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(10)
                                Rectangle {   // YouTube thumbnail
                                    visible: model.kind === "video"
                                    Layout.preferredWidth: window.s(96); Layout.preferredHeight: window.s(54); radius: window.s(6); color: window.crust; clip: true
                                    Image { anchors.fill: parent; source: model.vid ? ("https://i.ytimg.com/vi/" + model.vid + "/mqdefault.jpg") : ""
                                        fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true; cache: true; visible: status === Image.Ready }
                                }
                                Rectangle {   // episode number badge
                                    visible: model.kind === "episode"
                                    Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36); radius: window.s(8); color: window.surface1
                                    Text { anchors.centerIn: parent; text: String(model.epNum); font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; color: window.sectionAccent }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: window.s(2)
                                    Text { Layout.fillWidth: true; text: model.title; textFormat: Text.PlainText; color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(12); font.weight: Font.Bold; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                                    Text { Layout.fillWidth: true; visible: model.sub !== ""; text: model.sub; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(10); elide: Text.ElideRight; maximumLineCount: 1 }
                                }
                            }
                            MouseArea { id: unRowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: upNextPlay(model.kind, model.epNum, model.vid, model.title, model.channelId, model.channel) }
                        }
                    }
                }
            }
        }
    }

    // ── Add-to-playlist picker (local playlists) ──
    Rectangle {
        id: ytPlPicker
        anchors.fill: parent; z: 210
        visible: window.ytPlPickerOpen
        color: Qt.rgba(0, 0, 0, 0.7)
        MouseArea { anchors.fill: parent; onClicked: window.ytPlPickerOpen = false }   // click-out closes
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(window.s(380), parent.width * 0.82)
            height: Math.min(window.s(440), parent.height * 0.82)
            radius: window.s(16); color: window.base; border.width: 1; border.color: Qt.rgba(1,1,1,0.08)
            MouseArea { anchors.fill: parent; onClicked: {} }   // swallow clicks inside the card
            ColumnLayout {
                anchors.fill: parent; anchors.margins: window.s(16); spacing: window.s(10)
                Text { text: "Add to playlist"; color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(16); font.weight: Font.Bold }
                Text { Layout.fillWidth: true; text: window.ytAddItem.title || ""; color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); elide: Text.ElideRight; maximumLineCount: 1 }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: window.s(40); radius: window.s(10)
                    color: plkNewMouse.containsMouse ? window.red : window.surface0
                    Text { anchors.centerIn: parent; text: "+  New playlist (add this)"; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; color: plkNewMouse.containsMouse ? window.crust : window.text }
                    MouseArea { id: plkNewMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            ytPlaylistCreate("Playlist " + (window.ytPlaylists.length + 1))
                            var p = window.ytPlaylists[window.ytPlaylists.length - 1]
                            if (p) ytPlaylistAdd(p.id, window.ytAddItem)
                            window.ytPlPickerOpen = false
                        }
                    }
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: window.s(6)
                    model: window.ytPlaylists
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: window.s(9); background: Rectangle { radius: width / 2; color: Qt.rgba(1, 1, 1, 0.06) } contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                    delegate: Rectangle {
                        width: ListView.view.width; height: window.s(46); radius: window.s(8)
                        color: plkRowMouse.containsMouse ? window.surface1 : window.surface0
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(12); spacing: window.s(10)
                            Text { text: "󰐑"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(18); color: window.red }
                            Text { Layout.fillWidth: true; text: modelData.name; font.family: "JetBrains Mono"; font.pixelSize: window.s(13); font.weight: Font.Bold; color: window.text; elide: Text.ElideRight }
                            Text { text: (modelData.items ? modelData.items.length : 0) + ""; font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0 }
                        }
                        MouseArea { id: plkRowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { ytPlaylistAdd(modelData.id, window.ytAddItem); window.ytPlPickerOpen = false } }
                    }
                }
            }
        }
    }

    // ── Self-limit gate overlay for Movies / TV / Anime ──
    // Blank modal with a number selector ("how many can you watch"). Shows ONLY for the
    // selector — when locked, the three tabs simply hide and you're dropped on YouTube,
    // so there is never a modal you can't dismiss.
    Rectangle {
        id: mediaGate
        anchors.fill: parent
        z: 200
        readonly property bool onGated: window.gatedKeys.indexOf(window.mediaType) >= 0
        // Never show in gaming mode (no watch limit there) — reactive so it hides the
        // instant the focus mode loads/changes, even if the gate was opened earlier.
        visible: window.currentView === "search" && onGated && window.mediaGateOpen
                 && !window.mediaIsLocked() && window.focusMode !== "gaming"
        color: Qt.rgba(0, 0, 0, 0.80)
        // Swallow all input so the gate is truly modal.
        MouseArea { anchors.fill: parent; hoverEnabled: true; preventStealing: true; onClicked: {} }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(window.s(430), parent.width * 0.82)
            height: window.s(330)
            radius: window.s(16); color: window.base
            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.08)

            // SELECTOR — pick the allowance.
            ColumnLayout {
                anchors.centerIn: parent; width: parent.width - window.s(48); spacing: window.s(16)
                Text { Layout.alignment: Qt.AlignHCenter; text: "How many can you watch?"; color: window.text; font.family: "JetBrains Mono"; font.pixelSize: window.s(17); font.weight: Font.Bold }
                Text {
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: "Pick a limit before you start. After this many videos, Movies / TV / Anime lock for 10 minutes."
                    color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                }
                // Horizontal scroll-wheel picker, 1 → 10 (starts at 1).
                Item {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: window.s(290); Layout.preferredHeight: window.s(70)
                    // centre selection frame
                    Rectangle {
                        anchors.centerIn: parent; width: window.s(60); height: window.s(60); radius: window.s(12)
                        color: Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.16)
                        border.width: 1; border.color: window.mauve
                    }
                    // Circular wheel (wraps: …9, 10, 1, 2… so 10 sits left of 1).
                    PathView {
                        id: epWheel
                        property int itemW: window.s(58)
                        anchors.fill: parent
                        clip: true
                        model: 10
                        pathItemCount: Math.max(3, Math.floor(width / itemW))
                        snapMode: PathView.SnapToItem
                        highlightRangeMode: PathView.StrictlyEnforceRange
                        preferredHighlightBegin: 0.5
                        preferredHighlightEnd: 0.5
                        path: Path {
                            startX: 0; startY: epWheel.height / 2
                            PathLine { x: epWheel.width; y: epWheel.height / 2 }
                        }
                        delegate: Item {
                            width: epWheel.itemW; height: epWheel.height
                            readonly property bool sel: PathView.isCurrentItem
                            Text {
                                anchors.centerIn: parent
                                text: String(modelData + 1)
                                font.family: "JetBrains Mono"
                                font.pixelSize: sel ? window.s(28) : window.s(20)
                                font.weight: sel ? Font.Bold : Font.Medium
                                color: sel ? window.mauve : window.text
                                opacity: sel ? 1.0 : 0.4
                                Behavior on font.pixelSize { NumberAnimation { duration: 120 } }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: epWheel.currentIndex = index }
                        }
                        // Always reopen the picker at 1, take key focus, and drive it by controller.
                        Connections {
                            target: window
                            function onMediaGateOpenChanged() {
                                if (window.mediaGateOpen) {
                                    epWheel.currentIndex = 0
                                    window.forceActiveFocus()
                                    Quickshell.execDetached(["bash", "-c", "pkill -f media_gate_controller.py 2>/dev/null; setsid python3 ~/.config/hypr/scripts/quickshell/watchers/media_gate_controller.py >/dev/null 2>&1 < /dev/null &"])
                                } else {
                                    Quickshell.execDetached(["bash", "-c", "pkill -f media_gate_controller.py 2>/dev/null"])
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: window.s(170); Layout.preferredHeight: window.s(44); radius: window.s(12)
                    color: startMouse.containsMouse ? window.mauve : window.surface1
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text {
                        anchors.centerIn: parent
                        text: "Start — " + (epWheel.currentIndex + 1) + (epWheel.currentIndex === 0 ? " video" : " videos")
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(14); font.weight: Font.Bold
                        color: startMouse.containsMouse ? window.crust : window.text
                    }
                    MouseArea { id: startMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: window.mediaChooseAllowance(epWheel.currentIndex + 1) }
                }
                // Always-available escape so the gate can never trap you.
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Not now — go to YouTube"
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                    color: leaveMouse.containsMouse ? window.text : window.subtext0
                    MouseArea { id: leaveMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { window.mediaGateOpen = false; selectSection(window.focusMode === "gaming" ? "games" : "youtube") } }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIBRARY BROWSE OVERLAY — MAL-style watchlist for movies / TV / anime.
    // Status slider (same statuses as the MAL anime lists) over a grid of the
    // tracked items for that status; ✕ removes, clicking an item opens it.
    // ═══════════════════════════════════════════════════════════════════════
    Rectangle {
        id: libraryOverlay
        anchors.fill: parent; z: 500
        visible: window.libraryOpen
        color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.98)
        MouseArea { anchors.fill: parent }   // swallow clicks to the content behind

        ColumnLayout {
            anchors.fill: parent; anchors.margins: window.s(20); spacing: window.s(14)

            RowLayout {
                Layout.fillWidth: true; spacing: window.s(12)
                Text { text: "★  Library"; color: window.text; font.family: "JetBrains Mono"
                       font.pixelSize: window.s(20); font.weight: Font.Bold }
                Text { text: libraryModel.count + " in " + window.libLabel(window.libStatus)
                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                Item { Layout.fillWidth: true }
                Rectangle { Layout.preferredWidth: window.s(38); Layout.preferredHeight: window.s(38); radius: window.s(10)
                    color: libCloseMouse.containsMouse ? window.surface2 : window.surface1
                    Text { anchors.centerIn: parent; text: "✕"; color: window.text; font.pixelSize: window.s(16) }
                    MouseArea { id: libCloseMouse; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: window.libraryOpen = false } }
            }

            // Status slider
            RowLayout {
                Layout.fillWidth: true; spacing: window.s(8)
                Repeater {
                    model: window.malStatuses
                    Rectangle {
                        Layout.preferredHeight: window.s(34)
                        Layout.preferredWidth: statusLbl.implicitWidth + window.s(26)
                        radius: window.s(17)
                        property bool sel: window.libStatus === modelData.key
                        color: sel ? window.sectionAccent : (statusMouse.containsMouse ? window.surface1 : window.surface0)
                        Behavior on color { ColorAnimation { duration: 180 } }
                        Text { id: statusLbl; anchors.centerIn: parent; text: modelData.label
                               color: parent.sel ? window.crust : window.text
                               font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                               font.weight: parent.sel ? Font.Bold : Font.Normal }
                        MouseArea { id: statusMouse; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: window.libSetBrowseStatus(modelData.key) }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            GridView {
                id: libGrid
                Layout.fillWidth: true; Layout.fillHeight: true
                model: libraryModel
                cellWidth: Math.floor(width / 5); cellHeight: cellWidth * 1.5 + window.s(44)
                clip: true; boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: window.s(9)
                    contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                delegate: Item {
                    id: libCell
                    width: libGrid.cellWidth; height: libGrid.cellHeight
                    // Right-click flips the poster to a "Move to" status picker
                    // (same statuses as MAL) so an entry can be re-shelved in place.
                    property bool libPgFlipped: false
                    // Captured from the delegate model so the back-face Repeater
                    // (whose own model is the status list) can still reach this item.
                    property string cardImdb: model.imdbId || ""
                    property string cardTitle: model.title || ""
                    property string cardPoster: model.poster || ""
                    property string cardType: model.type || ""
                    property string cardStatus: model.status || ""
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: window.s(6); spacing: window.s(4)
                        Rectangle {
                            id: libPgPoster
                            Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(8); color: window.crust; clip: true
                            transform: Rotation {
                                id: libPgFlip
                                origin.x: libPgPoster.width / 2; origin.y: libPgPoster.height / 2
                                axis.x: 0; axis.y: 1; axis.z: 0
                                angle: libCell.libPgFlipped ? 180 : 0
                                Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
                            }
                            Image { anchors.fill: parent; source: model.poster || ""; fillMode: Image.PreserveAspectCrop
                                    asynchronous: true; smooth: true; cache: true
                                    sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                                    visible: status === Image.Ready && libPgFlip.angle < 90 }
                            Rectangle { anchors.fill: parent; color: window.surface0; radius: window.s(8)
                                visible: !model.poster && libPgFlip.angle < 90
                                Text { anchors.centerIn: parent; width: parent.width - window.s(8); text: model.title || ""
                                       textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"
                                       font.pixelSize: window.s(11); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                                       maximumLineCount: 5; elide: Text.ElideRight } }
                            // base click = open; right-click = flip to the status picker
                            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                enabled: libPgFlip.angle < 90
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (m) => {
                                    if (m.button === Qt.RightButton) libCell.libPgFlipped = true
                                    else { window.libraryOpen = false; openItem(model, { kind: "library" }) }
                                } }
                            // type badge (top-left)
                            Rectangle { visible: libPgFlip.angle < 90
                                anchors { top: parent.top; left: parent.left; margins: window.s(6) }
                                width: badgeT.implicitWidth + window.s(10); height: window.s(18); radius: window.s(5); color: Qt.rgba(0,0,0,0.62)
                                Text { id: badgeT; anchors.centerIn: parent
                                       text: model.type === "movie" ? "MOVIE" : (model.type === "anime" ? "ANIME" : "TV")
                                       color: "white"; font.family: "JetBrains Mono"; font.pixelSize: window.s(8); font.weight: Font.Bold } }
                            // remove (top-right)
                            Rectangle { visible: libPgFlip.angle < 90
                                anchors { top: parent.top; right: parent.right; margins: window.s(6) }
                                width: window.s(24); height: window.s(24); radius: width / 2
                                color: rmMouse.containsMouse ? window.red : Qt.rgba(0,0,0,0.62)
                                Text { anchors.centerIn: parent; text: "✕"; color: "white"; font.pixelSize: window.s(12) }
                                MouseArea { id: rmMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: (m) => { m.accepted = true; window.libRemove(model.imdbId) } } }
                            // ── BACK: "Move to" status picker (counter-rotated) ──
                            Rectangle {
                                anchors.fill: parent; radius: window.s(8); color: window.surface0
                                border.color: Qt.rgba(window.sectionAccent.r, window.sectionAccent.g, window.sectionAccent.b, 0.5); border.width: 1
                                visible: libPgFlip.angle >= 90
                                transform: Rotation {
                                    origin.x: libPgPoster.width / 2; origin.y: libPgPoster.height / 2
                                    axis.x: 0; axis.y: 1; axis.z: 0
                                    angle: 180
                                }
                                MouseArea { anchors.fill: parent; onClicked: libCell.libPgFlipped = false }
                                Column {
                                    anchors.centerIn: parent; spacing: window.s(4); width: parent.width - window.s(14)
                                    Text { width: parent.width; text: "Move to"; color: window.subtext0
                                           font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold
                                           horizontalAlignment: Text.AlignHCenter; bottomPadding: window.s(2) }
                                    Repeater {
                                        model: window.malStatuses
                                        delegate: Rectangle {
                                            width: parent.width; height: window.s(22); radius: window.s(6)
                                            property bool cur: modelData.key === libCell.cardStatus
                                            color: cur ? window.sectionAccent
                                                 : (libPgStM.containsMouse ? window.surface2 : window.surface1)
                                            Behavior on color { ColorAnimation { duration: 120 } }
                                            Text { anchors.centerIn: parent; text: modelData.label
                                                   color: parent.cur ? window.crust : window.text
                                                   font.family: "JetBrains Mono"; font.pixelSize: window.s(9)
                                                   font.weight: parent.cur ? Font.Bold : Font.Normal }
                                            MouseArea { id: libPgStM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    libCell.libPgFlipped = false
                                                    window.libSet({ imdbId: libCell.cardImdb, title: libCell.cardTitle,
                                                                    poster: libCell.cardPoster, type: libCell.cardType }, modelData.key)
                                                } }
                                        }
                                    }
                                }
                            }
                        }
                        Text { Layout.fillWidth: true; text: model.title || ""; textFormat: Text.PlainText; color: window.text
                               font.family: "JetBrains Mono"; font.pixelSize: window.s(11); horizontalAlignment: Text.AlignHCenter
                               maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap }
                    }
                }
                Text { anchors.centerIn: parent; visible: libraryModel.count === 0
                       text: "Nothing in “" + window.libLabel(window.libStatus) + "” yet.\nTap ★ on a movie or show to add it."
                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13)
                       horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY FULL PAGE — "View All ↗" on a home row opens the whole catalog
    // behind that row as a grid; scrolls paginate more of the catalog in.
    // ═══════════════════════════════════════════════════════════════════════
    Rectangle {
        id: catPageOverlay
        anchors.fill: parent; z: 500
        visible: window.catPageOpen
        color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.98)
        MouseArea { anchors.fill: parent }   // swallow clicks to the content behind

        ColumnLayout {
            anchors.fill: parent; anchors.margins: window.s(20); spacing: window.s(14)

            RowLayout {
                Layout.fillWidth: true; spacing: window.s(12)
                Rectangle {
                    Layout.preferredWidth: window.s(38); Layout.preferredHeight: window.s(38); radius: window.s(10)
                    color: catPageBackM.containsMouse ? window.surface2 : window.surface1
                    Text { anchors.centerIn: parent; text: "←"; color: window.text; font.pixelSize: window.s(16) }
                    MouseArea { id: catPageBackM; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: window.catPageOpen = false }
                }
                Text { text: window.catPageTitle; color: window.text; font.family: "JetBrains Mono"
                       font.pixelSize: window.s(20); font.weight: Font.Bold }
                Text { text: catPageModel.count + " titles"
                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(12) }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: window.s(38); Layout.preferredHeight: window.s(38); radius: window.s(10)
                    color: catPageCloseM.containsMouse ? window.surface2 : window.surface1
                    Text { anchors.centerIn: parent; text: "✕"; color: window.text; font.pixelSize: window.s(16) }
                    MouseArea { id: catPageCloseM; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: window.catPageOpen = false }
                }
            }

            GridView {
                id: catPageGrid
                Layout.fillWidth: true; Layout.fillHeight: true
                model: catPageModel
                cellWidth: Math.floor(width / 6); cellHeight: cellWidth * 1.5 + window.s(30)
                clip: true; boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: window.s(9)
                    contentItem: Rectangle { implicitWidth: window.s(7); radius: width / 2; color: window.surface2 } }
                // Nearing the bottom pulls the next catalog page in.
                onAtYEndChanged: if (atYEnd && window.catPageOpen)
                                     window.homeCatMore(window.catPageKey, window.catPageUrl)
                delegate: Item {
                    id: catPgCard
                    width: catPageGrid.cellWidth; height: catPageGrid.cellHeight
                    // Right-click flips to the "Move to" shelf picker.
                    property bool rcFlipped: false
                    property string cardImdb: model.imdbId || ""
                    property string cardTitle: model.title || ""
                    property string cardPoster: model.poster || ""
                    property string cardType: model.type || ""
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: window.s(6); spacing: window.s(4)
                        Rectangle {
                            id: catPgPoster
                            Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(8); color: window.crust; clip: true
                            transform: Rotation {
                                id: catPgFlip
                                origin.x: catPgPoster.width / 2; origin.y: catPgPoster.height / 2
                                axis.x: 0; axis.y: 1; axis.z: 0
                                angle: catPgCard.rcFlipped ? 180 : 0
                                Behavior on angle { NumberAnimation { duration: 360; easing.type: Easing.InOutQuad } }
                            }
                            Image { anchors.fill: parent; source: model.poster || ""; fillMode: Image.PreserveAspectCrop
                                    asynchronous: true; smooth: true; cache: true
                                    sourceSize.width: window.s(240); sourceSize.height: window.s(360)
                                    visible: status === Image.Ready }
                            Rectangle { anchors.fill: parent; color: window.surface0; radius: window.s(8)
                                visible: !model.poster
                                Text { anchors.centerIn: parent; width: parent.width - window.s(8); text: model.title || ""
                                       textFormat: Text.PlainText; color: window.subtext0; font.family: "JetBrains Mono"
                                       font.pixelSize: window.s(11); wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                                       maximumLineCount: 5; elide: Text.ElideRight } }
                            // ★ rating chip (top-left)
                            Rectangle {
                                visible: (model.rating || 0) > 0
                                anchors { top: parent.top; left: parent.left; margins: window.s(6) }
                                width: catPgRateT.width + window.s(10); height: window.s(18); radius: window.s(5)
                                color: Qt.rgba(0, 0, 0, 0.62)
                                Text { id: catPgRateT; anchors.centerIn: parent
                                       text: "★ " + (model.rating || 0).toFixed(1)
                                       color: "#f9e2af"; font.family: "JetBrains Mono"; font.pixelSize: window.s(9); font.weight: Font.Bold }
                            }
                            Rectangle {
                                anchors.fill: parent; radius: window.s(8); color: window.sectionAccent
                                opacity: catPgM.containsMouse ? 0.28 : 0
                                Behavior on opacity { NumberAnimation { duration: 200 } }
                            }
                            MouseArea { id: catPgM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                enabled: catPgFlip.angle < 90
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (m) => {
                                    if (m.button === Qt.RightButton) catPgCard.rcFlipped = true
                                    else { window.catPageOpen = false
                                           openItem(model, { kind: "catpage", key: window.catPageKey,
                                                             title: window.catPageTitle, url: window.catPageUrl }) }
                                } }
                            LibFlipBack {
                                fImdb: catPgCard.cardImdb; fTitle: catPgCard.cardTitle
                                fPoster: catPgCard.cardPoster
                                fType: window.mediaType === "anime" ? "anime" : catPgCard.cardType
                                shown: catPgFlip.angle >= 90
                                onDone: catPgCard.rcFlipped = false
                            }
                        }
                        Text { Layout.fillWidth: true; text: model.title || ""; textFormat: Text.PlainText; color: window.text
                               font.family: "JetBrains Mono"; font.pixelSize: window.s(11); horizontalAlignment: Text.AlignHCenter
                               maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap }
                    }
                }
                Text { anchors.centerIn: parent; visible: catPageModel.count === 0
                       text: "Loading " + window.catPageTitle + "…"
                       color: window.subtext0; font.family: "JetBrains Mono"; font.pixelSize: window.s(13) }
            }
        }
    }
}
