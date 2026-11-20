import SwiftUI
import AppKit
import Carbon
import Combine   // ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

/// 設定の「組み込みショートカット」タブの状態と記録処理（2026-10-30）。
/// 設定ウインドウはキーを受け取れるので、スクリプトの割当のような全画面の記録カードは使わず、行のキー欄で直接記録する
/// （ユーザー指定）。キー欄をクリック → キーを押すと即登録。Esc・ほかの場所のクリックで取りやめ、修飾なし Delete か ✕ で削除（なし）。
/// 他の組み込み・スクリプトの割当と重なったら、行の下に警告と「置き換える」「キャンセル」を出す（置き換えると相手の割当は外れる）。
/// 記録中は AppDelegate がグローバルホットキーを止める（Carbon のホットキーはウインドウより先にキーを奪うため）。
@MainActor
final class BuiltInShortcutsModel: ObservableObject {

    /// 重なった相手。
    enum Holder {
        case builtIn(BuiltInAction)
        case script(path: String)
    }

    /// 置き換えの確認待ち。
    struct Pending {
        let action: BuiltInAction
        let shortcut: ScriptShortcut
        let holder: Holder
        let message: String
    }

    @Published private(set) var shortcuts: [BuiltInAction: ScriptShortcut]
    /// 記録中の動作
    @Published private(set) var recording: BuiltInAction?
    /// 記録中に押さえている修飾キー（実況表示）
    @Published private(set) var liveModifiers = ""
    /// 記録中の案内（修飾キーが足りないときは注意に変わる）
    @Published private(set) var hint = ""
    @Published private(set) var pending: Pending?
    /// 「デフォルトに戻す」の確認待ち（既定のキーをスクリプトが使っているときだけ）。値は帯に出す文。
    @Published private(set) var restorePending: String?

    /// スクリプトの割当（パス → キー。重なりの判定用）
    var scriptShortcuts: () -> [String: ScriptShortcut] = { [:] }
    /// 記録の開始／終了（AppDelegate がホットキーを止める／戻す）
    var onRecordingChanged: (Bool) -> Void = { _ in }
    /// 組み込みの割当が変わった（保存済み。AppDelegate がホットキーを登録し直す）
    var onChange: ([BuiltInAction: ScriptShortcut]) -> Void = { _ in }
    /// 置き換えでスクリプトの割当を外す
    var onRemoveScriptShortcut: (String) -> Void = { _ in }

    private var eventMonitor: Any?
    private var observers: [Any] = []

    var isRecording: Bool { recording != nil }

    init(shortcuts: [BuiltInAction: ScriptShortcut]) {
        self.shortcuts = shortcuts
    }

    // MARK: - 記録

    func startRecording(_ action: BuiltInAction) {
        if isRecording { stopRecording() }
        pending = nil
        restorePending = nil
        recording = action
        liveModifiers = ""
        hint = String(localized: "Press a key with modifiers (F1–F20 may be used alone)")
        installMonitors()
        onRecordingChanged(true)
    }

    func stopRecording() {
        guard isRecording else { return }
        removeMonitors()
        recording = nil
        liveModifiers = ""
        onRecordingChanged(false)
    }

    /// ✕ ボタン・記録中の修飾なし Delete：「なし」にする。
    func clear(_ action: BuiltInAction) {
        stopRecording()
        pending = nil
        restorePending = nil
        guard shortcuts[action] != nil else { return }
        shortcuts[action] = nil
        commit()
    }

    func confirmReplace() {
        guard let p = pending else { return }
        switch p.holder {
        case .builtIn(let other):  shortcuts[other] = nil
        case .script(let path):    onRemoveScriptShortcut(path)
        }
        shortcuts[p.action] = p.shortcut
        pending = nil
        commit()
    }

    func cancelPending() {
        pending = nil
    }

    // MARK: - デフォルトに戻す（2026-11-10 ユーザー指定）

    /// 4つとも既定のキーか（「デフォルトに戻す」をグレーアウトする）。
    var isAllDefault: Bool {
        BuiltInAction.allCases.allSatisfy { shortcuts[$0] == $0.defaultShortcut }
    }

    /// 既定のキーを使っているスクリプト（既定のキー → パス）。いまその組み込みが既定のキーなら重ならないので除く。
    private func scriptsUsingDefaults() -> [(shortcut: ScriptShortcut, path: String)] {
        let scripts = scriptShortcuts()
        return BuiltInAction.allCases.compactMap { action in
            let key = action.defaultShortcut
            guard shortcuts[action] != key,
                  let path = scripts.first(where: { $0.value == key })?.key else { return nil }
            return (key, path)
        }
    }

    /// 「デフォルトに戻す」ボタン。既定のキーをスクリプトが使っていなければすぐ戻す。使っていれば帯で確認する
    /// （記録時の重なりと同じ扱い＝戻すとスクリプトの割当は外れる。ユーザー指定）。
    func requestRestoreDefaults() {
        stopRecording()
        pending = nil
        let conflicts = scriptsUsingDefaults()
        guard !conflicts.isEmpty else {
            restoreDefaults()
            return
        }
        let lines = conflicts.map { item in
            let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
            return String(localized: "\(item.shortcut.display) is already used by “\(name)”.")
        }
        restorePending = (lines + [String(localized: "Restoring the defaults will remove those shortcuts.")])
            .joined(separator: "\n")
    }

    func confirmRestoreDefaults() {
        guard restorePending != nil else { return }
        restoreDefaults()
    }

    func cancelRestoreDefaults() {
        restorePending = nil
    }

    private func restoreDefaults() {
        for item in scriptsUsingDefaults() { onRemoveScriptShortcut(item.path) }
        for action in BuiltInAction.allCases { shortcuts[action] = action.defaultShortcut }
        restorePending = nil
        commit()
    }

    private func commit() {
        BuiltInShortcutStore.save(shortcuts)
        onChange(shortcuts)
    }

    /// 記録中のキー入力。true ならイベントを消費する（ウインドウに渡さない＝ビープも鳴らない）。
    private func handleKeyDown(_ event: NSEvent) {
        guard let action = recording else { return }
        let mods = KeyDisplay.carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)

        if keyCode == 53, mods == 0 {                        // Esc → 取りやめ
            stopRecording()
            return
        }
        if (keyCode == 51 || keyCode == 117), mods == 0 {    // 修飾なし Delete → なし
            clear(action)
            return
        }
        // F キー以外は ⌘⌥⌃ のいずれか必須（スクリプトの割当と同じ規則）
        let hasHardModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasHardModifier || KeyDisplay.functionKeyCodes.contains(keyCode) else {
            hint = String(localized: "Include at least one of ⌘ ⌥ ⌃ (F1–F20 may be used alone)")
            return
        }

        let shortcut = ScriptShortcut(keyCode: keyCode, modifiers: mods)
        stopRecording()
        guard shortcut != shortcuts[action] else { return }   // いまと同じキー

        if let other = shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            pending = Pending(action: action, shortcut: shortcut, holder: .builtIn(other),
                              message: Self.conflictMessage(shortcut, name: other.label))
        } else if let path = scriptShortcuts().first(where: { $0.value == shortcut })?.key {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            pending = Pending(action: action, shortcut: shortcut, holder: .script(path: path),
                              message: Self.conflictMessage(shortcut, name: name))
        } else {
            shortcuts[action] = shortcut
            commit()
        }
    }

    private static func conflictMessage(_ shortcut: ScriptShortcut, name: String) -> String {
        String(localized: "\(shortcut.display) is already used by “\(name)”. Replacing it will remove that shortcut.")
    }

    // MARK: - モニタ

    private func installMonitors() {
        removeMonitors()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            switch event.type {
            case .keyDown:
                self.handleKeyDown(event)
                return nil
            case .flagsChanged:
                self.liveModifiers = KeyDisplay.modifierSymbols(KeyDisplay.carbonModifiers(from: event.modifierFlags))
                return event
            default:
                // ほかの場所のクリックで取りやめ（クリックはそのまま通す。キー欄なら記録をやり直す）
                self.stopRecording()
                return event
            }
        }
        // ウインドウ・アプリから離れたら取りやめ（ホットキーを止めたままにしない）
        let center = NotificationCenter.default
        observers = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            }
        }
    }

    private func removeMonitors() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

/// 設定の「組み込みショートカット」タブ（2026-10-30）。パネルを表示／スクリプトを検索…／クリーンペースト／
/// クリーンペースト（トリム）の4行。各行の右にキー欄と ✕（削除）。
struct BuiltInShortcutsSettingsView: View {
    @ObservedObject var model: BuiltInShortcutsModel

    var body: some View {
        // 標準フォームのカード（2026-11-09）。1動作＝カードの1行（名前が左、キー欄と ✕ が右）
        Section {
            ForEach(BuiltInAction.allCases) { action in
                row(action)
            }
            // 4つまとめて既定のキーに戻す（カードの最下行・右端。2026-11-10 ユーザー指定）
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.requestRestoreDefaults() }
                        .disabled(model.isAllDefault)
                }
                if let message = model.restorePending {
                    band(message,
                         confirmTitle: String(localized: "Restore Defaults"),
                         onCancel: { model.cancelRestoreDefaults() },
                         onConfirm: { model.confirmRestoreDefaults() })
                }
            }
        } header: {
            // 見出し（2026-10-30 に「ショートカット」タブへまとめたとき、下の「スクリプトのショートカット」と区別するため追加）。
            // 説明は操作の1段落だけ（クリーンペーストの説明・使える条件の段落は 2026-10-30 ユーザー指定で削除＝ヘルプに記載）。
            // 説明は見出しの下（システム設定の「ログイン時に開く」と同じ形。2026-11-10 ユーザー指定でカードの下から移した）
            SettingsSectionHeader(title: "Built-in Shortcuts",
                                  note: "Click a shortcut, then press the new keys. Click ✕ to remove it.")
        }
        .onDisappear { model.stopRecording() }   // タブを切り替えたら取りやめ
    }

    @ViewBuilder
    private func row(_ action: BuiltInAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(action.label)
                    .lineLimit(1)
                    .layoutPriority(1)   // 「クリーンペースト（トリム）」を折り返さない（キー欄より優先）
                Spacer(minLength: 8)
                keyField(action)
                Button {
                    model.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.shortcuts[action] == nil && model.recording != action)
                .opacity(model.shortcuts[action] == nil && model.recording != action ? 0.35 : 1)
            }
            if model.recording == action {
                Text(model.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = model.pending, p.action == action {
                conflictBand(p)
            }
        }
    }

    private func keyField(_ action: BuiltInAction) -> some View {
        let isRecording = model.recording == action
        let shortcut = model.shortcuts[action]
        return Button {
            model.startRecording(action)
        } label: {
            Group {
                if isRecording {
                    Text(model.liveModifiers.isEmpty ? String(localized: "Type Shortcut") : model.liveModifiers)
                        .foregroundStyle(model.liveModifiers.isEmpty ? .secondary : .primary)
                } else if let shortcut {
                    Text(shortcut.display)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: 100, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.2),
                                  lineWidth: isRecording ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 重なりの警告（記録カードの重複警告と同じアクセント色の帯）。
    private func conflictBand(_ p: BuiltInShortcutsModel.Pending) -> some View {
        band(p.message,
             confirmTitle: String(localized: "Replace"),
             onCancel: { model.cancelPending() },
             onConfirm: { model.confirmReplace() })
    }

    /// 確認の帯（文＋キャンセル／実行）。記録時の重なりと「デフォルトに戻す」で共用。
    private func band(_ message: String, confirmTitle: String,
                      onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel")) { onCancel() }
                Button(confirmTitle) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.22)))
    }
}
