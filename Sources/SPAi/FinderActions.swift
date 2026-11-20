import AppKit

/// Finder での表示（パネルの右クリックと設定の登録フォルダ一覧の行のボタンで共用。2026-10-22）。
/// フォルダを開く `open` は、設定の一覧のダブルクリックを廃止したので削除した（2026-11-17）。
enum FinderActions {
    /// Finder で選択表示する（親フォルダのウインドウで対象を選択）。
    /// `activateFileViewerSelecting` は選択するだけで Finder をアクティブにしないため、
    /// Illustrator が最前面だと背後に隠れて見えない → Finder を明示的に前面化する（2026-07-09）。
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        bringFinderToFront()
    }

    /// ⚠️ `NSRunningApplication.activate()` は macOS 14+ の協調型 activation で
    /// 「非アクティブな SPAi からの要求」として却下される（実機確認）。Launch Services への
    /// 起動要求（`open -a Finder` 相当）なら前面化が許可されるので、そちらを使う。
    private static func bringFinderToFront() {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: finderURL, configuration: config)
    }
}
