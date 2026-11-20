import Foundation

/// 表示モード（メニューバー / Dock / 両方）。FILL Id と同じ3択・既定は「メニューバーとDock」。
enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar    // メニューバーのみ
    case dock       // Dockのみ
    case both       // メニューバーとDock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBar: return String(localized: "Menu Bar Only")
        case .dock:    return String(localized: "Dock Only")
        case .both:    return String(localized: "Menu Bar and Dock")
        }
    }
}

/// パネルのリスト文字サイズ（4段階・既定は「中」＝従来の見た目）。
/// スクリプト名を基準に、アイコンは -3pt、フォルダ行は -2pt で連動させる。
/// 2026-11-11（ユーザー指定）：旧「小」（11pt）の表記を「極小」に変え、12pt の「小」を足した。
/// **「極小」の保存値は旧「小」の `"small"` のまま**（旧「小」を選んでいた人の大きさ 11pt を変えないため）。
/// 新しい「小」の保存値は `"small12"`。
enum ListTextSize: String, CaseIterable, Identifiable {
    case extraSmall = "small"
    case small = "small12"
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extraSmall: return String(localized: "Extra Small")
        case .small:  return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large:  return String(localized: "Large")
        }
    }

    /// スクリプト名（中＝13pt＝従来の .body）。
    var scriptName: CGFloat {
        switch self {
        case .extraSmall: return 11
        case .small:  return 12
        case .medium: return 13
        case .large:  return 15
        }
    }
    /// スクリプト行のアイコン（中＝10pt＝従来の .caption）。
    var scriptIcon: CGFloat { scriptName - 3 }
    /// フォルダ行の名前（中＝11pt＝従来の .subheadline）。
    var folderName: CGFloat { scriptName - 2 }
    /// フォルダ行のアイコン（中＝13pt）。名前より 2pt 大きくして、スクリプト行の書類アイコンと見分けやすくする
    /// （2026-10-28 ユーザー指定。+2／+3／+4pt を ui-snapshot で描き比べて選択。+2pt までは行の高さが変わらない）。
    var folderIcon: CGFloat { folderName + 2 }
    /// フォルダ行の開閉シェブロン（中＝8pt＝従来値）。
    var chevron: CGFloat { scriptName - 5 }
}

extension Notification.Name {
    /// 表示モードが変わった（設定画面 → AppDelegate が activationPolicy と status item を切替）。
    static let displayModeChanged = Notification.Name("SPAi.displayModeChanged")
    /// 「Illustrator が最前面にあるときだけパネルを表示」が変わった（設定画面 → AppDelegate が即時適用）。
    static let onlyWithIllustratorChanged = Notification.Name("SPAi.onlyWithIllustratorChanged")
    /// 設定ウィンドウを開く要求（アプリメニューの「設定…」から）。
    static let openSettingsRequested = Notification.Name("SPAi.openSettingsRequested")
    /// 設定ウィンドウを前面に出す直前（AppDelegate → 設定画面がログイン項目の状態などを読み直す。2026-10-24）。
    static let settingsWindowWillShow = Notification.Name("SPAi.settingsWindowWillShow")
    /// 「パネルのショートカット一覧を名前順に並べる」が変わった（設定画面 → パネルが一覧を並べ直す）。
    static let panelShortcutSortChanged = Notification.Name("SPAi.panelShortcutSortChanged")
}

/// アプリ設定（UserDefaults）。SwiftUI 側は同じキーを `@AppStorage` で参照する。
enum Prefs {

    /// Illustrator が最前面にあるときだけパネルを表示（仕様書 §3-1・§6.4。既定 ON）。
    static let onlyWithIllustratorKey = "SPAi.showPanelOnlyWithIllustrator"

    /// 表示モード（メニューバー / Dock / 両方。仕様書 §4。既定は「メニューバーとDock」）。
    static let displayModeKey = "SPAi.displayMode"

    /// パネルの表示状態（ユーザーの意思としての表示/非表示）。次回起動時に復元する。
    /// 自動隠し（§6.4）中も「表示する意思あり」として true のまま。
    static let panelVisibleKey = "SPAi.panelVisible"

    /// パネルのリスト文字サイズ（ListTextSize の rawValue。既定は「中」）。
    static let listTextSizeKey = "SPAi.listTextSize"

    /// パネルを畳んでいる（ヘッダーのダブルクリック）。次回起動時も畳んだまま開く。
    static let panelCollapsedKey = "SPAi.panelCollapsed"

    /// 畳む前のパネルの高さ（frame）。戻すときに使う。
    static let panelExpandedHeightKey = "SPAi.panelExpandedHeight"

    /// パネルの「ショートカット付きのみ表示」の一覧をキー順に並べる（OFF＝名前順。既定 ON）。
    /// 2026-10-28 に「名前順に並べる」（`SPAi.sortPanelShortcutsByName`・既定 OFF）で追加し、2026-10-30 に
    /// ユーザー指定で向きを反転。旧キーの値は引き継がない（既定のキー順はどちらも同じ並び）。
    static let sortPanelShortcutsByKeyKey = "SPAi.sortPanelShortcutsByKey"

    /// パネルのスクリプト行をシングルクリックで実行する（OFF＝ダブルクリックで実行。既定 OFF。2026-10-30）。
    static let runOnSingleClickKey = "SPAi.runOnSingleClick"

    /// 起動時に一度呼ぶ。`bool(forKey:)` と `@AppStorage` の既定値を一致させる。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            onlyWithIllustratorKey: true,
            sortPanelShortcutsByKeyKey: true,
            runOnSingleClickKey: false,
            displayModeKey: DisplayMode.both.rawValue,
            panelVisibleKey: false,
            listTextSizeKey: ListTextSize.medium.rawValue,
        ])
    }

    static var showPanelOnlyWithIllustrator: Bool {
        get { UserDefaults.standard.bool(forKey: onlyWithIllustratorKey) }
        set { UserDefaults.standard.set(newValue, forKey: onlyWithIllustratorKey) }
    }

    static var displayMode: DisplayMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: displayModeKey),
                  let mode = DisplayMode(rawValue: raw) else { return .both }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey) }
    }

    /// ノッチを考慮した実効モード。ノッチ付きディスプレイでは「メニューバーのみ」を
    /// 「メニューバーとDock」に読み替える（アイコンがノッチの陰に隠れて操作不能になるのを防ぐ）。
    /// 保存値そのものは書き換えない（非破壊。ノッチが外れれば元の設定に戻る）。
    static var resolvedDisplayMode: DisplayMode {
        let mode = displayMode
        if mode == .menuBar && NotchDetector.hasNotchedDisplay { return .both }
        return mode
    }

    static var panelVisible: Bool {
        get { UserDefaults.standard.bool(forKey: panelVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: panelVisibleKey) }
    }

    static var sortPanelShortcutsByKey: Bool {
        UserDefaults.standard.bool(forKey: sortPanelShortcutsByKeyKey)
    }

    static var panelCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: panelCollapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: panelCollapsedKey) }
    }

    /// 未保存なら 0。
    static var panelExpandedHeight: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: panelExpandedHeightKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: panelExpandedHeightKey) }
    }
}
