import AppKit
import Foundation

// MARK: - AppTranslocation（隔離起動の判定）

/// App Translocation（隔離属性付きのアプリを Finder で移動せずに起動したとき、
/// 読み取り専用の一時的な場所から実行される macOS の仕組み）の判定。
/// 共通資料 App-共有資料/AppTranslocation対策.md を参照（Glow Ai の実装をそのまま移植。2026-11-09）。
enum AppTranslocation {
    private static let securityHandle =
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    /// 隔離起動しているか。
    /// `SecTranslocateIsTranslocatedURL` を dlsym で呼び、取得できなければパスで判定する。
    static func isTranslocated(_ url: URL) -> Bool {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        if let handle = securityHandle,
           let sym = dlsym(handle, "SecTranslocateIsTranslocatedURL") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            var isTrans = false
            var err: Unmanaged<CFError>? = nil
            if fn(url as CFURL, &isTrans, &err).boolValue { return isTrans }
            err?.release()   // 失敗時に返る CFError を解放（リーク防止）
        }
        return url.path.contains("/AppTranslocation/")
    }

    /// 隔離起動中のアプリの元の場所。
    /// `SecTranslocateCreateOriginalPathForURL`（公開ヘッダに無い）を dlsym で呼ぶ。取得できなければ nil。
    static func originalURL(of url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = securityHandle,
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var err: Unmanaged<CFError>? = nil
        guard let original = fn(url as CFURL, &err)?.takeRetainedValue() else {
            err?.release()
            return nil
        }
        return original as URL
    }

    /// 元の場所がアプリケーションフォルダ（/Applications または ~/Applications）の中か。
    /// アプリケーションフォルダの中で ZIP を展開した場合などに当たる。
    static func isInApplicationsFolder(_ url: URL) -> Bool {
        let appDirs = FileManager.default.urls(for: .applicationDirectory,
                                               in: [.localDomainMask, .userDomainMask])
        let path = url.standardizedFileURL.path
        return appDirs.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    // MARK: - 案内

    /// 案内のアラートを組み立てる（表示はしない。スナップショット検証でも使う）。
    /// 元の場所がアプリケーションフォルダの中（そこで ZIP を展開した場合など）なら「いったん外へ出して戻す」案内、
    /// 元の場所が分からなければ両方に効く文言にする。
    /// ボタンは「終了」（既定・Return）と「このまま続ける」（Esc）。
    static func makeAlert(originalInApplications: Bool?) -> NSAlert {
        let title: String
        let action: String
        switch originalInApplications {
        case true?:
            title = String(localized: "Move SPAi 4 again in the Finder")
            action = String(localized: "SPAi 4 is in the Applications folder, but it was placed there without being moved in the Finder, for example by unzipping it there. Quit SPAi 4, move it to the Desktop in the Finder, move it back to the Applications folder, and then open it again.")
        case false?:
            title = String(localized: "Move SPAi 4 to the Applications folder")
            action = String(localized: "Quit SPAi 4, move it to the Applications folder in the Finder, and then open it again.")
        case nil:
            title = String(localized: "Move SPAi 4 to the Applications folder")
            action = String(localized: "Quit SPAi 4, move it to the Applications folder in the Finder, and then open it again. If it's already in the Applications folder, move it to the Desktop and back again in the Finder.")
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = [
            String(localized: "SPAi 4 is running from a temporary location because it was opened right after being downloaded."),
            String(localized: "For security, macOS runs apps obtained from the internet from a copy in a temporary location until you move them in the Finder."),
            action,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Quit"))             // 既定（Return）
        let continueButton = alert.addButton(withTitle: String(localized: "Continue Anyway"))
        continueButton.keyEquivalent = "\u{1b}"                           // Esc
        return alert
    }

    /// 隔離起動中なら案内を出す。「終了」が選ばれたら false（呼び出し側で終了する）。
    /// 隔離起動していなければ何も出さずに true。
    static func confirmLaunchIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard isTranslocated(bundleURL) else { return true }
        let inApps = originalURL(of: bundleURL).map { isInApplicationsFolder($0) }
        let alert = makeAlert(originalInApplications: inApps)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
