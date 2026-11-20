import Foundation
import CoreServices
import Combine   // @Published / ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

/// スクリプトの種類。実行方法・アイコン・AppleScript の複数起動確認の要否を決める（2026-10-23）。
nonisolated enum ScriptKind: Sendable, Equatable {
    case javaScript    // .jsx / .js → pid 指定の do javascript
    case appleScript   // .scpt / .applescript / .scptd → osascript
    case applet        // AppleScript アプレット（.app の中に main.scpt）→ 起動。中身は AppleScript
    case app           // ふつうのアプリ（.app）→ 起動するだけ

    /// 送信先 Illustrator を選べない（AppleScript）種類か。複数起動時の確認とアイコンに使う。
    var usesAppleScript: Bool { self == .appleScript || self == .applet }
    /// アプリとして起動する種類か。実行後に Illustrator を前面へ戻さない。
    var isApplication: Bool { self == .applet || self == .app }
}

/// 一覧に載る 1 本のスクリプト。
nonisolated struct ScriptItem: Sendable {
    let url: URL
    let name: String        // 拡張子を除いたファイル名（表示名）
    let groupPath: [String]  // 表示上の階層。先頭は登録フォルダ名、以降はサブフォルダ（例: ["SPAi 4 Scripts", "整列", "上級"]）。
    var isAlias = false      // Finder エイリアス／シンボリックリンク（行のアイコンに矢印バッジ。2026-10-22）
    /// 同じフォルダに同名・拡張子違いのスクリプトがある（名前の後ろに拡張子を淡色で出して見分ける。2026-10-23）。
    var showsExtension = false

    /// 種類（走査時に `kind(of:)` で決める。アプレットの判定はファイルを見るので毎回は計算しない）。
    var kind: ScriptKind = .javaScript
    /// 割当はあるがファイルが無い（ゴミ箱の中を含む）。「ショートカット付きのみ表示」で淡色＋⚠ にして、
    /// 右クリックで解除できるようにする（2026-10-23）。
    var isMissing = false
    /// `isMissing` の割当のファイルが今ある場所（ゴミ箱の中など）。完全に削除されていれば nil。
    /// パネルの右クリック「Finderに表示」に使う（nil ならグレーアウト。2026-10-23）。
    var foundAt: URL?

    /// ゴミ箱の中か（ホームの `.Trash`・各ボリュームの `.Trashes`）。ゴミ箱へ入れる操作も「移動」なので、
    /// ブックマークで追うと割当がゴミ箱の中まで付いて行く。ゴミ箱の中は「無い」として扱う（2026-10-23）。
    nonisolated static func isInTrash(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// 外付けディスク・サーバの共有など（`/Volumes/名前/…`）にあって、そのボリュームが今つながっていなければ
    /// その名前を返す（つながっている・内蔵ディスク上なら nil）。ファイルが無い割当を「削除済み」と
    /// 「名前（未接続）」に分けて示すのに使う（2026-10-23。サーバもあるので「ディスク」とは言わない）。
    nonisolated static func disconnectedVolumeName(_ path: String) -> String? {
        let components = (path as NSString).pathComponents   // ["/", "Volumes", "名前", …]
        guard components.count >= 3, components[1] == "Volumes",
              !FileManager.default.fileExists(atPath: "/Volumes/" + components[2]) else { return nil }
        return components[2]
    }

    /// 実行できる場所にあるか（実在し、ゴミ箱の中ではない）。割当のキー登録・一覧の表示に使う。
    nonisolated static func isAvailable(_ path: String) -> Bool {
        !isInTrash(path) && FileManager.default.fileExists(atPath: path)
    }

    /// AppleScript の拡張子（コンパイル済み／テキスト／バンドル）。`osascript` で実行する（2026-10-23）。
    nonisolated static let appleScriptExtensions: Set<String> = ["scpt", "applescript", "scptd"]

    /// 種類を判定する。拡張子で分け、.app は中に `Contents/Resources/Scripts/main.scpt` があればアプレット
    /// （スクリプトエディタで「アプリケーション」として保存したもの）。エイリアスは実体を見て判定する。
    nonisolated static func kind(of url: URL) -> ScriptKind {
        switch url.pathExtension.lowercased() {
        case let ext where appleScriptExtensions.contains(ext):
            return .appleScript
        case "app":
            let main = resolvedURL(url).appendingPathComponent("Contents/Resources/Scripts/main.scpt")
            return FileManager.default.fileExists(atPath: main.path) ? .applet : .app
        default:
            return .javaScript
        }
    }

    /// Finder エイリアス／シンボリックリンクか。
    nonisolated static func isAlias(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return values?.isAliasFile == true || values?.isSymbolicLink == true
    }

    /// Finder エイリアス／シンボリックリンクを実体へ解決する（それ以外はそのまま返す）。
    /// エイリアスのまま File を do javascript に渡しても Illustrator は実行できない（実機確認・2026-07-07）。
    /// 割当の「元のスクリプト／エイリアス」照合にも使う（2026-10-22）。
    nonisolated static func resolvedURL(_ url: URL) -> URL {
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
           let resolved = try? URL(resolvingAliasFileAt: url) {
            return resolved
        }
        return url.resolvingSymlinksInPath()
    }
}

/// 登録フォルダ（複数可・サブフォルダ含む）を走査してスクリプト（.jsx / .js、AppleScript、.app）を一覧化し、
/// `FSEvents` でフォルダの増減を監視して自動再走査する。
///
/// 仕様書 §7：数十〜100本・階層フォルダ前提。グループ化＋検索で運用する。
/// 本クラスは「走査と監視」に専念し、パネル・パレットへの反映は呼び出し側（AppDelegate）が行う。
/// `ObservableObject` なのは設定画面（SettingsView）が登録フォルダ一覧を直接表示するため。
///
/// 登録フォルダは URL ブックマーク（Finder エイリアス相当）で追跡する（Xojo 版と同じ方針・2026-07-08）。
/// リネーム・移動（同一ボリューム内）に追随し、パスは表示とフォールバック用に併記保存する。
@MainActor
final class ScriptStore: ObservableObject {

    /// 登録フォルダ1件。ブックマークで追跡し、解決できない間は最後に知られたパスを表示に使う。
    nonisolated private struct RootEntry: Sendable {
        var bookmark: Data?   // 取得できなかった場合のみ nil（未接続ボリューム上のフォルダ等）
        var url: URL          // 現在の解決結果（解決できないときは最後に知られた場所）
        var visible = true    // 設定のチェックボックス。false＝パネル・パレットに出さない（2026-10-22）
    }

    /// UserDefaults キー：登録フォルダの配列（各要素は "bookmark": Data ＋ "path": String
    /// ＋ "visible": Bool の辞書。"visible" が無い旧データは表示扱い）。
    private static let bookmarksKey = "SPAi.scriptFolderBookmarks"

    /// 旧キー（パス配列 → さらに前の単一パス）。初回起動時にブックマーク形式へ移行する。
    private static let legacyPathsKey = "SPAi.scriptFolderPaths"
    private static let legacySingleKey = "SPAi.scriptsFolderPath"

    /// 対象拡張子（Illustrator の ExtendScript＋AppleScript。AppleScript は 2026-10-23 追加）。
    /// `.scptd`（バンドル）はパッケージなので、走査ではフォルダとしてではなく1本のスクリプトとして拾われる。
    /// `.app`（アプレット・ふつうのアプリ）も 2026-10-23 に追加。`.scptd` と同じくパッケージなので1本として拾われる。
    nonisolated private static let scriptExtensions = Set(["jsx", "js", "app"]).union(ScriptItem.appleScriptExtensions)

    /// 走査で中に入らないフォルダ名（2026-10-24 ユーザー指定）。スクリプト開発用のフォルダを登録すると、
    /// `node_modules` の数千の .js がスクリプトとして一覧に載ってしまうため。隠しフォルダ（`.git` 等）は
    /// `.skipsHiddenFiles` で元から飛ばしている。
    nonisolated private static let skippedFolderNames: Set<String> = ["node_modules"]

    /// 走査結果が更新されたときに呼ばれる（メインスレッド）。
    var onChange: (() -> Void)?

    /// 現在のスクリプト一覧（グループ→名前でソート済み）。非表示の登録フォルダの分は含まない
    /// （パネルの階層表示・検索パレットはこれを使う）。
    private(set) var items: [ScriptItem] = []

    /// 非表示の登録フォルダも含めた一覧（パネルの「ショートカット付きのみ表示」用。割当は非表示でも効くため）。
    private(set) var allItems: [ScriptItem] = []

    /// 登録フォルダ（設定画面の一覧と同期。`entries` の解決結果）。
    @Published private(set) var rootURLs: [URL]

    /// 非表示にした登録フォルダ（標準化パス）。設定画面のチェックボックスと同期。
    @Published private(set) var hiddenRootPaths: Set<String>

    /// 見当たらない登録フォルダ（標準化パス。ゴミ箱の中を含む）。設定画面の一覧の ⚠ に使う。
    /// 走査のたびに更新して公開する（行の描画時に調べるだけだと、フォルダが消えても一覧が描き直されなかった。2026-10-23）。
    @Published private(set) var missingRootPaths: Set<String> = []

    /// `missingRootPaths` のうち、ゴミ箱の中にあるもの（設定の一覧の状態表示「ゴミ箱」用。2026-10-23）。
    /// 登録の場所はゴミ箱の中へ書き換えないので、今の場所はブックマークで調べる。
    @Published private(set) var trashedRootPaths: Set<String> = []

    private var entries: [RootEntry]

    private var eventStream: FSEventStreamRef?

    /// 走査用のキュー（裏）と、走査中か・走査中に再走査の要求が来たか（2026-10-24）。
    private let scanQueue = DispatchQueue(label: "com.tama-san.SPAi.scan", qos: .utility)
    private var isScanning = false
    private var needsRescan = false

    // MARK: - 初期化

    init() {
        let loaded = Self.loadOrMigrateEntries()
        entries = loaded
        rootURLs = loaded.map(\.url)
        hiddenRootPaths = Self.hiddenPaths(of: loaded)
    }

    private static func hiddenPaths(of entries: [RootEntry]) -> Set<String> {
        Set(entries.filter { !$0.visible }.map { $0.url.standardizedFileURL.path })
    }

    /// 保存済みの登録フォルダ（ブックマーク形式）を読む。無ければ旧キー（パス配列 → 単一パス）から
    /// 移行し、それも無ければ既定 `~/Documents/SPAi 4 Scripts` を初期登録する。
    /// ユーザーが意図的に全削除した空配列は空のまま尊重する。
    private static func loadOrMigrateEntries() -> [RootEntry] {
        let ud = UserDefaults.standard
        if let stored = ud.array(forKey: bookmarksKey) as? [[String: Any]] {
            return stored.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                return RootEntry(bookmark: dict["bookmark"] as? Data,
                                 url: URL(fileURLWithPath: path, isDirectory: true),
                                 visible: dict["visible"] as? Bool ?? true)
            }
        }
        let paths: [String]
        if let saved = ud.stringArray(forKey: legacyPathsKey) {
            paths = saved
        } else if let single = ud.string(forKey: legacySingleKey), !single.isEmpty {
            paths = [single]
        } else {
            paths = [defaultRoot().path]
        }
        return paths.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return RootEntry(bookmark: try? url.bookmarkData(), url: url)
        }
    }

    private static func defaultRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("SPAi 4 Scripts", isDirectory: true)
    }

    // MARK: - 開始 / 停止

    /// 起動時に呼ぶ。既定フォルダが対象なら無ければ作成（初回はサンプルを1本置く）、
    /// ブックマークを解決（前回終了後のリネーム・移動に追随）、走査、監視を開始する。
    func start() {
        ensureDefaultFolderIfRegistered(createSampleIfEmpty: true)
        refreshRoots()
        persistEntries()   // 旧形式からの移行・取得し直したブックマークを確定させる
        rescan()
        startWatching()
    }

    func stop() {
        stopWatching()
    }

    // MARK: - 登録フォルダの管理（設定画面から）

    /// フォルダを登録に追加する（重複は無視）。走査・監視をやり直す。
    func addRoot(_ url: URL) {
        addRoots([url], at: entries.count)
    }

    /// フォルダをまとめて `index` の位置に登録する（設定の一覧へのドロップ。2026-10-25）。
    /// 登録済みのもの・同じフォルダの重複は飛ばす。1つも増えなければ何もしない。
    func addRoots(_ urls: [URL], at index: Int) {
        var adding: [RootEntry] = []
        for url in urls {
            let std = url.standardizedFileURL
            guard !entries.contains(where: { $0.url.standardizedFileURL == std }),
                  !adding.contains(where: { $0.url.standardizedFileURL == std }) else { continue }
            adding.append(RootEntry(bookmark: try? url.bookmarkData(), url: url))
        }
        guard !adding.isEmpty else { return }
        var new = entries
        new.insert(contentsOf: adding, at: min(max(index, 0), new.count))
        setEntries(new)
        rescan()
        startWatching()
    }

    /// フォルダを登録から外す。スクリプト実体には触れない。
    func removeRoot(_ url: URL) {
        let std = url.standardizedFileURL
        setEntries(entries.filter { $0.url.standardizedFileURL != std })
        rescan()
        startWatching()
    }

    /// 登録フォルダの表示/非表示（設定のチェックボックス）。登録・監視はそのままで、一覧から出し入れするだけ。
    func isVisible(_ url: URL) -> Bool {
        !hiddenRootPaths.contains(url.standardizedFileURL.path)
    }

    func setVisible(_ visible: Bool, for url: URL) {
        let std = url.standardizedFileURL
        guard let i = entries.firstIndex(where: { $0.url.standardizedFileURL == std }),
              entries[i].visible != visible else { return }
        var new = entries
        new[i].visible = visible
        setEntries(new)
        rescan()
    }

    /// 登録フォルダの並び替え（設定の一覧のドラッグ。2026-10-24）。パネルの登録フォルダの並びもこの順になる。
    /// 監視するパスは変わらないので監視は張り直さない。
    func moveRoots(fromOffsets source: IndexSet, toOffset destination: Int) {
        // SwiftUI の `move(fromOffsets:toOffset:)` と同じ意味（destination は移動前の配列での挿入位置）。
        // データ側に SwiftUI を持ち込まないよう自前で並べ替える
        let moving = source.map { entries[$0] }
        var new = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        new.insert(contentsOf: moving, at: min(max(insertAt, 0), new.count))
        setEntries(new)
        rescan()
    }

    private func setEntries(_ new: [RootEntry]) {
        entries = new
        rootURLs = new.map(\.url)
        hiddenRootPaths = Self.hiddenPaths(of: new)
        persistEntries()
    }

    private func persistEntries() {
        let arr: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = ["path": entry.url.path, "visible": entry.visible]
            if let bookmark = entry.bookmark { dict["bookmark"] = bookmark }
            return dict
        }
        UserDefaults.standard.set(arr, forKey: Self.bookmarksKey)
    }

    // MARK: - ブックマーク解決（リネーム・移動への追随）

    /// 各登録フォルダのブックマークを解決し直す。場所が変わっていれば `rootURLs` を更新して保存し、
    /// true を返す（呼び出し側は監視を張り直す）。ブックマークが陳腐化（stale）していたら取り直す。
    /// `.withoutUI`・`.withoutMounting`：未接続ボリュームで勝手にマウントダイアログを出さない。
    @discardableResult
    private func refreshRoots() -> Bool {
        var new = entries
        var moved = false
        var needPersist = false

        for i in new.indices {
            // ブックマーク未取得（未接続ボリューム上のフォルダ等）なら、いま取れるようなら取る。
            guard let bookmark = new[i].bookmark else {
                if let fresh = try? new[i].url.bookmarkData() {
                    new[i].bookmark = fresh
                    needPersist = true
                }
                continue
            }
            var isStale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &isStale),
                  // ゴミ箱の中へは追随しない（ゴミ箱の中＝見当たらない。「戻す」で元の場所に戻れば復帰。
                  // ショートカット割当と同じ方針。2026-10-23）
                  !ScriptItem.isInTrash(resolved.path) else { continue }
            if isStale, let fresh = try? resolved.bookmarkData() {
                new[i].bookmark = fresh
                needPersist = true
            }
            if resolved.standardizedFileURL.path != new[i].url.standardizedFileURL.path {
                new[i].url = resolved
                moved = true
            }
        }

        if moved {
            setEntries(new)          // rootURLs 更新＋保存
        } else if needPersist {
            entries = new
            persistEntries()
        }
        return moved
    }

    /// FSEvents から。登録フォルダ自体の移動/リネーム（RootChanged）に追随してから再走査する。
    private func foldersChanged() {
        if refreshRoots() {
            startWatching()   // 監視パスが変わったので張り直す
        }
        rescan()
    }

    // MARK: - フォルダ準備

    /// 既定フォルダ `~/Documents/SPAi 4 Scripts` が登録されている場合のみ、無ければ作る（初回起動の受け皿）。
    /// ユーザーが登録した任意のフォルダは勝手に作らない。
    private func ensureDefaultFolderIfRegistered(createSampleIfEmpty: Bool) {
        let def = Self.defaultRoot().standardizedFileURL
        guard rootURLs.contains(where: { $0.standardizedFileURL == def }) else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: def.path, isDirectory: &isDir) {
            try? fm.createDirectory(at: def, withIntermediateDirectories: true)
            if createSampleIfEmpty {
                let sample = def.appendingPathComponent(String(localized: "Sample - Show Version") + ".jsx")
                let message = String(localized: "SPAi sample")
                let body = #"alert(""# + message + #" → Adobe Illustrator " + app.version);"#
                try? body.write(to: sample, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - 走査

    /// 走査の結果（裏のキューで作り、メインスレッドで反映する）。
    private struct ScanResult: Sendable {
        var items: [ScriptItem]
        var missing: Set<String>
        var trashed: Set<String>
        var hasNetworkRoots: Bool
    }

    /// 登録フォルダにサーバの共有（ローカルでないボリューム）上のものがあるか（直近の走査で判定。2026-10-24）。
    /// サーバの共有では、他の Mac からの追加・変更を FSEvents が知らせない。
    private var hasNetworkRoots = false

    /// サーバの共有上の登録フォルダがあるときだけ再走査する（2026-10-24 ユーザー指定）。パネル・検索パレットを
    /// 開くときと Illustrator が前面に戻ったときに呼ぶ。ローカルだけなら FSEvents で足りるので何もしない。
    /// 走査は裏で行われ、走査中ならまとめられる（`rescan()`）。
    func rescanIfNetworkRoots() {
        if hasNetworkRoots { rescan() }
    }

    /// 登録フォルダすべてを再帰走査して `items` を作り直し、`onChange` を呼ぶ。
    /// groupPath の先頭は登録フォルダの表示名（同名フォルダは親フォルダ名を付けて区別）。
    ///
    /// 走査（フォルダの列挙・ファイルの確認・ブックマーク解決）は裏のキューで行い、結果だけをメインスレッドで反映する
    /// （2026-10-24）。応答しないサーバの共有を登録していると列挙がそこで止まり得るため、メインスレッド（パネル・
    /// ホットキー）を巻き込まない。走査中に呼ばれたら、終わって反映した後にもう一度だけ走査する（要求を積み上げない）。
    func rescan() {
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let roots = rootURLs
        let entries = self.entries
        let names = Self.displayNames(for: roots)
        // 非表示の登録フォルダの表示名（判定は groupPath の先頭で行う——入れ子登録で同じファイルが表示・非表示の
        // 両方のフォルダ経由で載っても、非表示側の行だけが消える）
        let hiddenNames = Set(roots.filter { !isVisible($0) }
            .map { names[$0.standardizedFileURL.path] ?? $0.lastPathComponent })
        scanQueue.async { [weak self] in
            let result = Self.scan(roots: roots, entries: entries, names: names)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isScanning = false
                self.apply(result, hiddenNames: hiddenNames)
                if self.needsRescan {
                    self.needsRescan = false
                    self.rescan()
                }
            }
        }
    }

    private func apply(_ result: ScanResult, hiddenNames: Set<String>) {
        hasNetworkRoots = result.hasNetworkRoots
        if result.missing != missingRootPaths { missingRootPaths = result.missing }
        if result.trashed != trashedRootPaths { trashedRootPaths = result.trashed }
        allItems = result.items
        items = hiddenNames.isEmpty ? result.items
            : result.items.filter { !hiddenNames.contains($0.groupPath.first ?? "") }
        onChange?()
    }

    /// 走査本体。**メインスレッドから呼ばない**（裏のキューで呼ぶ）。
    nonisolated private static func scan(roots: [URL], entries: [RootEntry],
                                         names: [String: String]) -> ScanResult {
        let fm = FileManager.default
        var found: [ScriptItem] = []

        let missing = Set(roots.filter { !rootExists($0) }.map(\.standardizedFileURL.path))
        let trashed = Set(entries.filter { missing.contains($0.url.standardizedFileURL.path) && isInTrash($0) }
            .map(\.url.standardizedFileURL.path))

        for root in roots where !missing.contains(root.standardizedFileURL.path) {
            let rootName = names[root.standardizedFileURL.path] ?? root.lastPathComponent
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: [.isRegularFileKey, .isAliasFileKey, .isSymbolicLinkKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if skippedFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()   // 中に入らない（フォルダ自体もスクリプトではないので載らない）
                    continue
                }
                guard scriptExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let groupPath = [rootName] + relativeGroupPath(of: url, under: root)
                found.append(ScriptItem(url: url, name: name, groupPath: groupPath,
                                        isAlias: ScriptItem.isAlias(url), kind: ScriptItem.kind(of: url)))
            }
        }

        // 登録フォルダは設定の一覧の並び順（2026-10-24 ユーザー指定。それまでは名前順で、設定の一覧とずれた）。
        // その中はグループ階層 → 名前の順で安定ソート（数字混じりも自然順）。
        // 登録フォルダの見分けは groupPath の先頭（表示名）。同じ表示名が重なったら先の順位を使う。
        let rootOrder = Dictionary(roots.enumerated().map {
            (names[$0.element.standardizedFileURL.path] ?? $0.element.lastPathComponent, $0.offset)
        }, uniquingKeysWith: { first, _ in first })
        found.sort { a, b in
            let ga = a.groupPath, gb = b.groupPath
            if let ra = ga.first.flatMap({ rootOrder[$0] }), let rb = gb.first.flatMap({ rootOrder[$0] }), ra != rb {
                return ra < rb
            }
            for i in 0..<min(ga.count, gb.count) {
                if ga[i] != gb[i] {
                    return ga[i].localizedStandardCompare(gb[i]) == .orderedAscending
                }
            }
            if ga.count != gb.count { return ga.count < gb.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        // 同じフォルダに同名・拡張子違いがあれば拡張子を見せる（書き出し.scpt／.applescript／.scptd、.jsx と .js 等）。
        // 入れ子登録で同じファイルが2回載る場合は拡張子も同じなので対象にしない。
        let sameName = Dictionary(grouping: found.indices) {
            found[$0].url.deletingLastPathComponent().path + "/" + found[$0].name
        }
        for indices in sameName.values
        where Set(indices.map { found[$0].url.pathExtension.lowercased() }).count > 1 {
            for i in indices { found[i].showsExtension = true }
        }

        // サーバの共有（ローカルでないボリューム）上の登録フォルダがあるか（見当たらないフォルダは数えない。
        // つながれば didMount で再走査され、そこで判定し直される）
        let hasNetworkRoots = roots.contains { root in
            !missing.contains(root.standardizedFileURL.path)
                && (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        }

        return ScanResult(items: found, missing: missing, trashed: trashed, hasNetworkRoots: hasNetworkRoots)
    }

    /// 登録フォルダが使えるか（フォルダとして実在し、ゴミ箱の中ではない）。以前の版でゴミ箱の中へ追随して
    /// 保存された登録も、ここで「見当たらない」になる。
    nonisolated static func rootExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return !ScriptItem.isInTrash(url.path)
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 登録フォルダが今ゴミ箱の中にあるか。以前の版でゴミ箱の中のパスで保存された登録はそのパスで、
    /// それ以外はブックマークで今の場所を調べる（`.withoutMounting`＝外したボリュームにつなぎに行かない）。
    nonisolated private static func isInTrash(_ entry: RootEntry) -> Bool {
        if ScriptItem.isInTrash(entry.url.path) { return FileManager.default.fileExists(atPath: entry.url.path) }
        var isStale = false
        guard let bookmark = entry.bookmark,
              let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else { return false }
        return ScriptItem.isInTrash(resolved.path) && FileManager.default.fileExists(atPath: resolved.path)
    }

    /// 登録フォルダの表示名（キー＝標準化パス）。同名フォルダが複数あれば「名前 (親フォルダ)」で区別する。
    /// 親の名前まで同じなら、見分けがつくまで上の階層を足す（例「Scripts (共有/Work)」「Scripts (monokano/Work)」。
    /// 2026-10-24 ユーザー指定）。表示名はパネルのフォルダ見出し・表示/非表示・並び順の見分けに使うので、
    /// 重なると2つのフォルダが1つの見出しにまとまり、片方の非表示で両方が消えていた。
    static func displayNames(for roots: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        let groups = Dictionary(grouping: roots.map(\.standardizedFileURL), by: \.lastPathComponent)
        for (base, group) in groups {
            guard group.count > 1 else {
                out[group[0].path] = base
                continue
            }
            // 各フォルダの親の階層（近い順）。フォルダごとに、他のどれとも違う表示になる最小の段数だけ足す
            // （親の名前で見分けがつくものは従来どおり「名前 (親)」のまま）。段数が違えば "/" の数が違うので、
            // 結果どうしが重なることもない
            let ancestors = group.map { url in
                Array(url.deletingLastPathComponent().pathComponents.dropFirst().reversed())   // "/" を除く
            }
            func label(_ i: Int, _ depth: Int) -> String {
                ancestors[i].prefix(depth).reversed().joined(separator: "/")
            }
            for i in group.indices {
                let maxDepth = max(ancestors[i].count, 1)
                var depth = 1
                while depth < maxDepth,
                      group.indices.contains(where: { $0 != i && label($0, depth) == label(i, depth) }) {
                    depth += 1
                }
                let text = label(i, depth)
                out[group[i].path] = text.isEmpty ? base : "\(base) (\(text))"
            }
        }
        return out
    }

    /// url が root 直下から見て属するサブフォルダ階層（ファイル名は含めない）。
    nonisolated private static func relativeGroupPath(of url: URL, under root: URL) -> [String] {
        let rootComps = root.standardizedFileURL.pathComponents
        let fileComps = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard fileComps.count > rootComps.count,
              Array(fileComps.prefix(rootComps.count)) == rootComps else { return [] }
        return Array(fileComps.suffix(from: rootComps.count))
    }

    // MARK: - FSEvents 監視

    private func startWatching() {
        stopWatching()
        guard !rootURLs.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // C コールバック（キャプチャ不可）。info から自身を復元し、メインスレッドで
        // ルートの追随＋再走査を行う。
        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info else { return }
            let store = Unmanaged<ScriptStore>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in store.foldersChanged() }
        }

        let paths = rootURLs.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,  // 0.5 秒でイベントを束ねる（連続保存の連打を抑制）
            flags) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }
}
