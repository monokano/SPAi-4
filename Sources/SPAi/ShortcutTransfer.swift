import AppKit
import Carbon   // 旧版のキー名 → kVK_*・修飾キー（cmdKey 等）
import SwiftUI
import UniformTypeIdentifiers
import Combine   // @Published / ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

// MARK: - 書き出しファイルの形式

/// ショートカット書き出しファイル（JSON）。別の Mac へ割当を移すためのもの。
/// `ShortcutStore` はフルパス＋ブックマーク（そのMac専用）で持つため、そのままでは移せない。
/// そこで「登録フォルダ名＋登録フォルダからの相対パス」で書き出し、読み込み側の登録フォルダで照合する。
nonisolated struct ShortcutExportFile: Codable {
    static let formatID = "com.tama-san.SPAi4.shortcuts"
    static let currentVersion = 1

    var format: String
    var version: Int
    var source: String?            // 書き出し元のコンピュータ名（確認シートに表示）
    var exportedAt: Date?
    var shortcuts: [Entry]

    struct Entry: Codable {
        var folder: String         // 登録フォルダの名前（lastPathComponent）
        var path: String           // 登録フォルダからの相対パス（"/" 区切り・拡張子込み）
        var keyCode: UInt32
        var modifiers: UInt32
    }
}

/// 書き出し・読み込みの照合ロジック（UI なし）。
nonisolated enum ShortcutTransfer {

    /// 現在の割当を書き出し形式へ。登録フォルダの外にあるスクリプト（フォルダを登録解除した等）は含めない。
    static func makeExport(shortcuts: [String: ScriptShortcut], roots: [URL]) -> ShortcutExportFile {
        var entries: [ShortcutExportFile.Entry] = []
        for (path, shortcut) in shortcuts {
            guard let (root, rel) = locate(path, in: roots) else { continue }
            entries.append(.init(folder: root.lastPathComponent,
                                 path: rel.joined(separator: "/"),
                                 keyCode: shortcut.keyCode,
                                 modifiers: shortcut.modifiers))
        }
        entries.sort { ($0.folder, $0.path) < ($1.folder, $1.path) }
        return ShortcutExportFile(format: ShortcutExportFile.formatID,
                                  version: ShortcutExportFile.currentVersion,
                                  source: Host.current().localizedName,
                                  exportedAt: Date(),
                                  shortcuts: entries)
    }

    static func encode(_ file: ShortcutExportFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    /// SPAi の書き出しファイルでなければ nil。
    static func decode(_ data: Data) -> ShortcutExportFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ShortcutExportFile.self, from: data),
              file.format == ShortcutExportFile.formatID,
              file.version <= ShortcutExportFile.currentVersion else { return nil }
        return file
    }

    /// path を含む登録フォルダ（入れ子なら最も深いもの）と、そこからの相対パス要素。
    private static func locate(_ path: String, in roots: [URL]) -> (URL, [String])? {
        let comps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var best: (URL, [String])?
        for root in roots {
            let rc = root.standardizedFileURL.pathComponents
            guard comps.count > rc.count, Array(comps.prefix(rc.count)) == rc else { continue }
            if best == nil || rc.count > best!.0.standardizedFileURL.pathComponents.count {
                best = (root, Array(comps.suffix(from: rc.count)))
            }
        }
        return best
    }

    /// 読み込み1件の照合結果。
    struct ImportItem: Identifiable {
        enum Status {
            case ready                   // 割り当てられる（同じ割当が既にある場合も含む）
            case conflict(owner: String) // キーが別スクリプトに割当済み（owner はそのパス）
            case notFound                // 登録フォルダ内にスクリプトが無い
        }
        let id: Int
        let shortcut: ScriptShortcut
        let folder: String
        let relativePath: String
        let targetPath: String?          // 照合できたスクリプトのフルパス
        let status: Status

        var isConflict: Bool { if case .conflict = status { return true } else { return false } }
    }

    /// 書き出しファイルを、いまの登録フォルダ・割当と照合する。
    /// 照合は「同名の登録フォルダ内の同じ相対パス」を優先し、無ければ他の登録フォルダの同じ相対パスで探す。
    static func plan(_ file: ShortcutExportFile, roots: [URL],
                     current: [String: ScriptShortcut]) -> [ImportItem] {
        let fm = FileManager.default
        var items: [ImportItem] = []
        var usedTargets = Set<String>()
        for (i, e) in file.shortcuts.enumerated() {
            let shortcut = ScriptShortcut(keyCode: e.keyCode, modifiers: e.modifiers)
            // 予約キー（⇧⌘Space／⇧⌥⌘Space）は手で書き換えたファイルでもない限り来ないが、念のため除外。
            guard !ShortcutRecorderController.isReserved(shortcut),
                  !KeyDisplay.isSystemReserved(shortcut) else { continue }   // ⌘⌥Esc／⌘⌥⇧Esc（2026-11-23）
            let rel = e.path.split(separator: "/").map(String.init)
            guard !rel.isEmpty, !rel.contains("..") else { continue }

            let ordered = roots.filter { $0.lastPathComponent == e.folder }
                        + roots.filter { $0.lastPathComponent != e.folder }
            let target = ordered
                .map { rel.reduce($0) { $0.appendingPathComponent($1) }.path }
                .first { fm.fileExists(atPath: $0) && !usedTargets.contains($0) }

            let status: ImportItem.Status
            if let target {
                usedTargets.insert(target)
                if let owner = current.first(where: { $0.value == shortcut && $0.key != target })?.key {
                    status = .conflict(owner: owner)
                } else {
                    status = .ready
                }
            } else {
                status = .notFound
            }
            items.append(ImportItem(id: i, shortcut: shortcut, folder: e.folder,
                                    relativePath: e.path, targetPath: target, status: status))
        }
        return sortedByKey(items)
    }

    private static func sortedByKey(_ items: [ImportItem]) -> [ImportItem] {
        items.sorted { a, b in
            let ka = KeyDisplay.keyName(a.shortcut.keyCode), kb = KeyDisplay.keyName(b.shortcut.keyCode)
            if ka != kb { return ka.compare(kb, options: .numeric) == .orderedAscending }
            return a.shortcut.modifiers < b.shortcut.modifiers
        }
    }

    /// 照合結果を適用した新しい割当。`selected` は行ごとのチェック（id → 読み込むか）。
    /// 重複の行を読み込むと上書きになり、そのキーを持っていた別スクリプトの割当は外れる（記録オーバーレイと同じ後勝ち）。
    /// 2026-10-30 に重複行の「上書き／スキップ」のポップアップを行ごとのチェックボックスへ置き換え（ユーザー指定）。
    static func apply(_ items: [ImportItem], to current: [String: ScriptShortcut],
                      clearAll: Bool, selected: [Int: Bool]) -> [String: ScriptShortcut] {
        var map = clearAll ? [:] : current
        for item in items {
            guard let target = item.targetPath, selected[item.id] == true else { continue }
            for (p, s) in map where s == item.shortcut && p != target { map[p] = nil }
            map[target] = item.shortcut
        }
        return map
    }
}

// MARK: - 旧版（Xojo 版 SPAi 3）のショートカット設定

/// 旧版の設定ファイル `~/Library/Application Support/monokano/SPAi/Shortcut.setting` を読む（2026-10-30）。
/// 1行1件・"::" 区切りの5項目：Base64(エイリアスレコード)::Base64(ホットキー)::チェック(0/1)::有効(0/1)::種類。
/// 種類は 0＝プレーンテキストペースト／1＝パネルの表示切替（いずれも SPAi 4 には無いか固定キー）／2＝スクリプト。
/// ホットキーは「修飾キー記号,キー名」（例 "⌥⇧⌘,map_2"）。キー名は Carbon の kVK_* と同じ物理キーの名前。
/// エイリアスレコードは MBS の MacAliasMBS（Carbon Alias Manager）で作られたもの。
extension ShortcutTransfer {

    static let legacySettingURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/monokano/SPAi/Shortcut.setting")

    /// 旧版の設定ファイルがあるか（設定の「SPAi 3から読み込む…」ボタンを出すかどうか）。
    static var legacySettingExists: Bool {
        FileManager.default.fileExists(atPath: legacySettingURL.path)
    }

    /// 旧版の設定を、いまの登録フォルダ・割当と照合する。読めなければ読み取りのエラーを投げる
    /// （2026-11-09。以前は nil で返してエラーを捨てていた＝「あるのに読めない」の原因が分からなかった）。
    /// 取り込むのはチェックが付いた（旧版で有効だった）スクリプトの割当だけ。SPAi 4 の割当ルール
    /// （F1〜F20 以外は ⌘⌥⌃ のいずれか必須・予約キー不可）に合わないものも除く。
    /// スクリプトはエイリアスで探し、見つかっても登録フォルダの外なら「見つからない」扱い（書き出しファイルの読み込みと同じ）。
    static func planLegacy(roots: [URL], current: [String: ScriptShortcut]) throws -> [ImportItem] {
        let text = try String(contentsOf: legacySettingURL, encoding: .utf8)
        var items: [ImportItem] = []
        var usedTargets = Set<String>()
        var usedKeys: [ScriptShortcut] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
        for (i, line) in lines.enumerated() {
            let f = line.components(separatedBy: "::")
            guard f.count >= 5, f[4] == "2", f[2] == "1",
                  let hotkey = Data(base64Encoded: f[1]).flatMap({ String(data: $0, encoding: .utf8) }),
                  let shortcut = legacyShortcut(hotkey),
                  !usedKeys.contains(shortcut) else { continue }   // 同じキーが2件あれば先の1件だけ
            usedKeys.append(shortcut)

            let (resolved, recorded) = resolveLegacyAlias(Data(base64Encoded: f[0]) ?? Data())
            var target: String?
            var folder = "", rel: [String] = []
            if let resolved, let (root, r) = locate(resolved, in: roots), !usedTargets.contains(resolved) {
                target = resolved
                folder = root.lastPathComponent
                rel = r
            } else if let path = resolved ?? recorded {
                // 見つからない行は、元の場所の「親フォルダ / 名前」で示す
                rel = Array(URL(fileURLWithPath: path).pathComponents.suffix(2))
            } else {
                continue
            }

            let status: ImportItem.Status
            if let target {
                usedTargets.insert(target)
                if let owner = current.first(where: { $0.value == shortcut && $0.key != target })?.key {
                    status = .conflict(owner: owner)
                } else {
                    status = .ready
                }
            } else {
                status = .notFound
            }
            items.append(ImportItem(id: i, shortcut: shortcut, folder: folder,
                                    relativePath: rel.joined(separator: "/"), targetPath: target, status: status))
        }
        return sortedByKey(items)
    }

    /// 旧版のホットキー文字列 → ScriptShortcut。SPAi 4 で割り当てられないものは nil。
    private static func legacyShortcut(_ s: String) -> ScriptShortcut? {
        let parts = s.components(separatedBy: ",")
        guard parts.count == 2, let keyCode = legacyKeyCodes[parts[1]] else { return nil }
        var modifiers = 0
        if parts[0].contains("⌘") { modifiers |= cmdKey }
        if parts[0].contains("⌥") { modifiers |= optionKey }
        if parts[0].contains("⌃") { modifiers |= controlKey }
        if parts[0].contains("⇧") { modifiers |= shiftKey }
        let shortcut = ScriptShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        let hasRequired = modifiers & (cmdKey | optionKey | controlKey) != 0
        // F キーと Esc は単独可（記録画面と同じ規則。Esc は 2026-11-23）。⌘⌥Esc／⌘⌥⇧Esc（強制終了）は不可。
        guard hasRequired || KeyDisplay.functionKeyCodes.contains(shortcut.keyCode)
                || shortcut.keyCode == KeyDisplay.escapeKeyCode,
              !KeyDisplay.isSystemReserved(shortcut),
              !ShortcutRecorderController.isReserved(shortcut) else { return nil }
        return shortcut
    }

    /// エイリアスレコード → (解決できた実在のパス, 記録されていた元のパス)。
    /// Carbon のエイリアスレコードはブックマークに変換して解決する（変換 API は非推奨だが、
    /// 旧形式を読むための唯一の手段。警告を出さないよう実行時に引く）。
    /// 解決できないとき（改名・移動・削除）は、記録されていた元のパスにファイルがあればそれを使う。
    private static func resolveLegacyAlias(_ record: Data) -> (resolved: String?, recorded: String?) {
        guard !record.isEmpty, let bookmark = bookmarkFromAliasRecord(record) else { return (nil, nil) }
        let recorded = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale),
           !ScriptItem.isInTrash(url.path) {
            return (canonicalPath(url.path), recorded)
        }
        if let recorded, FileManager.default.fileExists(atPath: recorded), !ScriptItem.isInTrash(recorded) {
            return (canonicalPath(recorded), recorded)
        }
        return (nil, recorded)
    }

    /// `CFURLCreateBookmarkDataFromAliasRecord`（macOS 11 で非推奨・現役で動作。2026-10-30 実機確認）。
    private static func bookmarkFromAliasRecord(_ record: Data) -> Data? {
        typealias Fn = @convention(c) (CFAllocator?, CFData) -> Unmanaged<CFData>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CFURLCreateBookmarkDataFromAliasRecord")
        else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(nil, record as CFData)?.takeRetainedValue() as Data?
    }

    /// 実際の大文字小文字のパス（旧版の記録は "scripts" でも実体は "Scripts" のことがある。
    /// 割当はパスの文字列で引くため、走査結果と同じ表記にそろえる）。
    private static func canonicalPath(_ path: String) -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return path }
        defer { close(fd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return path }
        return String(cString: buf)
    }

    /// 旧版のキー名（Xojo 版の "map_*"）→ 仮想キーコード。名前は Carbon の kVK_* と同じ物理キー。
    private static let legacyKeyCodes: [String: Int] = [
        "map_0": kVK_ANSI_0, "map_1": kVK_ANSI_1, "map_2": kVK_ANSI_2, "map_3": kVK_ANSI_3, "map_4": kVK_ANSI_4,
        "map_5": kVK_ANSI_5, "map_6": kVK_ANSI_6, "map_7": kVK_ANSI_7, "map_8": kVK_ANSI_8, "map_9": kVK_ANSI_9,
        "map_A": kVK_ANSI_A, "map_B": kVK_ANSI_B, "map_C": kVK_ANSI_C, "map_D": kVK_ANSI_D, "map_E": kVK_ANSI_E,
        "map_F": kVK_ANSI_F, "map_G": kVK_ANSI_G, "map_H": kVK_ANSI_H, "map_I": kVK_ANSI_I, "map_J": kVK_ANSI_J,
        "map_K": kVK_ANSI_K, "map_L": kVK_ANSI_L, "map_M": kVK_ANSI_M, "map_N": kVK_ANSI_N, "map_O": kVK_ANSI_O,
        "map_P": kVK_ANSI_P, "map_Q": kVK_ANSI_Q, "map_R": kVK_ANSI_R, "map_S": kVK_ANSI_S, "map_T": kVK_ANSI_T,
        "map_U": kVK_ANSI_U, "map_V": kVK_ANSI_V, "map_W": kVK_ANSI_W, "map_X": kVK_ANSI_X, "map_Y": kVK_ANSI_Y,
        "map_Z": kVK_ANSI_Z,
        "map_Equal": kVK_ANSI_Equal, "map_Minus": kVK_ANSI_Minus, "map_LeftBracket": kVK_ANSI_LeftBracket,
        "map_RightBracket": kVK_ANSI_RightBracket, "map_Quote": kVK_ANSI_Quote, "map_Semicolon": kVK_ANSI_Semicolon,
        "map_Backslash": kVK_ANSI_Backslash, "map_Comma": kVK_ANSI_Comma, "map_Slash": kVK_ANSI_Slash,
        "map_Period": kVK_ANSI_Period, "map_Grave": kVK_ANSI_Grave,
        "map_Return": kVK_Return, "map_Tab": kVK_Tab, "map_Space": kVK_Space, "map_Delete": kVK_Delete,
        "map_Escape": kVK_Escape, "map_ForwardDelete": kVK_ForwardDelete, "map_Home": kVK_Home, "map_End": kVK_End,
        "map_PageUp": kVK_PageUp, "map_PageDown": kVK_PageDown, "map_UpArrow": kVK_UpArrow,
        "map_DownArrow": kVK_DownArrow, "map_LeftArrow": kVK_LeftArrow, "map_RightArrow": kVK_RightArrow,
        "map_PadClear": kVK_ANSI_KeypadClear, "map_PadMultiply": kVK_ANSI_KeypadMultiply,
        "map_PadPlus": kVK_ANSI_KeypadPlus, "map_PadEnter": kVK_ANSI_KeypadEnter,
        "map_JIS_Yen": kVK_JIS_Yen, "map_JIS_Underscore": kVK_JIS_Underscore,
        "map_F1": kVK_F1, "map_F2": kVK_F2, "map_F3": kVK_F3, "map_F4": kVK_F4, "map_F5": kVK_F5,
        "map_F6": kVK_F6, "map_F7": kVK_F7, "map_F8": kVK_F8, "map_F9": kVK_F9, "map_F10": kVK_F10,
        "map_F11": kVK_F11, "map_F12": kVK_F12, "map_F13": kVK_F13, "map_F14": kVK_F14, "map_F15": kVK_F15,
        "map_F16": kVK_F16, "map_F17": kVK_F17, "map_F18": kVK_F18, "map_F19": kVK_F19, "map_F20": kVK_F20,
    ]
}

// MARK: - 書き出し／読み込みの操作（設定ウインドウから）

/// 設定ウインドウの「書き出す…」「読み込む…」の流れ（保存/選択パネル → 確認シート）。
@MainActor
final class ShortcutTransferController {

    private var sheetWindow: NSWindow?

    /// 書き出し。割当が無ければその旨を知らせる。成功時は何も表示しない（成功は無音の方針）。
    func export(shortcuts: [String: ScriptShortcut], roots: [URL], from window: NSWindow?) {
        let file = ShortcutTransfer.makeExport(shortcuts: shortcuts, roots: roots)
        guard !file.shortcuts.isEmpty else {
            showAlert(String(localized: "There are no shortcuts to export."), info: nil, on: window)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SPAi Shortcuts.json"
        panel.allowedContentTypes = [.json]
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ShortcutTransfer.encode(file).write(to: url, options: .atomic)
            } catch {
                self?.showAlert(String(localized: "Couldn't export shortcuts."),
                                info: error.localizedDescription, on: window)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    /// 読み込み。ファイルを選ばせ、照合結果の確認シートを出す。確定したら新しい割当を `onApply` で返す。
    /// `current` はシートで確定した瞬間の割当を取り直すためのクロージャ（シート表示中の変更に備える）。
    func importShortcuts(roots: [URL], current: @escaping () -> [String: ScriptShortcut],
                         from window: NSWindow?,
                         onApply: @escaping ([String: ScriptShortcut]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let file = ShortcutTransfer.decode(data) else {
                self.showAlert(String(localized: "Couldn't read this file."),
                               info: String(localized: "Choose a shortcuts file exported from SPAi."), on: window)
                return
            }
            let items = ShortcutTransfer.plan(file, roots: roots, current: current())
            // 選択パネルのシートが閉じ切ってから次のシートを出す。
            DispatchQueue.main.async {
                self.presentConfirm(items: items, fileName: url.lastPathComponent, source: file.source,
                                    current: current, on: window, onApply: onApply)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: open) } else { open(panel.runModal()) }
    }

    /// 旧版（SPAi 3）の設定ファイルから読み込む。ファイルは決まった場所にあるので選ばせず、そのまま確認シートを出す。
    func importLegacyShortcuts(roots: [URL], current: @escaping () -> [String: ScriptShortcut],
                               from window: NSWindow?,
                               onApply: @escaping ([String: ScriptShortcut]) -> Void) {
        let items: [ShortcutTransfer.ImportItem]
        do {
            items = try ShortcutTransfer.planLegacy(roots: roots, current: current())
        } catch {
            // ファイルはある（ボタンはあるときだけ出す）のに読めなかった。原因が分かるよう、ファイル名とエラーを出して記録する。
            let url = ShortcutTransfer.legacySettingURL
            NSLog("[SPAi] Failed to read %@: %@", url.path, String(describing: error))
            showAlert(String(localized: "Couldn't read the SPAi 3 shortcut settings."),
                      info: "\(url.lastPathComponent): \(error.localizedDescription)", on: window)
            return
        }
        guard !items.isEmpty else {
            showAlert(String(localized: "There are no shortcuts to import from SPAi 3."), info: nil, on: window)
            return
        }
        presentConfirm(items: items, fileName: "SPAi 3 (\(ShortcutTransfer.legacySettingURL.lastPathComponent))",
                       source: nil, current: current, on: window, onApply: onApply)
    }

    private func presentConfirm(items: [ShortcutTransfer.ImportItem], fileName: String, source: String?,
                                current: @escaping () -> [String: ScriptShortcut],
                                on parent: NSWindow?,
                                onApply: @escaping ([String: ScriptShortcut]) -> Void) {
        let vm = ShortcutImportViewModel(items: items, fileName: fileName, source: source)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ShortcutImportView(
            vm: vm,
            onCancel: { [weak self] in self?.closeSheet() },
            onImport: { [weak self] in
                let map = ShortcutTransfer.apply(vm.items, to: current(),
                                                 clearAll: vm.clearAll, selected: vm.selected)
                self?.closeSheet()
                onApply(map)
            })))
        sheet.styleMask = [.titled]
        if let contentView = sheet.contentView {
            contentView.layoutSubtreeIfNeeded()
            sheet.setContentSize(contentView.fittingSize)
        }
        sheetWindow = sheet
        if let parent {
            parent.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func closeSheet() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        sheetWindow = nil
    }

    private func showAlert(_ message: String, info: String?, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        if let info { alert.informativeText = info }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - 読み込みの確認シート

@MainActor
final class ShortcutImportViewModel: ObservableObject {
    let items: [ShortcutTransfer.ImportItem]
    let fileName: String
    let source: String?
    /// 行ごとのチェック（true＝読み込む。重複の行は上書き）。見つかった行はすべて初期状態でチェックあり
    /// （重複の行も、旧ポップアップの既定「上書き」と同じ）。見つからない行は持たない（チェックできない）。
    @Published var selected: [Int: Bool]
    /// 「現在のショートカット登録を全削除してから読み込む」。ON なら重複は起きない。
    @Published var clearAll = false

    init(items: [ShortcutTransfer.ImportItem], fileName: String, source: String?) {
        self.items = items
        self.fileName = fileName
        self.source = source
        selected = Dictionary(uniqueKeysWithValues: items.filter { $0.targetPath != nil }.map { ($0.id, true) })
    }

    private var conflictCount: Int { items.filter(\.isConflict).count }
    var notFoundCount: Int { items.filter { $0.targetPath == nil }.count }
    /// 表示上の重複件数（全削除 ON なら 0）。
    var shownConflictCount: Int { clearAll ? 0 : conflictCount }
    /// 表示上の割当可件数（全削除 ON なら重複も割当可に数える）。
    var shownReadyCount: Int { items.count - notFoundCount - shownConflictCount }
    /// 実際に割り当てる件数（ボタンの「N件を読み込む」）＝チェックした行の数。
    var importCount: Int { items.filter { $0.targetPath != nil && selected[$0.id] == true }.count }
}

struct ShortcutImportView: View {
    @ObservedObject var vm: ShortcutImportViewModel
    var onCancel: () -> Void
    var onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Shortcuts")
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)

            // 色はアイコンだけに付け、文字は濃いまま（オレンジ文字は視認性が悪い＝記録カードの警告と同じ方針）
            HStack(spacing: 14) {
                Label { Text("Ready: \(vm.shownReadyCount)") } icon: {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
                Label { Text("Conflicts: \(vm.shownConflictCount)") } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                Label { Text("Not Found: \(vm.notFoundCount)") } icon: {
                    Image(systemName: "questionmark").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.top, 12)

            list
                .padding(.top, 10)

            Toggle("Delete all current shortcuts before importing", isOn: $vm.clearAll)
                .toggleStyle(.checkbox)
                .padding(.top, 12)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button { onImport() } label: {
                    Text("Import \(vm.importCount)").frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.importCount == 0)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        let count = String(localized: "\(vm.items.count) shortcuts")
        if let source = vm.source, !source.isEmpty {
            return String(localized: "\(vm.fileName) · \(count) (exported from \(source))")
        }
        return "\(vm.fileName) · \(count)"
    }

    /// 照合結果の一覧。高さは行の高さの合計で決め、上限を超えたらスクロールさせる。
    private var list: some View {
        let contentHeight = vm.items.reduce(CGFloat(0)) { $0 + rowHeight($1) } + Self.listPadding * 2
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.items) { item in
                    // 行間の区切り線は高さに影響しない overlay で引く（一覧の高さを行の高さの合計で決めるため）
                    row(item)
                        .overlay(alignment: .bottom) {
                            if item.id != vm.items.last?.id {
                                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                            }
                        }
                }
            }
            .padding(Self.listPadding)
        }
        .frame(height: min(contentHeight, Self.maxListHeight))
        .scrollIndicators(contentHeight > Self.maxListHeight ? .visible : .hidden)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }

    private func showsConflict(_ item: ShortcutTransfer.ImportItem) -> Bool {
        item.isConflict && !vm.clearAll
    }

    private func rowHeight(_ item: ShortcutTransfer.ImportItem) -> CGFloat {
        showsConflict(item) ? Self.conflictRowHeight : Self.rowHeight
    }

    @ViewBuilder
    private func row(_ item: ShortcutTransfer.ImportItem) -> some View {
        let notFound = item.targetPath == nil
        let checked = vm.selected[item.id] == true
        HStack(spacing: 8) {
            // 読み込むかどうかを行ごとに選ぶ（2026-10-30 ユーザー指定）。見つからない行はチェックできない
            Toggle("", isOn: Binding(
                get: { checked },
                set: { vm.selected[item.id] = $0 }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(notFound)
            statusIcon(item)
                .frame(width: 16)
            Text(item.shortcut.display)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 56, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.relativePath.replacingOccurrences(of: "/", with: " / "))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .conflict(let owner) = item.status, !vm.clearAll {
                    Text("This key is assigned to “\(URL(fileURLWithPath: owner).lastPathComponent)”")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        // チェックを外した行も、見つからない行と同じく淡色にして「読み込まない」ことを示す
        .foregroundStyle(notFound || !checked ? .secondary : .primary)
        .padding(.horizontal, 6)
        .frame(height: rowHeight(item))
        .background(RoundedRectangle(cornerRadius: 4)
            // 重複行の帯は記録カードの割当一覧の強調と同じアクセント色 22%（旧 黄 22%。2026-10-30 ユーザー指定）
            .fill(showsConflict(item) ? Color.accentColor.opacity(0.22) : Color.clear))
    }

    @ViewBuilder
    private func statusIcon(_ item: ShortcutTransfer.ImportItem) -> some View {
        if item.targetPath == nil {
            Image(systemName: "questionmark").foregroundStyle(.secondary)
        } else if showsConflict(item) {
            // 重複行は帯に警告マークを重ねる（集計行の「重複」と同じマーク）。2026-10-22 に「黄色の上に黄色の
            // 警告マークは野暮ったい」として外したが、2026-10-30 ユーザー指定で戻した
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        } else {
            Image(systemName: "checkmark").foregroundStyle(.green)
        }
    }

    private static let rowHeight: CGFloat = 24
    private static let conflictRowHeight: CGFloat = 40
    private static let listPadding: CGFloat = 4
    private static let maxListHeight: CGFloat = 260
}
