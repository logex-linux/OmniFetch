import Foundation

extension SelfTest {
    static func socialChecks(_ check: (String, Bool, String) -> Void) throws {
        func expect(_ name: String, _ success: Bool) { check(name, success, "") }
        let urls = ShareLinks.parse("6.28 复制链接【BV17x411w7KC?p=2】，看 https://x.com/a/status/123。另见 xhslink.com/a/AbCd，BV17x411w7KC?p=2")
        expect("share text order, part, dedup and decimal", urls.map(\.absoluteString) == [
            "https://www.bilibili.com/video/BV17x411w7KC?p=2", "https://x.com/a/status/123", "https://xhslink.com/a/AbCd"])
        expect("preserve signed share query", ShareLinks.parse("复制 https://a.test/photo.jpg?q=a%2Fb%2B%26!").first?.query == "q=a%2Fb%2B%26!")
        expect("domain boundary for native platforms", !XiaohongshuEngine().canHandle(URL(string: "https://notxiaohongshu.com/n")!) &&
               SocialPlatform.match(URL(string: "https://notbilibili.com/video/BV17x411w7KC")!) == nil)
        let registry = EngineRegistry.shared
        for (raw, id) in [("https://www.bilibili.com/bangumi/play/ep1", "ytdlp"),
                          ("https://www.bilibili.com/opus/123", "gallerydl"), ("https://t.bilibili.com/123", "gallerydl"),
                          ("https://mp.weixin.qq.com/s/demo", "ytdlp"),
                          ("https://bsky.app/profile/a/post/b", "gallerydl"),
                          ("https://commons.wikimedia.org/wiki/File:Example.jpg", "gallerydl"),
                          ("https://upload.wikimedia.org/x/a.jpg", "direct"),
                          ("https://www.youtube.com/shorts/abcdefghijk", "ytdlp")] {
            expect("route " + raw, registry.engine(for: URL(string: raw)!).id == id)
        }
        let dash: [[String: Any]] = [
            ["height": 1080, "codecs": "hev1", "bandwidth": 100, "baseUrl": "https://cdn.test/hevc"],
            ["height": 1080, "codecs": "avc1", "bandwidth": 80, "base_url": "https://cdn.test/avc"],
            ["height": 720, "codecs": "avc1", "baseUrl": "//cdn.test/720", "backupUrl": ["//backup.test/v"]]]
        let renditions = BilibiliEngine.renditions(dash, headers: [:])
        expect("bilibili keeps one playable stream per resolution", renditions.map(\.format.id) == ["1080", "720"] &&
               renditions.first?.file.url.lastPathComponent == "avc")
        let audio = RemoteFile(url: URL(string: "https://cdn.test/a")!, kind: .audio, fileExtension: "m4a")
        var info = MediaInfo(title: "分 P", files: [renditions[0].file, audio], engineID: "bilibili")
        info.videoVariants = Dictionary(uniqueKeysWithValues: renditions.map { ($0.format.id, $0.file) })
        let restored = try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(info))
        expect("cached quality change preserves audio and backup CDN", restored.files(for: "720") == [renditions[1].file, audio] &&
               restored.files(for: "720")[0].alternateURLs?.first?.host == "backup.test")

        let id = "010101010101010101010101", page = URL(string: "https://www.xiaohongshu.com/explore/" + "010101010101010101010101")!
        func note(_ value: [String: Any], target: String? = nil, quality: String = "best") throws -> MediaInfo {
            let root = ["note": ["noteDetailMap": [id: ["note": value]]]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
            return try XiaohongshuEngine.parsePage("<script>window.__INITIAL_STATE__ = \n" + json + ";</script>",
                                                   noteID: target ?? id, page: page, options: .init(quality: quality))
        }
        let streams: [String: Any] = ["h264": [
            ["height": 1080, "masterUrl": "", "backupUrls": ["//cdn.test/high.mp4"]],
            ["height": 720, "masterUrl": "//cdn.test/low.mp4", "backupUrls": ["//backup.test/low.mp4"]]]]
        let xhs = try note(["type": "video", "title": "笔记:undefined", "video": ["media": ["stream": streams]]], quality: "720")
        expect("xhs resolution cap and alternative CDN", xhs.files.first?.url.lastPathComponent == "low.mp4" &&
               xhs.files.first?.alternateURLs?.first?.host == "backup.test")
        expect("xhs missing master uses backup", xhs.files(for: xhs.formats.first?.id).first?.url.lastPathComponent == "high.mp4")
        let images: [[String: Any]] = [["urlDefault": "", "infoList": [
            ["imageScene": "WB_PRV", "url": "//cdn.test/preview.jpg"], ["imageScene": "WB_DFT", "url": "//cdn.test/photo.webp"]],
                                      "stream": ["h264": [["masterUrl": "//cdn.test/live.mp4"]]]],
                                       ["url": "https://cdn.test/next.jpg"]]
        let album = try note(["type": "normal", "video": [:], "imageList": images])
        expect("xhs photo and motion retain note order", album.isItemCollection && album.files.map(\.kind) == [.image, .video, .image] &&
               album.files.map(\.fileExtension) == ["webp","mp4","jpg"])
        expect("xhs login poster does not become a video", (try? note(["type": "video", "imageList": images])) == nil)
        expect("xhs never substitutes another note", (try? note(["type": "normal", "imageList": images], target: "different")) == nil)
        expect("xhs JS literal handling preserves quoted text",
               XiaohongshuEngine.replacingUndefined(#"{"a": undefined,"b":":undefined [undefined ,undefined","c":[undefined]}"#) ==
               #"{"a": null,"b":":undefined [undefined ,undefined","c":[null]}"#)

        let preview = URL(string: "https://channels.weixin.qq.com/web/pages/feed?token=demo%2Bvalue&eid=feed")!
        expect("wechat reads complete official preview", WeChatShare.previewParameters(preview)?.token == "demo+value")
        expect("wechat rejects missing or foreign preview fields", WeChatShare.previewParameters(URL(string: "https://channels.weixin.qq.com/web?eid=1")!) == nil &&
               WeChatShare.previewParameters(URL(string: "https://outside.test/web?eid=1&token=dummy")!) == nil)
        let feed: [String: Any] = ["errCode": 0, "data": ["feedInfo": ["h264VideoInfo": ["videoUrl": ""],
            "videoUrl": "https://cdn.test/main.mp4?signature=a%2Fb%2B%3D&flag=1", "h265VideoInfo": ["videoUrl": "//cdn.test/hevc.mp4"]]]]
        let wx = try WeChatShare.mediaInfo(feed)
        expect("wechat retains exact signature and alternative renditions", wx.selectedFormatID == "source" &&
               wx.files[0].url.query == "signature=a%2Fb%2B%3D&flag=1" && wx.files(for: "h265")[0].url.host == "cdn.test")
        expect("wechat expiry returns an error", (try? WeChatShare.mediaInfo(["errCode": 7])) == nil)

        let postURL = URL(string: "https://x.com/example/status/123")!
        let post: [String: Any] = ["data": ["id": "123", "text": "帖子", "attachments": ["media_keys": ["a","b"]]],
            "includes": ["media": [["media_key": "b", "type": "video", "variants": [
                ["content_type": "video/mp4", "bit_rate": 200, "url": "https://cdn.test/1280x720/b.mp4"],
                ["content_type": "video/mp4", "bit_rate": 100, "url": "https://cdn.test/640x360/b.mp4"]]],
                ["media_key": "a", "type": "photo", "url": "https://cdn.test/a.jpg"]]]]
        let tweet = try XMediaEngine.mediaInfo(post, page: postURL, options: .init(quality: "480"))
        expect("x mixed post uses attachment order and requested cap", tweet.isItemCollection && tweet.files.map(\.kind) == [.image,.video] &&
               tweet.files.last?.url.path.contains("640x360") == true && tweet.files.allSatisfy { $0.headers.isEmpty })
        let clip = try XMediaEngine.mediaInfo(post, page: postURL.appendingPathComponent("video/2"), options: .init())
        expect("x numbered video retains alternative formats", !clip.isItemCollection && clip.formats.count == 2 && clip.files.count == 1)
        expect("x missing attachment cannot become a successful post",
               (try? XMediaEngine.mediaInfo(["data": post["data"]!, "includes": ["media": []]], page: postURL, options: .init())) == nil)
        let messages: [Any] = [[2, ["category": "example"]], [3, "https://cdn.test/a.jpg", ["title":"画集", "category":"example"]]]
        let gallery = try GalleryDLEngine.mediaInfo(JSONSerialization.data(withJSONObject: messages), url: postURL)
        expect("gallery preview requires media", gallery.isItemCollection && gallery.title == "画集" &&
               (try? GalleryDLEngine.mediaInfo(Data("[[2,{}]]".utf8), url: postURL)) == nil)
        let options = DownloadOptions(formatID: "only-on-first", quality: "720")
        let playlist = try YTDLPEngine.mediaInfo(["_type": "multi_video", "entries": [["id": "first"]], "playlist_count": 2],
                                                  url: postURL, options: options)
        let request = DownloadRequest(info: playlist, options: options, destinationDirectory: FileManager.default.temporaryDirectory, baseName: "test")
        expect("multi-video preview and per-entry quality", playlist.isItemCollection && playlist.extra["count"] == "2" &&
               YTDLPEngine.selector(for: request) == YTDLPEngine.selector(quality: "720", audioOnly: false))
        expect("unavailable playlists cannot succeed", (try? YTDLPEngine.mediaInfo(["_type":"playlist", "entries":[]], url: postURL, options: .init())) == nil)
        expect("signed CDN rejects web response", HTTPProbe.isWebPage("Text/HTML; charset=UTF-8") && !HTTPProbe.isWebPage("video/mp4"))
        var settings = AppSettings()
        settings.cookieHeader = "example=dummy"
        settings.cookieDomain = "xiaohongshu.com"
        expect("manual cookie stays on its platform", settings.manualCookie(for: page) != nil && settings.manualCookie(for: postURL) == nil)
        expect("long multilingual filenames fit macOS", MediaNaming.sanitize(String(repeating: "风景", count: 100)).utf8.count <= 208)
    }
}
