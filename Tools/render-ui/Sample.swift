// P6-0a: Fake, realistic sample data for the UI renderer: the Hebrew ⇄ English pair, a few apps and websites.
// No real user data: nothing is read from this Mac (no running apps, no installed browsers, no preferences file).

import Foundation

enum SampleIDs {
    static let abc = InputSourceID("com.apple.keylayout.ABC")
    static let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    static let hebrewQWERTY = InputSourceID("com.apple.keylayout.Hebrew-QWERTY")
    static let pinyin = InputSourceID("com.apple.inputmethod.SCIM.ITABC")

    static let safari = "com.apple.Safari"
    static let chrome = "com.google.Chrome"
    static let zen = "app.zen-browser.zen"
    static let notes = "com.apple.Notes"
    static let whatsapp = "net.whatsapp.WhatsApp"
    static let slack = "com.tinyspeck.slackmacgap"
    static let terminal = "com.apple.Terminal"
    static let vscode = "com.microsoft.VSCode"
    static let mail = "com.apple.mail"
}

enum Sample {
    static let appNames: [String: String] = [
        SampleIDs.safari: "Safari", SampleIDs.chrome: "Google Chrome", SampleIDs.zen: "Zen",
        SampleIDs.notes: "Notes", SampleIDs.whatsapp: "WhatsApp", SampleIDs.slack: "Slack",
        SampleIDs.terminal: "Terminal", SampleIDs.vscode: "Visual Studio Code", SampleIDs.mail: "Mail",
    ]

    static func appName(_ id: String) -> String? { appNames[id] }

    /// The keyboards "turned on" on the pretend Mac.
    static let abcInfo = InputSourceInfo(id: SampleIDs.abc, name: "ABC", languageCode: "en", isEnabled: true,
                                         isConvertible: true, isInputMethod: false)
    static let hebrewInfo = InputSourceInfo(id: SampleIDs.hebrew, name: "Hebrew", languageCode: "he",
                                            isEnabled: true, isConvertible: true, isInputMethod: false)
    static let hebrewQWERTYInfo = InputSourceInfo(id: SampleIDs.hebrewQWERTY, name: "Hebrew-QWERTY",
                                                  languageCode: "he", isEnabled: false, isConvertible: true,
                                                  isInputMethod: false)
    static let pinyinInfo = InputSourceInfo(id: SampleIDs.pinyin, name: "Pinyin - Simplified", languageCode: "zh",
                                            isEnabled: true, isConvertible: false, isInputMethod: true)

    static let enabledSources = [abcInfo, hebrewInfo, pinyinInfo]
    static let allSources = [abcInfo, hebrewInfo, hebrewQWERTYInfo, pinyinInfo]

    static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return c.date ?? Date(timeIntervalSince1970: 0)
    }

    static let rules: [Rule] = [
        Rule(scope: .app(bundleID: SampleIDs.whatsapp), inputSource: SampleIDs.hebrew, origin: .pinned,
             updatedAt: date(3, 9, 12)),
        Rule(scope: .app(bundleID: SampleIDs.notes), inputSource: SampleIDs.hebrew, origin: .learned,
             updatedAt: date(16, 18, 40)),
        Rule(scope: .app(bundleID: SampleIDs.slack), inputSource: SampleIDs.abc, origin: .learned,
             updatedAt: date(17, 8, 5)),
        Rule(scope: .app(bundleID: SampleIDs.terminal), inputSource: SampleIDs.abc, origin: .pinned,
             updatedAt: date(1, 11, 0)),
        Rule(scope: .site(domain: "ynet.co.il"), inputSource: SampleIDs.hebrew, origin: .pinned,
             updatedAt: date(10, 7, 30)),
        Rule(scope: .site(domain: "github.com"), inputSource: SampleIDs.abc, origin: .learned,
             updatedAt: date(15, 22, 14)),
        Rule(scope: .site(domain: "walla.co.il"), inputSource: SampleIDs.hebrew, origin: .learned,
             updatedAt: date(12, 13, 2)),
        Rule(scope: .siteHost(host: "translate.google.com"), inputSource: SampleIDs.hebrew, origin: .pinned,
             updatedAt: date(14, 10, 45)),
        Rule(scope: .chat(bundleID: SampleIDs.whatsapp, key: ChatKey(kind: .hashed, value: "sample-chat")),
             inputSource: SampleIDs.abc, origin: .learned, label: nil, updatedAt: date(17, 9, 20)),
    ]

    static func preferences() -> Preferences {
        var p = Preferences()
        p.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew)
        p.general.onboardingSeen = true
        p.rules = rules
        p.apps = [
            SampleIDs.terminal: .init(replacementMethod: .terminal),
            SampleIDs.vscode: .init(convertEnabled: true, replacementMethod: .keysOnly),
            SampleIDs.slack: .init(disabled: true),
        ]
        return p
    }

    static let running: [AppCandidate] = [
        AppCandidate(bundleID: SampleIDs.mail, name: "Mail"),
        AppCandidate(bundleID: SampleIDs.notes, name: "Notes"),
        AppCandidate(bundleID: SampleIDs.safari, name: "Safari"),
    ]
}
