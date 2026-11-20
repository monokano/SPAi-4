import AppKit

/// スクリプト実行の失敗の中身。オートメーション権限の拒否（-1743）は、ダイアログに
/// 「システム設定を開く」ボタンを出すため、ふつうのエラー文と区別して運ぶ（2026-10-24）。
enum ScriptFailure: Sendable {
    /// Illustrator・osascript 等が返したエラー文字列
    case error(String)
    /// SPAi に送信先アプリの操作が許可されていない。`appName` は分かるときだけ（.jsx＝Illustrator）
    case notPermitted(appName: String?)
}

/// 失敗をダイアログで知らせる（仕様書 §8。成功は無音。2026-10-24）。
///
/// 当初（2026-10-23）は通知センターの通知だったが、最初の許可バナーを閉じる・見落とすと拒否扱いになり、
/// 以後のエラーが無言になった（実機）。Illustrator の「その他のスクリプト…」と同じくダイアログで出す（ユーザー指定）。
/// ダイアログは本文の文字を選択してコピーできる（ユーザー評価。今後も保つ）。
///
/// 対象：スクリプトのエラー（Illustrator・osascript）、送信の失敗、アプリの起動失敗、前の実行中で無視したとき。
/// 「Illustrator が起動していない」「ファイルが無い」は出さない（パネル上部の「Illustrator 未起動」・淡色＋⚠ の行で
/// 分かるため。2026-10-23 ユーザー指定）。
@MainActor
final class FailureAlert {

    static let shared = FailureAlert()

    /// システム設定の「プライバシーとセキュリティ > オートメーション」。
    private static let automationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    private struct Pending {
        let title: String
        let message: String
        /// 「システム設定を開く」ボタンを出す（権限の拒否）
        var offersAutomationSettings = false
    }

    /// 表示待ち。ダイアログ表示中に次の失敗が来ても入れ子にせず、閉じてから順に出す。
    private var queue: [Pending] = []
    private var isShowing = false

    /// ダイアログ表示中か（表示中に割当キー等で実行が重なったとき、呼び出し側が判断に使う）。
    var isPresenting: Bool { isShowing }

    /// スクリプトがエラーで終わった・送信や起動に失敗した。
    func scriptFailed(_ name: String, _ failure: ScriptFailure) {
        let title = String(localized: "“\(name)” failed")
        switch failure {
        case .error(let message):
            show(Pending(title: title, message: message))
        case .notPermitted(let appName):
            let message = appName.map {
                String(localized: "SPAi isn’t allowed to control \($0). Allow SPAi in System Settings > Privacy & Security > Automation.")
            } ?? String(localized: "SPAi isn’t allowed to control this app. Allow SPAi in System Settings > Privacy & Security > Automation.")
            show(Pending(title: title, message: message, offersAutomationSettings: true))
        }
    }

    /// 前のスクリプトの実行中（応答待ち）で、実行を無視した。
    func scriptIgnoredBusy(_ name: String) {
        show(Pending(title: String(localized: "“\(name)” was not run"),
                     message: String(localized: "The previous script is still running. Try again after it finishes.")))
    }

    private func show(_ pending: Pending) {
        NSLog("[SPAi] %@: %@", pending.title, pending.message)
        // Illustrator のエラー文は行区切りが CR（"Error 8: …\rLine: 1\r-> …"）なので改行にそろえる
        queue.append(Pending(title: pending.title,
                             message: pending.message.replacingOccurrences(of: "\r", with: "\n"),
                             offersAutomationSettings: pending.offersAutomationSettings))
        guard !isShowing else { return }
        // 呼び出し元（実行の完了処理など）を終えてから出す
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        guard !isShowing, !queue.isEmpty else { return }
        isShowing = true
        // パネルは key にならない（nonactivating）ので、ダイアログを前面に出すため SPAi を一時的にアクティブにし、
        // 閉じたら元の前面アプリ（ふつうは Illustrator）へ戻す。システム設定を開いたときは戻さない（設定を隠すため）。
        let previous = NSWorkspace.shared.frontmostApplication
        var openedSettings = false
        NSApp.activate(ignoringOtherApps: true)
        while !queue.isEmpty {
            let pending = queue.removeFirst()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = pending.title
            alert.informativeText = pending.message
            if pending.offersAutomationSettings {
                // 既定ボタン（Return）＝設定を開く。直すにはそこへ行くしかないので、迷わせない
                alert.addButton(withTitle: String(localized: "Open System Settings"))
            }
            alert.addButton(withTitle: String(localized: "OK"))
            let response = alert.runModalAboveOtherApps()
            if pending.offersAutomationSettings && response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.automationSettingsURL)
                openedSettings = true
            }
        }
        isShowing = false
        if !openedSettings, let previous,
           previous.processIdentifier != NSRunningApplication.current.processIdentifier {
            previous.activate(options: [])
        }
    }
}

extension NSAlert {
    /// 他アプリ（Illustrator）をアクティブにしても背面に隠れないダイアログとして表示する（2026-10-24 実機）。
    /// 既定のアラートは通常レベル（0）で、Illustrator のドキュメントウインドウをクリックすると背面に回って
    /// 見えなくなり、閉じる手段も見失う。スクリプトパネル（.floating）より上の .modalPanel に置く。
    /// runModal 中もレベルは保たれる（実測）。失敗のダイアログと AppleScript の確認アラートで共用。
    @discardableResult
    func runModalAboveOtherApps() -> NSApplication.ModalResponse {
        window.level = .modalPanel
        window.hidesOnDeactivate = false
        return runModal()
    }
}
