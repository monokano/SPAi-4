import AppKit
import SwiftUI

/// スクリプトパネルの実体。**キーボードは一切受け取らない**（§6.5）。
/// `.nonactivatingPanel` ＋ `canBecomeKey = false` により、クリックしても Illustrator が
/// アクティブ＆キーボード保持のまま。テキスト入力（検索）は検索パレットへ分離した（2026-07-07）。
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// スクリプトパネル（仕様書 §3）の表示制御。
/// - 表示/非表示トグル（ホットキー ⇧⌥⌘Space・メニュー）
/// - 位置・サイズの記憶・復元（`frameAutosaveName`）。初回既定位置のみ画面右下寄せ（中央は作業対象を覆うため避ける）
/// - 「Illustrator が最前面にあるときだけ表示」の自動隠し/再表示（§6.4。手動 orderOut/orderFront）
@MainActor
final class ScriptPanelController: NSObject, NSWindowDelegate {

    private static let autosaveName = "SPAiScriptPanel"

    let viewModel = ScriptPanelViewModel()
    private let panel: NonKeyPanel

    /// §6.4 の自動隠しで隠れている＝Illustrator に戻ったら再表示すべき状態。
    /// ユーザーが自分で閉じた場合（トグル・クローズボタン）は false のまま。
    private(set) var hiddenByAutoHide = false

    /// 起動時の復元待ち：SPAi 自身が最前面になっただけでは出さず、Illustrator そのものが最前面になるまで待つ。
    /// Finder/Dock から起動すると SPAi が最前面＝Illustrator 文脈になり、Illustrator が前にいないのに出てしまうため
    /// （2026-10-28）。`hiddenByAutoHide` が true のときだけ意味を持つ。
    private var waitingForIllustrator = false

    /// 終了処理に入ったら true（`saveVisibilityForRelaunch()` が立てる）。
    /// アプリ終了時に AppKit がパネルを閉じる際も `windowWillClose` が飛んでくるため、
    /// これを見ずに保存すると「表示したまま終了」が常に「非表示」で上書きされてしまう（実機確認・2026-07-09）。
    private var visibilityFrozen = false

    var isVisible: Bool { panel.isVisible }

    /// パネルの現在 frame（ショートカット記録パレットをパネル中央に出すために使う）。
    var frame: NSRect { panel.frame }

    /// スクリプト実行のハンドラ（AppDelegate が注入）。
    var onRun: ((ScriptItem) -> Void)?

    override init() {
        // `.utilityWindow` で小型タイトルバー（閉じるボタンのみ・ズーム/フルスクリーンなし）。
        // Illustrator のパレット群と同じ佇まいの省スペース仕様（§3-1）。
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.title = "SPAi 4"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false   // OFF 運用で Illustrator 操作中も出したまま（§9。true だと詰む）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.minSize
        panel.standardWindowButton(.zoomButton)?.isHidden = true          // 念のため（utility では通常出ない）
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.panel = panel

        super.init()

        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScriptPanelView(vm: viewModel))

        // 実行してもパネルは閉じない（「実行後にウインドウを閉じる」は 2026-10-23 に廃止。閉じるのはトグルとクローズボタン）
        viewModel.onRun = { [weak self] item in self?.onRun?(item) }

        viewModel.onToggleCollapse = { [weak self] in
            guard let self else { return }
            self.setCollapsed(!self.viewModel.isCollapsed)
        }
        viewModel.onHeaderHeightChange = { [weak self] _ in
            guard let self, self.viewModel.isCollapsed else { return }
            self.fitCollapsedHeight()
        }

        // 位置・サイズの記憶・復元。保存が無い初回だけ既定位置に置く。
        let hasSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame \(Self.autosaveName)") != nil
        panel.setFrameAutosaveName(Self.autosaveName)
        if !hasSavedFrame { moveToDefaultPosition() }

        // 畳んだまま終了していたら畳んだ状態で復元する（autosave の frame は畳んだ高さ）。
        // ヘッダーの実測が届いたら fitCollapsedHeight() で高さを合わせ直す。
        if Prefs.panelCollapsed {
            viewModel.isCollapsed = true
            lockCollapsedHeight(panel.contentLayoutRect.height)
        }
    }

    // MARK: - 畳む / 戻す（ヘッダーのダブルクリック）

    private static let minSize = NSSize(width: 220, height: 160)
    /// ヘッダーの実測が無いときの畳んだ内容高さ（11pt 1行＋上下パディング）。
    private static let fallbackHeaderHeight: CGFloat = 21

    /// 畳む＝リストと下部バーを隠し、タイトルバー＋ヘッダー1行の高さにする。戻す＝畳む前の高さへ。
    /// どちらも上端を固定して下側を伸縮させる（ヘッダーの位置が動かないように）。
    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != viewModel.isCollapsed else { return }
        if collapsed {
            Prefs.panelExpandedHeight = panel.frame.height
            viewModel.isCollapsed = true
            fitCollapsedHeight()
        } else {
            viewModel.isCollapsed = false
            panel.minSize = Self.minSize
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
            let saved = Prefs.panelExpandedHeight
            setFrameHeightKeepingTop(saved > 0 ? max(saved, Self.minSize.height) : 460)
        }
        Prefs.panelCollapsed = collapsed
    }

    /// 畳んだ状態の高さをヘッダーの実測値に合わせる。
    private func fitCollapsedHeight() {
        lockCollapsedHeight(viewModel.headerHeight ?? Self.fallbackHeaderHeight)
    }

    /// 内容高さを固定する（幅だけリサイズ可）。
    private func lockCollapsedHeight(_ contentHeight: CGFloat) {
        let frameHeight = panel.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: panel.frame.width, height: contentHeight)).height
        // 先に制約を外してから縮める（minSize 160 が残っていると縮まない）。
        panel.minSize = NSSize(width: Self.minSize.width, height: 0)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setFrameHeightKeepingTop(frameHeight)
        panel.minSize = NSSize(width: Self.minSize.width, height: frameHeight)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frameHeight)
    }

    private func setFrameHeightKeepingTop(_ height: CGFloat) {
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// applicationWillTerminate から呼ぶ後始末。
    func teardown() {
        panel.orderOut(nil)
    }

    // MARK: - 表示 / 非表示

    /// ホットキー ⇧⌥⌘Space・メニューからのトグル。
    func toggle() {
        if panel.isVisible { hideManually() } else { show() }
    }

    /// パネルを表示する。キーボードフォーカスは決して取らない（`canBecomeKey = false`）。
    func show() {
        hiddenByAutoHide = false
        waitingForIllustrator = false
        Prefs.panelVisible = true    // 次回起動時の復元用（ユーザーの意思としての「表示」）
        panel.orderFrontRegardless()
    }

    /// ユーザー操作による非表示（トグル）。自動再表示の対象にしない。
    func hideManually() {
        hiddenByAutoHide = false
        waitingForIllustrator = false
        Prefs.panelVisible = false   // 次回起動時の復元用（ユーザーの意思としての「非表示」）
        panel.orderOut(nil)
    }

    /// 起動時に前回の表示状態を復元する（AppDelegate が呼ぶ）。
    /// 「Illustrator が最前面にあるときだけ表示」ON でいま Illustrator そのものが最前面でなければ、
    /// すぐには出さず自動再表示待ちにする（Illustrator へ切り替えた時点で出る。§6.4 と同じ経路）。
    /// 判定に Illustrator 文脈（SPAi 自身の最前面を含む）を使わないこと：起動直後は SPAi が最前面になるため。
    func restoreVisibilityAtLaunch(illustratorFrontmost: Bool) {
        guard Prefs.panelVisible else { return }
        if !Prefs.showPanelOnlyWithIllustrator || illustratorFrontmost {
            show()
        } else {
            hiddenByAutoHide = true
            waitingForIllustrator = true
        }
    }

    /// 終了開始の時点（applicationShouldTerminate）で呼ぶ。この瞬間の表示状態を確定保存する
    /// （自動隠し中は「表示する意思あり」として表示扱い）。以後、終了処理で AppKit がパネルを
    /// 閉じて `windowWillClose` が飛んできても上書きさせない。
    func saveVisibilityForRelaunch() {
        Prefs.panelVisible = panel.isVisible || hiddenByAutoHide
        visibilityFrozen = true
    }

    /// Illustrator 以外へ切り替わったときの自動隠し（設定 ON 時に AppDelegate が呼ぶ。§6.4）。
    func autoHide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        hiddenByAutoHide = true
    }

    /// Illustrator（または SPAi 自身）へ戻ったときの自動再表示（§6.4）。
    /// 起動時の復元待ちのあいだは、Illustrator そのものが最前面のときだけ出す。
    func autoShowIfNeeded(illustratorFrontmost: Bool = true) {
        guard hiddenByAutoHide else { return }
        if waitingForIllustrator && !illustratorFrontmost { return }
        hiddenByAutoHide = false
        waitingForIllustrator = false
        panel.orderFrontRegardless()
    }

    /// クローズボタンで閉じられたとき（close() 経由）。ユーザーの意思による非表示として扱う。
    /// ただしアプリ終了処理で AppKit が閉じるときにもここへ来るので、終了開始後は保存しない
    /// （`saveVisibilityForRelaunch()` が確定させた値を守る）。
    func windowWillClose(_ notification: Notification) {
        hiddenByAutoHide = false
        waitingForIllustrator = false
        if !visibilityFrozen { Prefs.panelVisible = false }
    }

    // MARK: - 初回の既定位置

    /// 位置記憶が無い初回のみ：マウスのあるスクリーン（＝作業中のスクリーン）の右下寄せ。
    /// 中央は実行対象のアートワークを覆うため避ける（仕様書 §0-1・§10）。
    private func moveToDefaultPosition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 40,
                             y: visible.minY + 40)
        panel.setFrameOrigin(origin)
    }
}
