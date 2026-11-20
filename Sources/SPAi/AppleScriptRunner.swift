import Foundation

/// AppleScript（.scpt / .applescript / .scptd）を `osascript` の別プロセスで実行する（2026-10-23）。
///
/// `NSAppleScript` で SPAi の中から実行すると、長いスクリプトの間メインスレッド（パネル等）が固まり、
/// 止まったスクリプトを強制終了する手段もない。別プロセスなら UI は生きたまま、エラーも stderr で受け取れる。
///
/// ⚠️ AppleScript は送信先 Illustrator を選べない（`tell application "Adobe Illustrator"` は全バージョン共通の
/// Bundle ID に解決され、1インスタンスに収束する＝付録B-3(a)）。複数起動時の確認は呼び出し側（AppDelegate）で行う。
@MainActor
final class AppleScriptRunner {

    /// 多重実行ガードを外すまでの時間。`do javascript` のタイムアウト（60 秒）とそろえる。
    /// 経過後もスクリプト自体は止めない（ダイアログで入力待ちのスクリプトや長い一括処理があり得るため）。
    private static let busyLimit: TimeInterval = 60

    private static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    /// エラー出力を溜める上限。超えた分は古い方（先頭）から捨てる——osascript は `log` の出力を先に、
    /// エラーの行を最後に出すので、ダイアログに要るのは末尾。
    private static let stderrLimit = 16 * 1024

    /// 実行開始ごとに変える。古い実行の終了・ガード解除が新しい実行の状態を消さないようにする。
    private var currentToken: UUID?

    /// 実行中（開始から busyLimit 以内で、まだ終わっていない）か。.jsx の `isBusy` と合わせて多重実行を防ぐ。
    var isBusy: Bool { currentToken != nil }

    /// スクリプトがエラーで終わった・osascript を起動できなかったときに呼ばれる（スクリプト名・失敗の中身）。
    /// ユーザーのキャンセル（-128）は失敗にしない。AppDelegate が失敗のダイアログ（`FailureAlert`）に配線する（2026-10-23）。
    var onFailure: ((_ name: String, _ failure: ScriptFailure) -> Void)?

    /// スクリプトファイルを実行する。終了時（成功・失敗とも）にログを残す。
    func run(_ url: URL) {
        let token = UUID()
        currentToken = token

        let process = Process()
        process.executableURL = Self.osascriptURL
        process.arguments = [url.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice   // 戻り値は使わない（溜まってパイプが詰まるのも防ぐ）

        let name = url.lastPathComponent
        let scriptName = url.deletingPathExtension().lastPathComponent
        let path = url.path

        // エラー出力は実行中から読み続ける（2026-10-24）。終わってからまとめて読むと、出力がパイプの容量（約 64KB）を
        // 超えたところで osascript が書き込み待ちで止まり、終われない（SPAi は終了を待ったまま読まない＝互いに待ち）。
        // 終了（terminationHandler）と出力の終わり（EOF）の両方がそろってから結果を出す。
        let output = TailBuffer(limit: Self.stderrLimit)
        let finished = DispatchGroup()
        finished.enter()   // 出力の終わり
        finished.enter()   // プロセスの終了
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finished.leave()
            } else {
                output.append(data)
            }
        }
        process.terminationHandler = { proc in
            output.status = proc.terminationStatus
            finished.leave()
        }
        finished.notify(queue: .main) { [weak self] in
            let message = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = output.status
            MainActor.assumeIsolated {   // queue: .main で届く
                if status != 0 {
                    NSLog("[SPAi] AppleScript error (%@, status %d): %@", name, status, message)
                    if !message.hasSuffix("(-128)") {   // ユーザーのキャンセル（ダイアログの「キャンセル」等）は失敗ではない
                        self?.onFailure?(scriptName, Self.failure(from: message, path: path))
                    }
                }
                self?.release(token)
            }
        }

        do {
            try process.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            NSLog("[SPAi] Failed to launch osascript (%@): %@", name, error.localizedDescription)
            onFailure?(scriptName, .error(error.localizedDescription))
            release(token)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyLimit) { [weak self] in
            self?.release(token)
        }
    }

    /// osascript のエラー出力（例 "/path/x.scpt: execution error: …（-2753）"）から、ダイアログに要らない
    /// 先頭のパスと "execution error: " を除く。空なら汎用の文にする。
    /// エラー出力には `log` の出力も先に混ざるので、最後の「パス:」で始まるエラーの行から後だけを使う
    /// （2026-10-24。でないと大量の log の下にエラーが埋もれる。log の全体は NSLog に残る）。
    /// テキスト形式（.applescript）で付く文字位置「154:165:」も除く（行番号ではなく読む助けにならない）。
    /// 送信先アプリの操作の拒否（-1743）は権限の失敗として返す（ダイアログに「システム設定を開く」を出す）。
    /// 送信先のアプリ名はエラー文が OS の言語で変わり確実に取り出せないので、名前なしの案内にする。
    private static func failure(from message: String, path: String) -> ScriptFailure {
        var text = message
        if let errorLine = text.range(of: path + ":", options: .backwards) {
            text = String(text[errorLine.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if let position = text.range(of: #"^\d+:\d+:"#, options: .regularExpression) {
            text.removeSubrange(position)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("execution error: ") { text.removeFirst("execution error: ".count) }
        if text.hasSuffix("(-1743)") { return .notPermitted(appName: nil) }
        return .error(text.isEmpty ? String(localized: "The script ended with an error.") : text)
    }

    private func release(_ token: UUID) {
        if currentToken == token { currentToken = nil }
    }
}

/// osascript のエラー出力の末尾 `limit` バイトと終了コードを溜める（2026-10-24）。読み取りは裏のスレッド
/// （パイプの通知・終了ハンドラ）から、取り出しはメインから行うのでロックで守る。
nonisolated final class TailBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private var _status: Int32 = 0

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data = Data(data.suffix(limit))
            truncated = true
        }
    }

    var status: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    /// 溜めた出力の文字列。上限で切ったときは、途中で切れた先頭の行（文字の途中かもしれない）を捨てる。
    var text: String {
        lock.lock(); defer { lock.unlock() }
        var s = String(decoding: data, as: UTF8.self)
        if truncated, let newline = s.firstIndex(of: "\n") { s = String(s[s.index(after: newline)...]) }
        return s
    }
}
