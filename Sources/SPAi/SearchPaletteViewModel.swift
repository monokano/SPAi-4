import Foundation
import SwiftUI
import Combine   // @Published / ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

/// 検索パレットの1行（フラット表示）。
struct PaletteRow: Identifiable {
    let id: String          // ファイルのフルパス
    let item: ScriptItem
    let subtitle: String?   // 所属フォルダ（例 "整列 › 上級"）
}

/// 検索パレット（仕様書 §3B）の状態と検索ロジック。
/// - 空クエリ → MRU（最近使った順）を先頭に全件（「さっきのをもう一回」が最速）
/// - 入力中 → あいまい一致（サブシーケンス）スコア順。同点は MRU → 名前順
@MainActor
final class SearchPaletteViewModel: ObservableObject {

    @Published var query = "" {
        didSet { if query != oldValue { rebuildRows(resetSelection: true) } }
    }
    @Published private(set) var rows: [PaletteRow] = []
    @Published var selectedID: String?
    /// 増えたら検索欄へフォーカス（パレット表示時にコントローラが更新）。
    @Published var focusRequest = 0

    /// スクリプト実行のハンドラ（コントローラが注入）。
    var onRun: ((ScriptItem) -> Void)?

    private var allItems: [ScriptItem] = []

    var scriptCount: Int { allItems.count }

    /// ScriptStore の走査結果を反映する。
    /// 親フォルダとその中のサブフォルダを両方登録していると、同一ファイルが複数の経路で
    /// 重複して載る（行 id＝パスが衝突し、SwiftUI が空行を描く実害も出る・2026-07-09）。
    /// 検索は「実体」単位が自然なので、パスで重複排除する（表記は階層の浅い方＝
    /// 専用に登録したフォルダ側を残す）。
    func update(items: [ScriptItem]) {
        var byPath: [String: ScriptItem] = [:]
        for item in items {
            if let existing = byPath[item.url.path] {
                if item.groupPath.count < existing.groupPath.count {
                    byPath[item.url.path] = item
                }
            } else {
                byPath[item.url.path] = item
            }
        }
        allItems = byPath.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // 照合用にそろえた名前とフォルダ込みの名前（キー入力のたびではなく一覧の更新時に一度だけ作る）
        searchKeys = Dictionary(uniqueKeysWithValues: allItems.map { item in
            (item.url.path, SearchKey(name: FuzzyMatch.normalize(item.name),
                                      fullPath: FuzzyMatch.normalize((item.groupPath + [item.name]).joined(separator: " "))))
        })
        rebuildRows(resetSelection: false)
    }

    /// 照合用にそろえた文字列（`FuzzyMatch.normalize` 済み）。
    private struct SearchKey {
        let name: String
        let fullPath: String
    }
    private var searchKeys: [String: SearchKey] = [:]

    /// パレット表示時の初期化：検索をクリアして先頭選択、検索欄へフォーカス。
    func prepareForShow() {
        if query.isEmpty {
            rebuildRows(resetSelection: true)
        } else {
            query = ""   // didSet 経由で rebuild（先頭選択）
        }
        focusRequest += 1
    }

    // MARK: - 選択と実行

    /// ↑↓キーでの選択移動。
    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        guard let sel = selectedID, let idx = rows.firstIndex(where: { $0.id == sel }) else {
            selectedID = delta >= 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = min(max(idx + delta, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    /// Enter：選択中のスクリプトを実行。
    func runSelected() {
        guard let sel = selectedID,
              let row = rows.first(where: { $0.id == sel }) else { return }
        run(row.item)
    }

    /// 実行の共通経路（ダブルクリック・Enter）。MRU を更新してハンドラへ渡す。
    func run(_ item: ScriptItem) {
        MRUStore.touch(item.url.path)
        onRun?(item)
    }

    // MARK: - 行の組み立て

    private func rebuildRows(resetSelection: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        rows = q.isEmpty ? Self.mruRows(allItems)
            : Self.searchRows(allItems, keys: searchKeys, query: FuzzyMatch.normalize(q))
        if resetSelection || !(selectedID.map { id in rows.contains { $0.id == id } } ?? false) {
            selectedID = rows.first?.id
        }
    }

    private static func subtitle(of item: ScriptItem) -> String? {
        item.groupPath.isEmpty ? nil : item.groupPath.joined(separator: " › ")
    }

    /// 空クエリ：MRU を先頭に全件（MRU 外は名前順）。
    private static func mruRows(_ items: [ScriptItem]) -> [PaletteRow] {
        let mru = MRUStore.paths()
        let sorted = items.sorted { a, b in
            let ia = mru.firstIndex(of: a.url.path) ?? Int.max
            let ib = mru.firstIndex(of: b.url.path) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return sorted.map { PaletteRow(id: $0.url.path, item: $0, subtitle: subtitle(of: $0)) }
    }

    /// 検索中：スコア降順 → MRU → 名前順。`query` は `FuzzyMatch.normalize` 済み。
    private static func searchRows(_ items: [ScriptItem], keys: [String: SearchKey],
                                   query: String) -> [PaletteRow] {
        let mru = MRUStore.paths()
        struct Hit {
            let item: ScriptItem
            let score: Int
            let mruIndex: Int
        }
        var hits: [Hit] = []
        for item in items {
            // 名前一致を優先しつつ、フォルダ名を含めた全階層横断の一致も拾う（§3B）。
            guard let key = keys[item.url.path] else { continue }
            let byName = FuzzyMatch.score(query: query, in: key.name)
            let byPath = FuzzyMatch.score(query: query, in: key.fullPath).map { $0 - 1 }
            guard let score = [byName, byPath].compactMap({ $0 }).max() else { continue }
            let mruIndex = mru.firstIndex(of: item.url.path) ?? Int.max
            hits.append(Hit(item: item, score: score, mruIndex: mruIndex))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.mruIndex != $1.mruIndex { return $0.mruIndex < $1.mruIndex }
            return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
        return hits.map { PaletteRow(id: $0.item.url.path, item: $0.item, subtitle: subtitle(of: $0.item)) }
    }
}

/// あいまい一致（サブシーケンス）。query の全文字が candidate に順番どおり現れれば一致。
/// 連続一致と語頭一致にボーナスを与え、スコアが大きいほど上位に出す。
enum FuzzyMatch {
    /// 照合用に文字をそろえる（2026-10-24）：大文字小文字・全角半角（英数記号と半角カナ）・ひらがなとカタカナの
    /// 違いを無視する。Illustrator で日本語入力中にパレットを開くと全角英字やかなで打たれ、英語名・カタカナ名の
    /// スクリプトにヒットしなかった（例「ｓｅｌ」≠「sel」、「せれくと」≠「セレクト」）。
    /// NFKC（全角英数→半角、半角カナ→全角カナ）→ カタカナ→ひらがな → 小文字。
    static func normalize(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let hiragana = nfkc.applyingTransform(.hiraganaToKatakana, reverse: true) ?? nfkc
        return hiragana.lowercased()
    }

    /// `query`・`candidate` とも `normalize` 済みで渡す（候補は一覧の更新時に一度だけそろえておく）。
    static func score(query: String, in candidate: String) -> Int? {
        let q = Array(query)
        let c = Array(candidate)
        guard !q.isEmpty else { return 0 }
        var qi = 0
        var score = 0
        var streak = 0
        var prevIsBoundary = true
        for ch in c {
            if qi < q.count, ch == q[qi] {
                streak += 1
                score += streak                     // 連続一致ボーナス
                if prevIsBoundary { score += 3 }    // 語頭一致ボーナス
                qi += 1
            } else {
                streak = 0
            }
            prevIsBoundary = !(ch.isLetter || ch.isNumber)
        }
        return qi == q.count ? score : nil
    }
}

/// MRU（最近使った順）。検索パレットの並び・パネルからの実行の両方で更新される。
enum MRUStore {
    private static let key = "SPAi.mruPaths"
    private static let capacity = 100

    static func paths() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func touch(_ path: String) {
        var arr = paths()
        arr.removeAll { $0 == path }
        arr.insert(path, at: 0)
        if arr.count > capacity { arr.removeLast(arr.count - capacity) }
        UserDefaults.standard.set(arr, forKey: key)
    }
}
