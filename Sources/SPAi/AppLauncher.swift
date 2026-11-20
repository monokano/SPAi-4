import AppKit

/// `.app`（AppleScript アプレット・ふつうのアプリ）を起動する（2026-10-23）。Finder でのダブルクリックと同じ
/// `NSWorkspace.openApplication`。起動したアプリが前面に来る（呼び出し側は Illustrator を前面に戻さない）。
///
/// アプレットは中身が AppleScript で Illustrator へ命令を送るので、`.scpt` と同じく多重実行ガードを掛ける
/// （終了まで、ただし 60 秒で解除）。ふつうのアプリは起動したまま使うことが多く、Illustrator への命令とも
/// 限らないのでガードしない（掛けると、起動中のあいだ他のスクリプトを実行できなくなる）。
///
/// ⚠️ 起動中のアプリをもう一度開いても前面に出るだけで、アプレットの処理は再実行されない（macOS の仕様）。
@MainActor
final class AppLauncher {

    /// 多重実行ガードを外すまでの時間（`do javascript`・osascript とそろえる）。
    private static let busyLimit: TimeInterval = 60

    /// ガード中のアプレット（実行ごとのトークン）。古い実行の終了が新しい実行の状態を消さないようにする。
    private var currentToken: UUID?
    private var terminationObserver: NSObjectProtocol?

    /// アプレットの実行中（開始から busyLimit 以内で、まだ終わっていない）か。
    var isBusy: Bool { currentToken != nil }

    /// 起動に失敗したときに呼ばれる（アプリ名・エラー文字列）。AppDelegate が失敗のダイアログ（`FailureAlert`）に配線する（2026-10-23）。
    /// 起動後のエラーはアプレット自身がダイアログで出すので扱わない。
    var onFailure: ((_ name: String, _ failure: ScriptFailure) -> Void)?

    func launch(_ url: URL, guardsUntilExit: Bool) {
        let token = UUID()
        if guardsUntilExit {
            currentToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyLimit) { [weak self] in
                self?.release(token)
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let name = url.lastPathComponent
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            let pid = app?.processIdentifier
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let message {
                    NSLog("[SPAi] Failed to open app (%@): %@", name, message)
                    self.onFailure?(url.deletingPathExtension().lastPathComponent, .error(message))
                    self.release(token)
                    return
                }
                guard guardsUntilExit, let pid else { return }
                self.releaseWhenTerminated(pid: pid, token: token)
            }
        }
    }

    /// 起動したアプレットの終了でガードを外す（既に終わっていれば即時）。
    private func releaseWhenTerminated(pid: pid_t, token: UUID) {
        guard currentToken == token else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            release(token)
            return
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let ended = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            guard ended == pid else { return }
            MainActor.assumeIsolated { self?.release(token) }   // queue: .main で届く
        }
    }

    private func release(_ token: UUID) {
        guard currentToken == token else { return }
        currentToken = nil
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminationObserver = nil
        }
    }
}
