import SwiftUI
import AppKit

/// SPAi — Illustrator スクリプト実行パネル（Xcode + Swift 版）。
/// 常駐先は設定の「表示モード」（メニューバー / Dock / 両方・仕様書 §4）。実処理は AppDelegate 側で行う。
@main
struct SPAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // ⌘キーを押しながら起動 → 表示モードのみリセット（ノッチでメニューバーアイコンが隠れた場合の救済）
        if NSEvent.modifierFlags.contains(.command) {
            UserDefaults.standard.removeObject(forKey: Prefs.displayModeKey)
            AppDelegate.shouldShowResetAlert = true
        }
    }

    var body: some Scene {
        // 設定ウィンドウは AppDelegate 側で自前の NSWindow として表示する。
        // この Settings シーンは Scene 要件を満たすためのダミー（開かれない）。
        Settings { EmptyView() }
            .commands {
                // アプリメニュー（Dock 表示時）の「設定…」。メニューバー・Dock メニューと同じ窓を開く。
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    }
                    .keyboardShortcut(",")
                }
                // ヘルプメニュー（Dock 表示時）。バンドルしたヘルプブックを自前のウインドウで開く。
                CommandGroup(replacing: .help) {
                    Button("SPAi 4 Help") {
                        appDelegate.openHelp()
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
    }
}
