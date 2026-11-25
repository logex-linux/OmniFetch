import Foundation

/// Known share domains for the clipboard and the platform guide. The external
/// extractors can handle additional sites without an update to this list.
public struct SocialPlatform: Sendable {
    public let name: String
    public let domains: [String]
    public let support: String
    let preferGallery: Bool

    private init(_ name: String, _ domains: String, _ support: String = "yt-dlp", gallery: Bool = false) {
        self.name = name
        self.domains = domains.split(separator: " ").map(String.init)
        self.support = support
        self.preferGallery = gallery
    }

    public static let all: [Self] = [
        .init("哔哩哔哩", "bilibili.com b23.tv", "原生视频 / 专栏图集 / yt-dlp"),
        .init("小红书", "xiaohongshu.com xhslink.com", "原生视频和图集"),
        .init("微信视频号", "weixin.qq.com finder.video.qq.com mpvideo.qpic.cn wxapp.tc.qq.com res.wx.qq.com", "分享链接、官方预览和媒体直链"),
        .init("X / Twitter", "x.com twitter.com t.co", "图集 / yt-dlp / 可选官方 API", gallery: true),
        .init("YouTube", "youtube.com youtu.be youtube-nocookie.com", "视频、Shorts、音乐和播放列表"),
        .init("抖音", "douyin.com iesdouyin.com"),
        .init("微博", "weibo.com weibo.cn", "图集 / yt-dlp", gallery: true),
        .init("快手", "kuaishou.com gifshow.com kwai.com", "通用网页解析，视具体帖子而定"),
        .init("知乎", "zhihu.com", "视频内容 · yt-dlp"),
        .init("网易云音乐", "music.163.com"),
        .init("QQ 音乐", "y.qq.com"),
        .init("优酷", "youku.com"),
        .init("爱奇艺", "iqiyi.com"),
        .init("AcFun", "acfun.cn"),
        .init("西瓜视频 / 今日头条", "ixigua.com toutiao.com toutiaoimg.cn"),
        .init("斗鱼", "douyu.com douyutv.com"),
        .init("虎牙", "huya.com"),
        .init("喜马拉雅", "ximalaya.com"),
        .init("荔枝", "lizhi.fm"),
        .init("美拍", "meipai.com"),
        .init("梨视频", "pearvideo.com"),
        .init("LOFTER", "lofter.com", "gallery-dl 图集", gallery: true),
        .init("TikTok", "tiktok.com"),
        .init("Instagram", "instagram.com instagr.am", "图集 / yt-dlp", gallery: true),
        .init("Facebook", "facebook.com fb.watch fb.com"),
        .init("Reddit", "reddit.com redd.it", "图集 / yt-dlp", gallery: true),
        .init("Bluesky", "bsky.app", "图集 / yt-dlp", gallery: true),
        .init("Mastodon", "mastodon.social mastodon.online mstdn.jp fosstodon.org", "gallery-dl 实例", gallery: true),
        .init("Misskey", "misskey.io misskey.design misskey.art", "gallery-dl 实例", gallery: true),
        .init("Tumblr", "tumblr.com", "图集 / yt-dlp", gallery: true),
        .init("Pinterest", "pinterest.com pin.it", "图集 / yt-dlp", gallery: true),
        .init("Flickr", "flickr.com flic.kr", "gallery-dl 图集", gallery: true),
        .init("Pixiv", "pixiv.net", "gallery-dl，部分内容需账号", gallery: true),
        .init("ArtStation", "artstation.com", "gallery-dl 图集", gallery: true),
        .init("DeviantArt", "deviantart.com sta.sh", "gallery-dl 图集", gallery: true),
        .init("Behance", "behance.net", "gallery-dl 图集", gallery: true),
        .init("Imgur", "imgur.com", "图集 / yt-dlp", gallery: true),
        .init("Wikimedia Commons", "commons.wikimedia.org", "gallery-dl 图集", gallery: true),
        .init("Snapchat Spotlight", "snapchat.com"),
        .init("Twitch", "twitch.tv"),
        .init("Vimeo", "vimeo.com"),
        .init("Dailymotion", "dailymotion.com dai.ly"),
        .init("SoundCloud", "soundcloud.com"),
        .init("Bandcamp", "bandcamp.com"),
        .init("Niconico", "nicovideo.jp nico.ms"),
        .init("Naver TV", "tv.naver.com"),
        .init("SOOP", "sooplive.co.kr afreecatv.com"),
        .init("VK", "vk.com vkvideo.ru", "yt-dlp / 图集"),
        .init("Telegram", "t.me", "公开媒体嵌入"),
        .init("LinkedIn", "linkedin.com"),
        .init("Substack", "substack.com"),
        .init("Mixcloud", "mixcloud.com"),
        .init("500px", "500px.com", "gallery-dl 图集", gallery: true),
        .init("Steam 社区", "steamcommunity.com", "图集 / yt-dlp", gallery: true),
        .init("Patreon", "patreon.com", "图集 / yt-dlp，部分内容需账号", gallery: true),
        .init("Streamable", "streamable.com"),
        .init("Naver Blog", "blog.naver.com", "gallery-dl 图集", gallery: true),
        .init("Kakao TV", "tv.kakao.com"),
        .init("Rumble", "rumble.com")
    ]

    private static let byDomain = Dictionary(uniqueKeysWithValues: all.flatMap { site in site.domains.map { ($0, site) } })

    public static func match(_ url: URL) -> Self? {
        guard var host = url.host?.lowercased()[...] else { return nil }
        while !host.isEmpty {
            if let match = byDomain[String(host)] { return match }
            guard let dot = host.firstIndex(of: ".") else { break }
            host = host[host.index(after: dot)...]
        }
        return nil
    }
}

extension URL {
    func isOn(_ domain: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func mediaURL(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text), url.isRemoteMediaURL else { return nil }
        return url
    }

    var isRemoteMediaURL: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false && user == nil && password == nil
    }
}

enum ShareLinks {
    // Match in order, including URLs immediately preceded by Chinese share copy.
    // Signed queries stay byte-for-byte intact.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?i:https?://)[^\s<>"“”‘’【】《》，。！？；、（）]+|(?<![A-Za-z0-9_@./:-])(?:BV[A-Za-z0-9]{10}|(?i:av)[0-9]+)(?:\?p=[0-9]+)?(?![A-Za-z0-9_])|(?<![A-Za-z0-9_@./:-])(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?::[0-9]+)?(?:/[^\s<>"“”‘’【】《》，。！？；、（）]*)?"#)

    static func parse(_ text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<URL>()
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var raw = String(text[r])
            if !raw.contains("?") && !raw.contains("#") {
                while let end = raw.last, ".,;!'`".contains(end) { raw.removeLast() }
            }
            while raw.hasSuffix(")") && raw.filter({ $0 == ")" }).count > raw.filter({ $0 == "(" }).count {
                raw.removeLast()
            }
            let lower = raw.lowercased()
            if !lower.hasPrefix("https://") && !lower.hasPrefix("http://") {
                let id = raw.split(separator: "?", maxSplits: 1).first ?? ""
                let bili = (id.hasPrefix("BV") && id.count == 12 && !id.contains(".")) ||
                    (id.lowercased().hasPrefix("av") && !id.dropFirst(2).isEmpty && id.dropFirst(2).allSatisfy(\.isNumber))
                raw = bili ? "https://www.bilibili.com/video/" + raw : "https://" + raw
            }
            guard let url = URL.mediaURL(raw), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
