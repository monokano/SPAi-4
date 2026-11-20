import AppKit
import Carbon

/// 組み込みショートカットの動作（設定の「組み込みショートカット」タブ。2026-10-30）。
/// 旧版 SPAi 3 の組み込みのショートカット（プレーンテキストでペースト・パネルの表示）を引き継ぎ、
/// 「スクリプトを検索…」と「クリーンペースト（トリム）」を加えた。どれもキーを変えられ、「なし」にもできる。
nonisolated enum BuiltInAction: String, CaseIterable, Identifiable, Sendable {
    case togglePanel
    case searchPalette
    case cleanPaste
    case cleanPasteTrim

    var id: String { rawValue }

    var label: String {
        switch self {
        case .togglePanel:    return String(localized: "Show Panel")
        case .searchPalette:  return String(localized: "Search Scripts…")
        case .cleanPaste:     return String(localized: "Clean Paste")
        case .cleanPasteTrim: return String(localized: "Clean Paste (Trim)")
        }
    }

    /// 既定のキー。パネル ⇧⌥⌘Space／検索 ⇧⌘Space（仕様 §10）、クリーンペースト ⌥V（旧版と FILL Id と同じ）、
    /// トリム ⇧⌥V（ユーザー指定）。
    var defaultShortcut: ScriptShortcut {
        switch self {
        case .togglePanel:
            return ScriptShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | optionKey | cmdKey))
        case .searchPalette:
            return ScriptShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | cmdKey))
        case .cleanPaste:
            return ScriptShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey))
        case .cleanPasteTrim:
            return ScriptShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | optionKey))
        }
    }

    /// Illustrator そのものが最前面のときだけ登録する（ペースト先が Illustrator のテキストだけなので）。
    /// SPAi 自身が前面のときに登録すると、検索パレットの検索欄などで ⌥V が打てなくなる。
    var needsIllustratorFrontmost: Bool {
        self == .cleanPaste || self == .cleanPasteTrim
    }
}

/// 組み込みショートカットの保存（UserDefaults に JSON。動作 → キー、null＝なし）。
/// 保存に無い動作は既定のキー（今後動作を足したときも既定で始まる）。
nonisolated enum BuiltInShortcutStore {
    private static let key = "SPAi.builtInShortcuts"

    /// 動作 → キー。「なし」の動作は含まない。
    static func load() -> [BuiltInAction: ScriptShortcut] {
        let saved = readSaved() ?? [:]
        var map: [BuiltInAction: ScriptShortcut] = [:]
        for action in BuiltInAction.allCases {
            if let entry = saved[action.rawValue] {
                if let entry { map[action] = entry }   // null＝なし
            } else {
                map[action] = action.defaultShortcut
            }
        }
        return map
    }

    static func save(_ map: [BuiltInAction: ScriptShortcut]) {
        var raw: [String: ScriptShortcut?] = [:]
        for action in BuiltInAction.allCases {
            raw[action.rawValue] = .some(map[action])
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 初めて起動したとき（保存が無いとき）に一度だけ呼ぶ。既定のキーをスクリプトに割当済みなら、その組み込みは
    /// 「なし」で始める（ステップ78 以前から ⌥V などをスクリプトに付けている人の割当を優先する）。
    static func initializeIfNeeded(scriptShortcuts: [String: ScriptShortcut]) {
        guard readSaved() == nil else { return }
        let used = Set(scriptShortcuts.values.map { "\($0.keyCode)-\($0.modifiers)" })
        var map: [BuiltInAction: ScriptShortcut] = [:]
        for action in BuiltInAction.allCases {
            let s = action.defaultShortcut
            if !used.contains("\(s.keyCode)-\(s.modifiers)") { map[action] = s }
        }
        save(map)
    }

    /// 組み込みのどれかが使っているキーか（スクリプトの割当・読み込みでは使えない）。
    static func isUsed(_ shortcut: ScriptShortcut) -> Bool {
        load().values.contains(shortcut)
    }

    private static func readSaved() -> [String: ScriptShortcut?]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: ScriptShortcut?].self, from: data)
    }
}
