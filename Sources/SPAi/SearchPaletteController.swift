import AppKit
import SwiftUI

/// 検索パレットの実体。表示中はキーボードを持つことが期待される道具なので `canBecomeKey = true`。
/// `.nonactivatingPanel` なので、key になっても Illustrator はアプリレベルでアクティブのまま（Spotlight 挙動）。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// ズーム不可（タイトルバーのダブルクリックでも拡大しない）。緑ボタンのグレーアウトは init 側で
    /// ボタンを直接無効化する（isZoomable だけではボタンは有効のまま＝実測 2026-10-21）。
    override var isZoomable: Bool { false }
}

/// 検索パレット（仕様書 §3B）。⇧⌘Space → 即・検索欄フォーカス → 打つ → ↑↓ → **Enter で実行して閉じる**。
/// Esc・外側クリック（resignKey）でも閉じる。**閉じれば key は自動的に Illustrator へ戻る**ので、
/// パネル同居時代に必要だった「key を手放す」ハック（orderOut→出し直し）は不要。
/// 表示位置はユーザーが動かした位置を記憶・復元する（画面中央固定にはしない。§0-1）。
@MainActor
final class SearchPaletteController: NSObject, NSWindowDelegate {

    private static let autosaveName = "SPAiSearchPalette"

    let viewModel = SearchPaletteViewModel()
    private let panel: KeyablePanel
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    /// スクリプト実行のハンドラ（AppDelegate が注入）。
    var onRun: ((ScriptItem) -> Void)?

    override init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.title = String(localized: "Search Scripts")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 240)
        panel.standardWindowButton(.zoomButton)?.isEnabled = false   // 緑ボタンをグレーアウト（2026-10-21 ユーザー指定）
        self.panel = panel

        super.init()

        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchPaletteView(vm: viewModel))

        viewModel.onRun = { [weak self] item in
            guard let self else { return }
            self.onRun?(item)
            self.close()   // 実行したら必ず閉じる（§3B。「そういうもの」として迷いを生まない）
        }

        // 位置・サイズの記憶・復元。保存が無い初回だけ既定位置に置く。
        let hasSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame \(Self.autosaveName)") != nil
        panel.setFrameAutosaveName(Self.autosaveName)
        if !hasSavedFrame { moveToDefaultPosition() }

        installKeyMonitor()
    }

    /// applicationWillTerminate から呼ぶ後始末。
    func teardown() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        panel.orderOut(nil)
    }

    // MARK: - 表示 / 非表示

    /// ホットキー ⇧⌘Space からのトグル（表示中にもう一度押すと閉じる）。
    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    /// 表示して検索欄へ即フォーカス。検索は毎回クリアして先頭選択から。
    func show() {
        viewModel.prepareForShow()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 閉じる（実行後・Esc・外側クリック・トグル）。key はアクティブアプリ＝Illustrator へ自動で戻る。
    func close() {
        panel.orderOut(nil)
    }

    /// 外側クリックや他アプリへの切替で key を失ったら閉じる（Spotlight 挙動）。
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - キーボード操作

    /// ↑↓・Enter・Esc。検索欄にフォーカスを置いたままリストを操作できるよう、ローカルモニタで先取りする。
    /// **IME の変換中（marked text あり）は一切奪わない**——奪うと日本語変換の確定 Return が
    /// スクリプト実行に化け、↑↓ の候補選択・Esc の変換取り消しも壊れる（§6.5。実機で確認済み）。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event   // 変換中：Return=確定、↑↓=候補選択、Esc=取り消し（IME に渡す）
            }
            switch event.keyCode {
            case 53:   // Esc
                self.close()
                return nil
            case 126:  // ↑
                self.viewModel.moveSelection(-1)
                return nil
            case 125:  // ↓
                self.viewModel.moveSelection(+1)
                return nil
            case 36, 76:  // Return / Enter（テンキー）
                self.viewModel.runSelected()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - 初回の既定位置

    /// 位置記憶が無い初回のみ：マウスのあるスクリーンの右下寄せ（パネルの既定位置より少し上）。
    /// 中央は実行対象のアートワークを覆うため避ける（§0-1）。
    private func moveToDefaultPosition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 40,
                             y: visible.minY + 160)
        panel.setFrameOrigin(origin)
    }
}
