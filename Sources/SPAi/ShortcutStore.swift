import AppKit
import Carbon

/// スクリプト1本に割り当てるグローバルキー（仕様書 §5）。
/// Carbon の `RegisterEventHotKey` にそのまま渡せる形（keyCode ＋ Carbon 修飾キー）で持つ。
/// 割当はアプリ側 DB（UserDefaults・`ShortcutStore`）に保持し、`.jsx` には書き込まない。
nonisolated struct ScriptShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32   // Carbon 修飾キー（cmdKey / optionKey / controlKey / shiftKey）

    /// テンキーの数字は上段の数字のキーコードにそろえる（同じキー扱い＝旧版 SPAi 3 と同じ。2026-10-30 ユーザー指定）。
    /// 記録・保存データの読み込み・書き出しファイルの読み込みはすべてここを通るので、以前テンキーで登録した割当も
    /// 上段の数字として読まれる。ホットキーは上段とテンキーの両方で登録する（`HotKeyManager`）。
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = KeyDisplay.mainRowDigit(for: keyCode) ?? keyCode
        self.modifiers = modifiers
    }

    /// 記録パレットで捕まえた keyDown イベントから生成する。
    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode),
                  modifiers: KeyDisplay.carbonModifiers(from: event.modifierFlags))
    }

    /// 行末やメニューに出す表示文字列（例 "⌥⌘1"）。
    var display: String {
        KeyDisplay.modifierSymbols(modifiers) + KeyDisplay.keyName(keyCode)
    }

    /// ショートカット順の比較：キー順（1, 2 … A, B …。数字は数値順）→ 同じキーなら修飾キー順。空きキーを探しやすくする。
    /// 記録カードの割当一覧とパネルの「ショートカット付きのみ表示」で共用（2026-10-28）。
    static func keyOrder(_ a: ScriptShortcut, _ b: ScriptShortcut) -> Bool {
        let ka = KeyDisplay.keyName(a.keyCode), kb = KeyDisplay.keyName(b.keyCode)
        if ka != kb { return ka.compare(kb, options: .numeric) == .orderedAscending }
        return a.modifiers < b.modifiers
    }
}

/// 割当ファイルの状態（`ShortcutStore.inspect` が裏のキューで調べる。2026-10-24）。
/// ホットキー登録（使えるものだけ）・パネルの「ショートカット付きのみ表示」・記録カードの一覧が、
/// メインスレッドでファイルを確かめずに済むよう、ここにまとめて持つ。
nonisolated struct ShortcutFileState: Sendable, Equatable {
    /// ファイルが無い理由（記録カードのフォルダ名欄に出す状態）
    enum MissingReason: Sendable, Equatable {
        case trash                        // ゴミ箱の中にある（戻せば使える）
        case notConnected(volume: String) // 元の場所のボリュームがつながっていない
        case deleted
    }

    var isAvailable: Bool
    var isAlias: Bool
    var kind: ScriptKind
    /// 使えないときだけ
    var missing: MissingReason?
    /// 使えないときの今の場所（ゴミ箱の中など）。完全に削除されていれば nil
    var foundAt: URL?
}

/// スクリプトのフルパス → 割当キー、の永続化（UserDefaults に JSON）。
/// 各割当には URL ブックマーク（Finder エイリアス相当）を添えて保存し、`load()` で元のパスに
/// ファイルが無ければブックマークで解決してキーを付け替える。これでスクリプトの改名・移動
/// （同一ボリューム内）に割当が追随する（仕様書 §10「キー切れ」への回答・2026-07-08）。
nonisolated enum ShortcutStore {
    private static let key = "SPAi.scriptShortcuts"

    /// 保存形式。bookmark が省略可能なので、旧形式（パス → ScriptShortcut のみ）もそのまま読める。
    private struct Entry: Codable {
        let keyCode: UInt32
        let modifiers: UInt32
        var bookmark: Data?

        var shortcut: ScriptShortcut { ScriptShortcut(keyCode: keyCode, modifiers: modifiers) }
    }

    /// 読み込み。改名・移動されたスクリプトの割当をブックマークで現在地に付け替えてから返す
    /// （付け替えがあれば保存もし直す）。再走査のたびに呼んでよい（割当は数本・解決は軽い）。
    static func load() -> [String: ScriptShortcut] {
        var entries = readEntries()
        if resolveMoved(&entries) { writeEntries(entries) }
        return entries.mapValues(\.shortcut)
    }

    /// 保存。既存エントリのブックマークは引き継ぎ、新しい割当にはここで取得する。
    static func save(_ map: [String: ScriptShortcut]) {
        let old = readEntries()
        var new: [String: Entry] = [:]
        for (path, shortcut) in map {
            let bookmark = old[path]?.bookmark
                ?? (try? URL(fileURLWithPath: path).bookmarkData())
            new[path] = Entry(keyCode: shortcut.keyCode,
                              modifiers: shortcut.modifiers,
                              bookmark: bookmark)
        }
        writeEntries(new)
    }

    /// 元のパスにファイルが無いエントリをブックマークで解決してキーを付け替える。
    /// ついでに、ブックマーク未取得のエントリ（旧形式からの移行直後）はここで取得する。
    /// 戻り値：保存し直しが必要なら true。
    private static func resolveMoved(_ entries: inout [String: Entry]) -> Bool {
        var changed = false
        for (path, entry) in entries {
            // ゴミ箱の中は「無い」扱い（2026-10-23）。ゴミ箱へ入れても割当の場所は元のまま残し、
            // 「戻す」で元の場所に戻れば下のブックマーク解決でそのまま使える。以前の版でゴミ箱の場所に
            // 付け替わって保存された割当も、ここでは「無い」として扱い、戻されたら元の場所へ付け替える。
            if ScriptItem.isAvailable(path) {
                if entry.bookmark == nil,
                   let bookmark = try? URL(fileURLWithPath: path).bookmarkData() {
                    entries[path]?.bookmark = bookmark
                    changed = true
                }
                continue
            }
            var isStale = false
            guard let bookmark = entry.bookmark,
                  let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &isStale),
                  resolved.path != path,
                  ScriptItem.isAvailable(resolved.path) else {   // ゴミ箱の中へは付け替えない
                // ゴミ箱の中の場所で保存されていて、そのファイルも無い＝ゴミ箱を空にした（もう戻せない）ので割当を消す。
                // 以前の版でゴミ箱の場所に付け替わった割当が、空にした後も「.Trash」として残り続けていた（2026-10-23 実機）。
                // 「戻す」で外へ出た場合は、上のブックマーク解決で元の場所へ付け替わるのでここには来ない。
                if ScriptItem.isInTrash(path) && !FileManager.default.fileExists(atPath: path) {
                    entries[path] = nil
                    changed = true
                }
                continue
            }
            var moved = entry
            if isStale, let fresh = try? resolved.bookmarkData() { moved.bookmark = fresh }
            entries[path] = nil
            entries[resolved.path] = moved   // 同一ファイルの追跡なので衝突は実質起きない（起きたら移動側優先）
            changed = true
        }
        return changed
    }

    /// 割当のファイルが今ある場所（ゴミ箱の中を含む）。割当の場所に無ければブックマークで探す。
    /// 完全に削除された（ゴミ箱を空にした）・見つからない場合は nil（2026-10-23）。
    /// 「見つからない」割当の表示（カードのフォルダ名「ゴミ箱」）とパネルの「Finderに表示」に使う。
    /// 割当の場所は書き換えない（ゴミ箱の中へは付け替えない方針＝`resolveMoved`）。
    static func currentLocation(of path: String) -> URL? {
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        var isStale = false
        guard let bookmark = readEntries()[path]?.bookmark,
              let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// 割当ファイルの状態をまとめて調べる。**メインスレッドから呼ばない**（裏のキューで呼ぶ）。
    /// 応答しないサーバの共有上のファイルがあると、存在確認やブックマーク解決がそこで止まり得るため
    /// （付録B-3(c) の「アプリ切替のたびに固まる」と同型。2026-10-24）。
    static func inspect(_ paths: [String]) -> [String: ShortcutFileState] {
        var states: [String: ShortcutFileState] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let available = ScriptItem.isAvailable(path)
            var missing: ShortcutFileState.MissingReason?
            var foundAt: URL?
            if !available {
                foundAt = currentLocation(of: path)
                if let foundAt, ScriptItem.isInTrash(foundAt.path) {
                    missing = .trash
                } else if let volume = ScriptItem.disconnectedVolumeName(path) {
                    missing = .notConnected(volume: volume)
                } else {
                    missing = .deleted
                }
            }
            states[path] = ShortcutFileState(isAvailable: available,
                                             isAlias: ScriptItem.isAlias(url),
                                             kind: ScriptItem.kind(of: url),
                                             missing: missing,
                                             foundAt: foundAt)
        }
        return states
    }

    private static func readEntries() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func writeEntries(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// キーコード・修飾キーの表示名解決。
nonisolated enum KeyDisplay {

    /// NSEvent の修飾フラグ → Carbon 修飾キー。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// 修飾キーの記号列（macOS 標準の並び ⌃⌥⇧⌘）。
    static func modifierSymbols(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & UInt32(controlKey) != 0 { s += "⌃" }
        if carbon & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbon & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbon & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// F1〜F20。修飾キーなしでも単独で割当を許可するキー。
    static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100,       // F1〜F8
        101, 109, 103, 111, 105, 107, 113,        // F9〜F15
        106, 64, 79, 80, 90,                      // F16〜F20
    ]

    /// テンキーの数字 → 上段の数字（0〜9）。ほかのテンキー（+ * Enter 等）は別のキーのまま。
    private static let keypadToMainRow: [UInt32: UInt32] = [
        UInt32(kVK_ANSI_Keypad0): UInt32(kVK_ANSI_0), UInt32(kVK_ANSI_Keypad1): UInt32(kVK_ANSI_1),
        UInt32(kVK_ANSI_Keypad2): UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_Keypad3): UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_Keypad4): UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_Keypad5): UInt32(kVK_ANSI_5),
        UInt32(kVK_ANSI_Keypad6): UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_Keypad7): UInt32(kVK_ANSI_7),
        UInt32(kVK_ANSI_Keypad8): UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_Keypad9): UInt32(kVK_ANSI_9),
    ]
    private static let mainRowToKeypad = Dictionary(uniqueKeysWithValues: keypadToMainRow.map { ($1, $0) })

    /// テンキーの数字なら、同じ数字の上段のキーコード。
    static func mainRowDigit(for keyCode: UInt32) -> UInt32? { keypadToMainRow[keyCode] }
    /// 上段の数字なら、同じ数字のテンキーのキーコード（ホットキーを両方で登録するため）。
    static func keypadDigit(for keyCode: UInt32) -> UInt32? { mainRowToKeypad[keyCode] }

    /// 文字を持たないキーの表示名（UCKeyTranslate では取れないもの）。
    private static let specialNames: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Carbon 修飾キー → NSEvent の修飾フラグ（メニュー項目のキー表示用）。
    static func cocoaModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        return flags
    }

    /// 文字を持たないキー → メニュー項目の keyEquivalent。
    private static let specialKeyEquivalents: [UInt32: Int] = [
        36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B, 76: 0x03, 117: NSDeleteFunctionKey,
        123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
        126: NSUpArrowFunctionKey, 115: NSHomeFunctionKey, 119: NSEndFunctionKey,
        116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey,
        122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey,
        96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey,
        101: NSF9FunctionKey, 109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
        105: NSF13FunctionKey, 107: NSF14FunctionKey, 113: NSF15FunctionKey, 106: NSF16FunctionKey,
        64: NSF17FunctionKey, 79: NSF18FunctionKey, 80: NSF19FunctionKey, 90: NSF20FunctionKey,
    ]

    /// メニュー項目の keyEquivalent（組み込みショートカットのキー表示。2026-10-30）。文字キーは小文字にする
    /// （大文字は ⇧ 付きと解釈されるため）。求められなければ空文字（キー表示なし）。
    static func menuKeyEquivalent(_ keyCode: UInt32) -> String {
        if let code = specialKeyEquivalents[keyCode], let scalar = Unicode.Scalar(code) {
            return String(Character(scalar))
        }
        let name = keyName(keyCode)
        guard name.count == 1 else { return "" }
        return name.lowercased()
    }

    /// キーコード → 表示名。文字キーは現在のキーボードレイアウトで解決する（JIS/US の記号差を吸収）。
    static func keyName(_ keyCode: UInt32) -> String {
        if let s = specialNames[keyCode] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "key\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
