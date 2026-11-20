import Foundation
import AppKit
import SwiftUI
import Combine   // @Published / ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

/// パネル上部に出す送信先 Illustrator の表示情報（仕様書 §3-1）。
/// AppDelegate が最前面監視（§6.2 の pid 持ち回り）から更新する。nil は「Illustrator 未起動」。
struct PanelTargetInfo {
    let icon: NSImage?
    let label: String   // 例 "Illustrator 2026 (30.5.1)"
}

/// パネルの一覧に表示する1行。フォルダ見出し行とスクリプト行の2種。
struct PanelRow: Identifiable {
    enum Kind {
        case folder(name: String)
        case script(ScriptItem)
    }
    /// フォルダ: "d:表示階層"、スクリプト: "s:表示階層/名前"（フィルタ表示ではフルパス）。
    /// 同一ファイルが複数の登録フォルダ経由で重複して載ることがある（親フォルダとその中の
    /// サブフォルダを両方登録している場合）ため、パスではなく表示階層で一意にする。
    /// id が重複すると SwiftUI の ForEach が空行を描く（実機で確認・2026-07-09）。
    let id: String
    let kind: Kind
    let level: Int          // インデント段数
}

/// スクリプトパネル（仕様書 §3）の状態。常に階層表示＋フォルダの展開/折りたたみ。
/// インクリメンタル検索は検索パレット（§3B・`SearchPaletteViewModel`）に分離した（2026-07-07）。
/// パネルはキーボードを一切受け取らないマウスの道具（クリック選択＋ダブルクリック実行＋クリック開閉）。
@MainActor
final class ScriptPanelViewModel: ObservableObject {

    @Published private(set) var rows: [PanelRow] = []
    @Published var selectedID: String?
    @Published private(set) var targetInfo: PanelTargetInfo?
    /// スクリプトのフルパス → 割当キー（行末の淡色表示用。AppDelegate が ShortcutStore から更新）。
    @Published private(set) var shortcuts: [String: ScriptShortcut] = [:]

    /// スクリプト実行のハンドラ（コントローラが注入）。
    var onRun: ((ScriptItem) -> Void)?
    /// ショートカット割当の開始（AppDelegate が記録パレットを出す）。
    var onAssignShortcut: ((ScriptItem) -> Void)?
    /// ショートカット解除（コンテキストメニューから）。
    var onClearShortcut: ((ScriptItem) -> Void)?
    /// 検索パレットを開く（ヘッダーの虫眼鏡ボタン。AppDelegate が注入）。
    var onOpenSearch: (() -> Void)?
    /// 設定ウインドウを開く（ヘッダーの歯車ボタン。AppDelegate が注入）。
    var onOpenSettings: (() -> Void)?

    /// パネルを畳んでいる（ヘッダー1行だけ表示）。コントローラが設定する。
    @Published var isCollapsed = false
    /// 畳む／戻す要求（ヘッダーのダブルクリック。コントローラが注入）。
    var onToggleCollapse: (() -> Void)?
    /// ヘッダーの実測高さが変わった（畳んだ高さの算出用。コントローラが注入）。
    var onHeaderHeightChange: ((CGFloat) -> Void)?
    /// ヘッダーの実測高さ（未計測なら nil）。
    private(set) var headerHeight: CGFloat?

    private var allItems: [ScriptItem] = []
    /// 非表示の登録フォルダも含めた一覧（「ショートカット付きのみ表示」用。割当は非表示でも効くので、
    /// どこで効いているかをここで確かめられるようにする＝2026-10-22 ユーザー指定）。
    private var filterItems: [ScriptItem] = []

    /// 展開中フォルダの id 集合（"d:階層/パス"）。**既定は畳んだ状態**——膨大な本数をフォルダで
    /// 分類している環境で全展開は非現実的なため、展開した分だけを記憶する（UserDefaults）。
    private var expandedIDs: Set<String>
    private static let expandedKey = "SPAi.panelExpandedFolders"

    /// 「ショートカット付きのみ表示」フィルタ（§3-1）。ON のあいだは割当済みスクリプトを
    /// フラットに一覧する（登録フォルダ外へ移動した割当済みスクリプトも載る）。状態は永続化。
    @Published var showOnlyShortcuts: Bool {
        didSet {
            guard showOnlyShortcuts != oldValue else { return }
            UserDefaults.standard.set(showOnlyShortcuts, forKey: Self.showOnlyShortcutsKey)
            rebuildRows()
        }
    }
    private static let showOnlyShortcutsKey = "SPAi.panelShowOnlyShortcuts"

    private var cancellables = Set<AnyCancellable>()

    init() {
        expandedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
        showOnlyShortcuts = UserDefaults.standard.bool(forKey: Self.showOnlyShortcutsKey)
        // 設定の「キー順に並べる」の切替をすぐ一覧に反映する（2026-10-28）
        NotificationCenter.default.publisher(for: .panelShortcutSortChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.showOnlyShortcuts else { return }
                    self.rebuildRows()
                }
            }
            .store(in: &cancellables)
    }

    var scriptCount: Int { allItems.count }

    /// 下部バーの本数表示。フィルタ中は割当数を出す。
    var countLabel: String {
        showOnlyShortcuts
            ? String(localized: "\(rows.count) assigned")
            : String(localized: "\(scriptCount) scripts")
    }

    /// ScriptStore の走査結果を反映する（FSEvents の自動更新もここに来る）。
    /// `items` は表示中の登録フォルダの分、`includingHidden` は非表示の登録フォルダも含めた分。
    func update(items: [ScriptItem], includingHidden: [ScriptItem]) {
        allItems = items
        filterItems = includingHidden
        rebuildRows()
    }

    func requestToggleCollapse() {
        onToggleCollapse?()
    }

    func reportHeaderHeight(_ height: CGFloat) {
        guard height > 0, height != headerHeight else { return }
        headerHeight = height
        onHeaderHeightChange?(height)
    }

    /// 送信先 Illustrator の表示を更新する（AppDelegate の最前面監視から）。
    func updateTarget(_ info: PanelTargetInfo?) {
        targetInfo = info
    }

    /// ショートカット割当の一覧を更新する（AppDelegate が保存と同時に呼ぶ）。
    /// フィルタ表示中は行そのもの（載る/載らない）が変わるので組み直す。
    func updateShortcuts(_ map: [String: ScriptShortcut]) {
        shortcuts = map
        if showOnlyShortcuts { rebuildRows() }
    }

    /// 割当ファイルの状態（AppDelegate が裏のキューで調べた結果。2026-10-24）。
    /// 「ショートカット付きのみ表示」の淡色＋⚠・Finderに表示の可否はこれで決め、行の組み立てではファイルを確かめない。
    private var shortcutStates: [String: ShortcutFileState] = [:]

    func updateShortcutStates(_ states: [String: ShortcutFileState]) {
        shortcutStates = states
        if showOnlyShortcuts { rebuildRows() }
    }

    func shortcutLabel(for item: ScriptItem) -> String? {
        shortcuts[item.url.path]?.display
    }

    func requestShortcut(_ item: ScriptItem) {
        onAssignShortcut?(item)
    }

    func clearShortcut(_ item: ScriptItem) {
        onClearShortcut?(item)
    }

    // MARK: - フォルダの展開 / 折りたたみ

    func isExpanded(_ folderID: String) -> Bool {
        expandedIDs.contains(folderID)
    }

    /// フォルダ行クリックで開閉。`deep: true`（⌥クリック）は配下のフォルダごと一括開閉。
    func toggleFolder(_ folderID: String, deep: Bool = false) {
        let targets = deep ? descendantFolderIDs(of: folderID) : [folderID]
        if expandedIDs.contains(folderID) {
            expandedIDs.subtract(targets)
        } else {
            expandedIDs.formUnion(targets)
        }
        UserDefaults.standard.set(Array(expandedIDs), forKey: Self.expandedKey)
        rebuildRows()
    }

    /// folderID 自身とその配下の全フォルダ id（⌥クリックの一括開閉用）。
    private func descendantFolderIDs(of folderID: String) -> Set<String> {
        let path = String(folderID.dropFirst(2))   // "d:" を外す
        var out: Set<String> = [folderID]
        for item in allItems {
            let gp = item.groupPath
            for lvl in 0..<gp.count {
                let idPath = gp.prefix(lvl + 1).joined(separator: "/")
                if idPath == path || idPath.hasPrefix(path + "/") {
                    out.insert("d:\(idPath)")
                }
            }
        }
        return out
    }

    // MARK: - 実行

    /// 実行の共通経路（ダブルクリック・コンテキストメニュー）。MRU を更新してハンドラへ渡す。
    func run(_ item: ScriptItem) {
        MRUStore.touch(item.url.path)
        onRun?(item)
    }

    /// シングルクリック実行で最後に実行した行と時刻（ダブルクリックの2クリック目で二重に実行しないため）。
    private var lastClickRun: (id: String, time: TimeInterval)?

    /// シングルクリック実行（設定「スクリプトを実行」＝シングルクリック）。同じ行へのクリックが
    /// ダブルクリックの間隔内に続いたら無視する。でないとダブルクリックで2回実行され、2回目は
    /// 「前の実行中」として失敗のダイアログが出てしまう。
    func runOnClick(_ item: ScriptItem, rowID: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClickRun, last.id == rowID, now - last.time < NSEvent.doubleClickInterval {
            lastClickRun = (rowID, now)   // 3連打なども続けて無視する
            return
        }
        lastClickRun = (rowID, now)
        run(item)
    }

    // MARK: - 編集

    /// 既定のアプリで開く（パネルの右クリック「編集」＝Finder でのダブルクリックと同じ。2026-11-18）。
    func openInDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Finder に表示

    /// Finder で選択表示する（スクリプト・フォルダ共通のコンテキストメニュー）。
    /// Finder の前面化を含む実処理は `FinderActions`（設定の登録フォルダ一覧と共用）。
    func revealInFinder(_ url: URL) {
        FinderActions.reveal(url)
    }

    /// フォルダ行の実 URL を割り出す。フォルダ行は表示階層（groupPath。先頭は登録フォルダ表示名で
    /// 実フォルダ名と異なることがある）しか持たないため、配下のスクリプトの URL から
    /// 「階層の深さぶんだけ親へ遡る」ことで実パスを得る。
    func folderURL(for folderID: String) -> URL? {
        let path = String(folderID.dropFirst(2))   // "d:" を外す
        let comps = path.components(separatedBy: "/")
        for item in allItems
        where item.groupPath.count >= comps.count
            && Array(item.groupPath.prefix(comps.count)) == comps {
            var url = item.url.deletingLastPathComponent()
            for _ in 0..<(item.groupPath.count - comps.count) {
                url = url.deletingLastPathComponent()
            }
            return url
        }
        return nil
    }

    // MARK: - 行の組み立て

    private func rebuildRows() {
        rows = showOnlyShortcuts
            ? Self.shortcutRows(filterItems, shortcuts: shortcuts, states: shortcutStates,
                                byKey: Prefs.sortPanelShortcutsByKey)
            : Self.treeRows(allItems, expanded: expandedIDs)
        if let sel = selectedID, !rows.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
        // expandedIDs は掃除しない：フォルダが一時的に消えても（外付け HDD 未接続等）記憶を保つ。
    }

    /// 「ショートカット付きのみ表示」：割当済みスクリプトをフラット一覧にする。並びは `byKey` で
    /// ショートカット順（記録カードの一覧と同じ。既定）か名前順（設定「名前順に並べる」ON。2026-10-28）。
    /// 走査結果（登録フォルダ内）に無いパスでも、割当があれば載せる
    /// （ブックマーク追随で割当が生きたまま登録フォルダ外へ移動したスクリプトの受け皿）。
    /// ファイルが無い（ゴミ箱の中を含む）割当も `isMissing` で載せ、淡色＋⚠ で示して右クリックで解除できるようにする
    /// （2026-10-23。それまでは無いものは出さず、キーだけ取られたまま消す入口が無かった）。
    /// ファイルの有無などは裏で調べた `states` を使い、ここではファイルを確かめない（2026-10-24。まだ調べていない割当は
    /// 使える扱い）。
    private static func shortcutRows(_ items: [ScriptItem],
                                     shortcuts: [String: ScriptShortcut],
                                     states: [String: ShortcutFileState],
                                     byKey: Bool) -> [PanelRow] {
        var byPath: [String: ScriptItem] = [:]
        for item in items { byPath[item.url.path] = item }

        var scripts: [ScriptItem] = []
        for path in shortcuts.keys {
            let state = states[path]
            let available = state?.isAvailable ?? true
            // 走査結果にあっても有無の確認結果を優先する（取り外したボリューム上のファイルが、再走査されるまで走査結果に残る。2026-10-23）
            if let item = byPath[path], available {
                scripts.append(item)
            } else {
                let url = URL(fileURLWithPath: path)
                scripts.append(ScriptItem(url: url,
                                          name: url.deletingPathExtension().lastPathComponent,
                                          groupPath: [],
                                          isAlias: state?.isAlias ?? false, kind: state?.kind ?? .javaScript,
                                          isMissing: !available,
                                          foundAt: state?.foundAt))
            }
        }
        scripts.sort { a, b in
            if byKey, let ka = shortcuts[a.url.path], let kb = shortcuts[b.url.path], ka != kb {
                return ScriptShortcut.keyOrder(ka, kb)
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return scripts.map { PanelRow(id: $0.url.path, kind: .script($0), level: 0) }
    }

    /// 階層表示。items は「グループ→名前」でソート済み（ScriptStore）なので、上から walk しながら
    /// 「親がすべて展開されている行」だけを出力すれば折りたたみ済みの木になる。
    private static func treeRows(_ items: [ScriptItem], expanded: Set<String>) -> [PanelRow] {
        var out: [PanelRow] = []
        var emitted = Set<String>()   // 出力済みフォルダ id（ソート済みなので同フォルダは連続する）

        func ancestorsExpanded(_ gp: [String], upTo count: Int) -> Bool {
            (0..<count).allSatisfy { expanded.contains("d:" + gp.prefix($0 + 1).joined(separator: "/")) }
        }

        for item in items {
            let gp = item.groupPath
            for lvl in 0..<gp.count {
                let idPath = gp.prefix(lvl + 1).joined(separator: "/")
                let id = "d:\(idPath)"
                guard !emitted.contains(id), ancestorsExpanded(gp, upTo: lvl) else { continue }
                emitted.insert(id)
                out.append(PanelRow(id: id, kind: .folder(name: gp[lvl]), level: lvl))
            }
            if ancestorsExpanded(gp, upTo: gp.count) {
                // id は拡張子付きのファイル名で作る。拡張子を除いた表示名だと、同じ階層の同名・拡張子違い
                // （書き出し.scpt／.applescript／.scptd、.jsx と .js 等）が同じ id になり、SwiftUI が
                // 2行目以降を空白で描いた（2026-10-23 実機で発覚）。
                out.append(PanelRow(id: "s:" + (gp + [item.url.lastPathComponent]).joined(separator: "/"),
                                    kind: .script(item), level: gp.count))
            }
        }
        return out
    }
}
