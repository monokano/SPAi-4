import AppKit

/// 操作対象の Illustrator インスタンス。**pid で特定**する（複数バージョン同時起動対応の要）。
/// 安定版 2024/2025/2026 は同一 Bundle ID `com.adobe.illustrator` のため、pid でしか一意に狙えない
/// （仕様書 付録B-3(a)。実機で 2026(v30.5.1)/2024(v28.7.10) の撃ち分けを確認済み）。
struct IllustratorTarget {
    let pid: pid_t
    let name: String   // 診断用（例: "Adobe Illustrator 2026"）
}

/// `do javascript` の送信結果。成功なら Illustrator の応答文字列、失敗なら理由（実エラー文字列等）。
enum SendOutcome {
    case success(String)
    case failure(String)
    /// SPAi に Illustrator の操作が許可されていない（オートメーション権限の拒否＝-1743）。
    case notPermitted
    /// 応答待ちのタイムアウト。スクリプトはダイアログで入力待ち等でまだ動いている可能性があるので失敗扱いしない。
    case timedOut
}

/// Illustrator 連携。`do javascript`（`misc`/`DjxM`）を **pid 指定の Apple Event** で送る。
///
/// 送信は専用のシリアルキューで行い、**メインスレッドをブロックしない**（FILL Id で確立したフリーズ対策）。
/// Illustrator がビジーで応答しなくても、固まるのはバックグラウンドのキューだけで、UI・最前面監視は生きたまま。
@MainActor
final class IllustratorController {

    /// 安定版と Beta の Bundle ID。最前面判定・列挙の両方で使う。
    static let bundleIDs: Set<String> = ["com.adobe.illustrator", "com.adobe.illustratorBeta"]

    /// Apple Event 送信用のシリアルキュー。送信順を保証するため 1 本に直列化する。
    private let sendQueue = DispatchQueue(label: "com.tama-san.SPAi.illustrator-ae", qos: .userInitiated)

    /// 応答待ち中の Apple Event の数（メインスレッドで読み書き）。
    private var inFlightCount = 0

    /// 送信が応答待ち中か。ホットキーの多重発火ガードが参照する。
    /// ビジー中の連打を無視しないと、送信側がタイムアウトしてもイベントは Illustrator 側のキューに残り、
    /// 後からまとめて実行される（多重実行事故）。
    var isBusy: Bool { inFlightCount > 0 }

    /// スクリプトファイルの実行が失敗したとき（エラー・送信失敗。タイムアウトは除く）に呼ばれる。
    /// 引数はスクリプト名（拡張子なし）と失敗の中身。AppDelegate が失敗のダイアログ（`FailureAlert`）に配線する（2026-10-23）。
    var onFailure: ((_ name: String, _ failure: ScriptFailure) -> Void)?

    /// 最前面が Illustrator（安定版 or Beta）か。
    var isFrontmost: Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.bundleIDs.contains(bid)
    }

    /// 発火時点で最前面の Illustrator を捕捉する（＝作業中のそのバージョン）。
    /// ホットキーは Illustrator 最前面時のみ発火するので、これが狙うべき pid。
    func captureFrontmostTarget() -> IllustratorTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier, Self.bundleIDs.contains(bid) else { return nil }
        return IllustratorTarget(pid: app.processIdentifier, name: Self.displayName(of: app))
    }

    /// 起動中の Illustrator（安定版＋Beta）の数。AppleScript は送信先を選べず、2つ以上あるとどれに届くか
    /// 分からない（2026-10-23）。⚠️ Beta も数える：Beta もアプリ名が `Adobe Illustrator.app` で、
    /// `tell application "Adobe Illustrator"` は名前で解決されるため、正式版が前面でも版の新しい Beta に
    /// 届いた（実機確認。当初「Beta は別 Bundle ID なので紛れない」としたのは誤り）。
    static var runningCount: Int {
        NSWorkspace.shared.runningApplications.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return bundleIDs.contains(bid)
        }.count
    }

    /// 起動中の Illustrator を1つ返す（メニューからの実行など、最前面が Illustrator でない場面用のフォールバック）。
    func anyRunningTarget() -> IllustratorTarget? {
        NSWorkspace.shared.runningApplications.first {
            guard let bid = $0.bundleIdentifier else { return false }
            return Self.bundleIDs.contains(bid)
        }.map { IllustratorTarget(pid: $0.processIdentifier, name: Self.displayName(of: $0)) }
    }

    // MARK: - 送信（バックグラウンド・シリアルキュー）

    /// 直接オブジェクトの素材（文字列 or File）。`NSAppleEventDescriptor` は Sendable でないため
    /// スレッド間で受け渡せず、Sendable なこの素材を送信キューへ渡してディスクリプタは送信側で組み立てる。
    private enum DirectObject: Sendable {
        case script(String)
        case file(URL)

        var descriptor: NSAppleEventDescriptor {
            switch self {
            case .script(let js): NSAppleEventDescriptor(string: js)
            case .file(let url):  NSAppleEventDescriptor(fileURL: url)
            }
        }
    }

    /// JavaScript コード文字列を `do javascript` で送信する。completion はメインスレッドで呼ばれる
    /// （成功時は結果文字列、失敗時は nil）。
    func run(_ js: String, target: IllustratorTarget, timeout: TimeInterval = 10,
             completion: (@MainActor (String?) -> Void)? = nil) {
        dispatch(directObject: .script(js),
                 target: target, timeout: timeout, completion: completion)
    }

    /// スクリプト**ファイル**（.jsx / .js）を `do javascript` で実行する。
    /// 直接オブジェクトに File を渡すため、文字列エスケープ・巨大テキスト・`#include` の相対解決を気にせず済む。
    /// alert 等でユーザー入力を待つスクリプトがあり得るため、タイムアウトは既定 60 秒。
    func runFile(_ url: URL, target: IllustratorTarget, timeout: TimeInterval = 60,
                 completion: (@MainActor (String?) -> Void)? = nil) {
        dispatch(directObject: .file(url),
                 target: target, timeout: timeout, completion: completion)
    }

    /// 直接オブジェクト（文字列 or File）を受け取り、シリアルキューから送信する共通経路。
    private func dispatch(directObject: DirectObject, target: IllustratorTarget,
                          timeout: TimeInterval, completion: (@MainActor (String?) -> Void)?) {
        inFlightCount += 1
        sendQueue.async {
            let result = Self.sendDoJavaScript(directObject: directObject.descriptor,
                                               to: target, timeout: timeout)
            let isSilent: Bool
            if case .failure(let e) = result {
                isSilent = Self.isNoDocumentError(e, target: target)
            } else {
                isSilent = false
            }
            Task { @MainActor in
                self.inFlightCount -= 1
                switch result {
                case .success(let s):
                    completion?(s)
                case .failure(let e):
                    NSLog("[SPAi] Illustrator script error (%@): %@", target.name, e)
                    if case .file(let url) = directObject, !isSilent {
                        self.onFailure?(url.deletingPathExtension().lastPathComponent, .error(e))
                    }
                    completion?(nil)
                case .notPermitted:
                    NSLog("[SPAi] Not permitted to control Illustrator (%@)", target.name)
                    if case .file(let url) = directObject {
                        // システム設定の一覧に出る名前に合わせる（版ごとの名前ではなく）
                        self.onFailure?(url.deletingPathExtension().lastPathComponent,
                                        .notPermitted(appName: "Adobe Illustrator"))
                    }
                    completion?(nil)
                case .timedOut:
                    NSLog("[SPAi] Illustrator reply timed out (%@)", target.name)
                    completion?(nil)
                }
            }
        }
    }

    // MARK: - pid 指定の do javascript 送信（実装の急所）

    /// Apple Event を組み立てて同期送信する。ブロックしてよいバックグラウンドスレッド（sendQueue）から呼ぶ。
    /// `directObject` は実行する JavaScript 本体（文字列 or File）。
    nonisolated static func sendDoJavaScript(directObject: NSAppleEventDescriptor,
                                             to target: IllustratorTarget,
                                             timeout: TimeInterval) -> SendOutcome {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: osType("misc"),   // Illustrator: misc スイート
            eventID: osType("DjxM"),          // do javascript（miscDjxM）※ do script(dosc) はアクション再生で別物
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))

        event.setParam(directObject, forKeyword: osType("----"))
        // ※ InDesign と違い language パラメータ(doLg) も undo mode(pSUM) も不要。

        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            if let err = reply.paramDescriptor(forKeyword: osType("errs"))?.stringValue, !err.isEmpty {
                return .failure(err)   // Illustrator 側の実エラー文字列（失敗のダイアログにそのまま載せる）
            }
            // エラー文字列なしでエラー番号だけ返る場合も失敗として拾う（§8「握りつぶさない」）。
            // ⚠️ 権限の拒否（-1743）は sendEvent が投げるのではなく、応答の errn で返る（2026-10-24 実機）。
            if let errn = reply.paramDescriptor(forKeyword: osType("errn"))?.int32Value, errn != 0 {
                switch Int(errn) {
                case Int(errAEEventNotPermitted): return .notPermitted
                case Int(errAETimeout):           return .timedOut
                // 番号は String にしてから埋め込む（Int のままだと「-1,743」と桁区切りになる＝実機）
                default:                          return .failure(String(localized: "Error \(String(errn))"))
                }
            }
            let result = reply.paramDescriptor(forKeyword: osType("----"))?.stringValue ?? ""
            return .success(result)
        } catch {
            switch (error as NSError).code {
            case Int(errAETimeout):          return .timedOut
            case Int(errAEEventNotPermitted): return .notPermitted   // 直し方の案内はダイアログ側（FailureAlert）
            default:                          return .failure(error.localizedDescription)
            }
        }
    }

    /// 書類が1つも開いていないときの 1302（No such element。`app.activeDocument` 等）か。Illustrator から直接実行すると
    /// このときは何も表示されないので、SPAi も失敗のダイアログを出さない（ログには残す）。書類が開いているときの 1302
    /// （`pathItems` の範囲外・`getByName` の名前違い等）は Illustrator もダイアログを出す本物のバグなので知らせる（2026-10-25 実機）。
    /// 書類の数は同じ pid に問い合わせる。sendQueue から呼ぶ。問い合わせに失敗したら false（＝知らせる側に倒す）。
    nonisolated static func isNoDocumentError(_ error: String, target: IllustratorTarget) -> Bool {
        guard error.hasPrefix("Error 1302:") else { return false }
        let query = NSAppleEventDescriptor(string: "app.documents.length")
        guard case .success(let count) = sendDoJavaScript(directObject: query, to: target, timeout: 5) else {
            return false
        }
        return count == "0"
    }

    /// 4文字コード→OSType（4文字未満は空白でパディング）。
    nonisolated static func osType(_ s: String) -> OSType {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }

    /// 表示名はインストールフォルダ名から採る（.app 名は全バージョン "Adobe Illustrator.app" で区別不可）。
    nonisolated static func displayName(of app: NSRunningApplication) -> String {
        if let url = app.bundleURL {
            let parent = url.deletingLastPathComponent().lastPathComponent  // 例: "Adobe Illustrator 2026"
            if !parent.isEmpty && parent != "/" { return parent }
        }
        return app.localizedName ?? "Adobe Illustrator"
    }
}
