import AppKit
import SwiftUI
import Carbon
import Combine   // @Published / ObservableObject（MemberImportVisibility 有効のため明示 import が必須）

/// 割当済みショートカット1件（記録カードの一覧と重複判定に使う）。
struct AssignedShortcut: Identifiable {
    let shortcut: ScriptShortcut
    let name: String     // 拡張子を除いたファイル名
    let folder: String   // 親フォルダ名（同名スクリプトの区別用）。ファイルが無い割当は状態（ゴミ箱／未接続／削除済み）
    var isAlias = false  // 行のアイコンに矢印バッジ（強調行が元ファイルかエイリアスかを見分ける。2026-10-23）
    var kind: ScriptKind = .javaScript   // 行のアイコンを種類別に（2026-10-23）
    var isMissing = false   // ファイルが無い（ゴミ箱の中を含む）割当。淡色＋⚠（2026-10-23）

    var id: String { "\(shortcut.keyCode)-\(shortcut.modifiers)" }

    /// 一覧の並び：キー順（1, 2 … A, B …。数字は数値順）→ 同じキーなら修飾キー順。空きキーを探しやすくする。
    static func sorted(_ items: [AssignedShortcut]) -> [AssignedShortcut] {
        items.sorted { ScriptShortcut.keyOrder($0.shortcut, $1.shortcut) }
    }
}

/// 記録中のスクリプトと同じ実体を指す、他の行（元ファイル／エイリアス）の割当（2026-10-22）。
struct RelatedShortcut {
    let shortcut: ScriptShortcut
    let isAlias: Bool   // true＝相手がエイリアス、false＝相手が元ファイル
}

/// ショートカット記録の結果。
enum ShortcutRecordResult {
    case assigned(ScriptShortcut)
    case cleared
    case cancelled
}

@MainActor
final class ShortcutRecorderViewModel: ObservableObject {
    /// 未割当のプレースホルダ文言（コントローラの表示とビューの判定で共有する）。
    static let unassignedLabel = String(localized: "Not Assigned")

    @Published var scriptName = ""
    @Published var scriptIsAlias = false   // 名前の左のアイコンに矢印バッジ（2026-10-23）
    @Published var scriptKind: ScriptKind = .javaScript   // 名前の左のアイコンを種類別に（2026-10-23）
    @Published var comboLabel = ""       // 表示中のキー（候補 → 既存割当 → 未割当 の優先順）
    @Published var liveModifiers = ""    // 押下中の修飾キー（flagsChanged で更新）
    @Published var message = ""
    @Published var canRegister = false   // 候補あり＝「登録」ボタン有効
    @Published var hasCurrent = false    // 既存割当あり＝「解除」ボタン表示
    /// 他スクリプトの割当一覧（記録中のスクリプト自身は除く・表示順に整列済み）。
    @Published var assigned: [AssignedShortcut] = []
    /// 候補が他スクリプトに割当済みならそのキー＝警告表示・一覧の行を強調・ボタンを「置き換える」に。
    @Published var conflict: ScriptShortcut?
    /// 同じスクリプトを指す元ファイル／エイリアスの割当。割当は行ごとに別々なので、同じスクリプトに
    /// 別のキーを付けていることに気づけるよう、案内の帯を出し一覧の該当行を強調する（2026-10-22）。
    @Published var related: [RelatedShortcut] = []
    /// 記録開始のたびに変える。一覧を関連行の位置へスクロールするきっかけ。
    @Published var startToken = UUID()

    var isConflict: Bool { conflict != nil }

    /// 表示中のキー（候補、無ければ既存割当）が修飾なしの Esc＝「Illustrator で Esc が使えなくなる」警告を出す（2026-11-23）。
    @Published var plainEscapeWarning = false

    /// 案内の文言。キーは一覧の強調行で分かるので文には出さない（2026-10-23 ユーザー指定の文面）。
    var relatedNotes: [String] {
        var notes: [String] = []
        if related.contains(where: { !$0.isAlias }) {
            notes.append(String(localized: "The original file already has a shortcut."))
        }
        if related.contains(where: { $0.isAlias }) {
            notes.append(String(localized: "An alias already has a shortcut."))
        }
        return notes
    }

    func isRelated(_ shortcut: ScriptShortcut) -> Bool {
        related.contains { $0.shortcut == shortcut }
    }
}

/// 記録オーバーレイ用のパネル。キー入力を受けるため `canBecomeKey = true`（ボーダーレスは
/// 既定で key になれない）。画面全体を覆うため、メニューバー回避などのフレーム制約
/// （`constrainFrameRect`）も無効化する。
final class RecorderOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// スクリプト個別ショートカットの記録オーバーレイ（仕様書 §5）。
/// スクリプトパネルは key にならない（§6.5）ためキー入力を受けられない。そこで
/// **画面全体を半透明グレーで覆うボーダーレスの nonactivating パネル**（`canBecomeKey = true`）を出し、
/// 中央のカードでキーを記録する。モーダル感で「キー入力待ち」状態を明示し、
/// グレー部分のクリック＝キャンセルで即座に元へ戻れる。カードは動かせない（動かす理由がない）。
///
/// **確定は2段階**：キーを押すと候補として表示されるだけで、「登録」ボタン（または修飾なし Return）で
/// 確定する。キー1打で即保存だと押し間違いがそのまま登録される（2026-07-07 ユーザー指摘で改訂）。
/// **記録中は AppDelegate がグローバルホットキーを止める**（記録対象キーが即発火する事故の防止）。
/// 閉じれば key は Illustrator へ自動で戻る。
@MainActor
final class ShortcutRecorderController: NSObject, NSWindowDelegate {

    private let panel: RecorderOverlayPanel
    private let vm = ShortcutRecorderViewModel()
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var onDone: ((ShortcutRecordResult) -> Void)?
    private var finished = true

    /// 既存の割当と、いま押されたキー候補（「登録」で確定するまで保存しない）。
    private var currentShortcut: ScriptShortcut?
    private var pendingShortcut: ScriptShortcut?

    /// キーを捕捉した直後は true。修飾キーを離し切るまで実況表示を再開しない。
    /// これが無いと、⌥⌘1 と押した瞬間に候補 "⌥⌘1" を表示しても、まだ押さえている
    /// ⌥⌘ の flagsChanged が上書きして「離すまで ⌥⌘ しか見えない」不具合になる（実機確認）。
    private var suppressLiveUntilRelease = false

    var isRecording: Bool { panel.isVisible }

    override init() {
        let panel = RecorderOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .modalPanel   // スクリプトパネル（.floating）より上に重ねる
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        self.panel = panel

        super.init()

        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ShortcutRecorderView(
            vm: vm,
            onRegister: { [weak self] in self?.confirmPending() },
            onClear: { [weak self] in self?.finish(.cleared) },
            onCancel: { [weak self] in self?.finish(.cancelled) }))
    }

    /// applicationWillTerminate から呼ぶ後始末。
    func teardown() {
        removeMonitors()
        panel.orderOut(nil)
    }

    // MARK: - 記録の開始 / 終了

    /// 記録を開始する。`near` はスクリプトパネルの frame（その画面全体を覆う）。
    /// 結果は onDone で1回だけ返す（割当・解除・キャンセルのいずれか）。
    /// `assigned` は他スクリプトの割当一覧（記録中のスクリプト自身は除く）。一覧表示と重複判定に使う。
    /// `related` は同じスクリプトを指す元ファイル／エイリアスの割当（案内と一覧の強調。表示専用）。
    func begin(for item: ScriptItem, current: ScriptShortcut?, near frame: NSRect?,
               assigned: [AssignedShortcut], related: [RelatedShortcut] = [],
               onDone: @escaping (ShortcutRecordResult) -> Void) {
        guard finished || !panel.isVisible else { return }
        self.onDone = onDone
        vm.assigned = AssignedShortcut.sorted(assigned)
        vm.related = related
        vm.startToken = UUID()
        vm.conflict = nil
        finished = false
        currentShortcut = current
        pendingShortcut = nil
        suppressLiveUntilRelease = false
        vm.scriptName = item.name
        vm.scriptIsAlias = item.isAlias
        vm.scriptKind = item.kind
        vm.comboLabel = current?.display ?? ShortcutRecorderViewModel.unassignedLabel
        vm.liveModifiers = ""
        vm.message = String(localized: "Press a key with modifiers (F1–F20 and Esc may be used alone)")
        vm.canRegister = false
        vm.hasCurrent = current != nil
        updatePlainEscapeWarning()
        panel.setFrame(Self.overlayScreen(near: frame), display: true)
        installMonitors()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func finish(_ result: ShortcutRecordResult) {
        guard !finished else { return }
        finished = true
        removeMonitors()
        panel.orderOut(nil)
        let done = onDone
        onDone = nil
        done?(result)
    }

    /// 「登録」（ボタン・修飾なし Return）：候補を確定する。
    private func confirmPending() {
        guard let pending = pendingShortcut else { return }
        finish(.assigned(pending))
    }

    /// 他アプリへの切替等で key を失ったらキャンセル（検索パレットと同じ Spotlight 挙動）。
    func windowDidResignKey(_ notification: Notification) {
        finish(.cancelled)
    }

    // MARK: - キー捕捉

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handleKeyDown(event)
            return nil   // オーバーレイが key の間、keyDown は全て消費する
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = KeyDisplay.carbonModifiers(from: event.modifierFlags)
            if self.suppressLiveUntilRelease {
                // 候補を捕捉した直後：残りの修飾キーを離す過程では実況しない（候補表示を守る）。
                if mods == 0 { self.suppressLiveUntilRelease = false }
                self.vm.liveModifiers = ""
            } else {
                self.vm.liveModifiers = KeyDisplay.modifierSymbols(mods)
            }
            return nil
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let mods = KeyDisplay.carbonModifiers(from: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)

        // Esc はキャンセルにしない（修飾の有無を問わずキーとして記録できる。2026-11-23 ユーザー指定）。
        // キャンセルは「キャンセル」ボタン・グレー部分のクリック・他アプリへの切替で行う。
        if (keyCode == 36 || keyCode == 76), mods == 0 {   // 修飾なし Return → 候補を確定
            confirmPending()
            return
        }
        if (keyCode == 51 || keyCode == 117), mods == 0 {  // 修飾なし Delete → 候補を取り消し
            clearPending()
            vm.message = String(localized: "Press a key with modifiers (F1–F20 and Esc may be used alone)")
            return
        }

        // F キー・Esc 以外は ⌘⌥⌃ のいずれか必須（⇧単独や無修飾は通常入力と衝突するため不可）。
        let hasHardModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasHardModifier || KeyDisplay.functionKeyCodes.contains(keyCode)
                || keyCode == KeyDisplay.escapeKeyCode else {
            clearPending()
            vm.message = String(localized: "Include at least one of ⌘ ⌥ ⌃ (F1–F20 and Esc may be used alone)")
            return
        }

        let shortcut = ScriptShortcut(keyCode: keyCode, modifiers: mods)
        guard !KeyDisplay.isSystemReserved(shortcut) else {   // ⌘⌥Esc／⌘⌥⇧Esc（強制終了）
            clearPending()
            vm.message = String(localized: "\(shortcut.display) is reserved by macOS and cannot be assigned")
            return
        }
        guard !Self.isReserved(shortcut) else {
            clearPending()
            vm.message = String(localized: "\(shortcut.display) is used by a built-in shortcut and cannot be assigned")
            return
        }

        // ここでは保存しない。候補として表示し、「登録」で確定する。
        // 実況表示を止めて候補を即表示（修飾キーはまだ押されたままなので）。
        suppressLiveUntilRelease = true
        vm.liveModifiers = ""
        vm.comboLabel = shortcut.display

        // いまの割当と同じキー：登録しても何も変わらないので確定させない。
        if shortcut == currentShortcut {
            pendingShortcut = nil
            updatePlainEscapeWarning()
            vm.canRegister = false
            vm.conflict = nil
            vm.message = String(localized: "This is the current shortcut")
            return
        }

        pendingShortcut = shortcut
        updatePlainEscapeWarning()
        vm.canRegister = true
        // 他スクリプトに割当済み：警告し、ボタンを「置き換える」にする（確定すると相手の割当は外れる＝後勝ち）。
        // 相手の名前は一覧の強調行で分かるので、警告文には出さない（2026-10-21 ユーザー指定の文面）。
        if vm.assigned.contains(where: { $0.shortcut == shortcut }) {
            vm.conflict = shortcut
            vm.message = String(localized: "\(shortcut.display) is already assigned. Replacing it will remove the shortcut from that script.")
        } else {
            vm.conflict = nil
            vm.message = String(localized: "Click “Register” to confirm (press another key to change)")
        }
    }

    /// 不正なキー（修飾不足・予約キー）が押されたら候補を取り消す。前の候補の重複警告や
    /// 「置き換える」が、別の文言の下に残ったままにならないようにする。
    private func clearPending() {
        pendingShortcut = nil
        vm.comboLabel = currentShortcut?.display ?? ShortcutRecorderViewModel.unassignedLabel
        vm.canRegister = false
        vm.conflict = nil
        updatePlainEscapeWarning()
    }

    /// 修飾なしの Esc を表示中なら警告を出す（候補が無ければ既存割当で判定＝Esc 割当済みのスクリプトを開いたときも出す）。
    private func updatePlainEscapeWarning() {
        vm.plainEscapeWarning = (pendingShortcut ?? currentShortcut).map(KeyDisplay.isPlainEscape) ?? false
    }

    /// 組み込みショートカット（パネル・検索・クリーンペースト。設定で変えたキー）が使っているキー。スクリプトには割り当てない
    /// （2026-10-30。以前は検索 ⇧⌘Space／パネル ⇧⌥⌘Space の固定の予約キー）。
    nonisolated static func isReserved(_ s: ScriptShortcut) -> Bool {
        BuiltInShortcutStore.isUsed(s)
    }

    // MARK: - 覆う画面

    /// スクリプトパネルのある画面（無ければマウスのある画面）の全体 frame。
    private static func overlayScreen(near frame: NSRect?) -> NSRect {
        if let frame,
           let screen = NSScreen.screens.first(where: {
               NSPointInRect(NSPoint(x: frame.midX, y: frame.midY), $0.frame)
           }) {
            return screen.frame
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
            ?? NSScreen.main
        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

/// 記録オーバーレイの中身。半透明グレーが画面を覆い、中央のカードがキー入力を待つ。
/// グレー部分のクリックでキャンセル。押下中の修飾キーを実況表示し、「登録」ボタンで確定する。
struct ShortcutRecorderView: View {
    @ObservedObject var vm: ShortcutRecorderViewModel
    var onRegister: () -> Void
    var onClear: () -> Void
    var onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 黒 32%（2026-10-21 ユーザー指定で 25% から少し暗く）。磨りガラス（NSVisualEffectView）は
            // 「透明度を下げる」ON の環境で不透明グレーになり画面が透けなくなるため不採用。
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            card
        }
    }

    /// 未割当のプレースホルダ文言（キー表示より小さく出す判定に使う）。
    private static let placeholder = ShortcutRecorderViewModel.unassignedLabel

    private var card: some View {
        let keyText = vm.liveModifiers.isEmpty ? vm.comboLabel : vm.liveModifiers
        let isPlaceholder = keyText == Self.placeholder

        return VStack(spacing: 12) {
            // 何のアプリの何の画面かを示すタイトル行
            HStack(spacing: 5) {
                Text("SPAi 4 — Record Shortcut")
                    .font(.subheadline).bold()
                Spacer(minLength: 0)
            }
            .foregroundColor(Color.primary.opacity(0.75))

            // スクリプト名の左にパネルと同じアイコン（エイリアスは矢印バッジ）。アイコンと名前をまとめて中央に置き、
            // 長い名前は名前だけを省略する（2026-10-23 ユーザー指定）。
            HStack(spacing: 5) {
                ScriptIcon(isAlias: vm.scriptIsAlias, kind: vm.scriptKind,
                           size: 13, selected: false)   // 13pt＝.headline
                    .fixedSize()
                    .padding(.leading, 4)   // 矢印バッジは左へ約 4pt はみ出すので、長い名前でも内側に収める
                Text(vm.scriptName)
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Text(keyText)
                .font(.system(size: isPlaceholder ? 16 : 24, weight: .medium))
                .foregroundColor(isPlaceholder ? Color.primary.opacity(0.5) : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)   // プレースホルダとキー表示でカードの高さが変わらないよう固定
                .background(Capsule().fill(Color.primary.opacity(0.06)))   // キー表示の定番＝カプセル形

            if vm.isConflict {
                conflictWarning
            } else {
                Text(vm.message)
                    .font(.body)
                    .foregroundColor(Color.primary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 修飾なしの Esc の警告。重複の警告と同じ帯（2026-11-23 ユーザー指定）。
            if vm.plainEscapeWarning {
                noticeBand(String(localized: "Esc will no longer work in Illustrator."))
            }

            // 元ファイル／エイリアスの割当の案内。重複の警告と同じ帯で示し、一覧の該当行も強調する（2026-10-23）。
            if !vm.relatedNotes.isEmpty {
                noticeBand(vm.relatedNotes.joined(separator: "\n"))
            }

            if !vm.assigned.isEmpty {
                assignedList
            }

            HStack(spacing: 10) {
                if vm.hasCurrent {
                    Button { onClear() } label: {
                        Text("Remove").frame(minWidth: 64)
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel") { onCancel() }
                Button { onRegister() } label: {
                    // 短いラベルだとボタンが窮屈に見えるため、キャンセルと釣り合う最小幅を持たせる
                    Group {
                        if vm.isConflict { Text("Replace") } else { Text("Register") }
                    }
                    .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canRegister)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 420)   // 旧 380。割当一覧の行にアイコンを足した分を広げた（2026-10-23 ユーザー指定）
        // ほんの少しだけ半透明（背後がうっすら透ける）。2026-10-22 ユーザー指定で「ほんの少し明るく」：
        // 不透明度 88% → 94%（暗くした背後が透ける分を減らす）＋白 4% を重ねる（ダークでも明るくなるように）。
        // 2026-11-12 ユーザー指定：ライトは windowBackgroundColor がグレーで陰気（macOS 15・27 とも）→ 白 98% に。ダークは従来どおり。
        .background {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.98))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    /// 重複の警告。文字は濃いまま（オレンジ文字は視認性が悪い＝実機指摘 2026-10-21）、淡い帯で目立たせる。
    /// 警告アイコンは出さない（2026-10-22 ユーザー指定）。
    private var conflictWarning: some View {
        noticeBand(vm.message)
    }

    /// 重複の警告と元ファイル／エイリアスの案内に共通の帯。地は淡いアクセント色
    /// （黄色は安っぽく見えた＝2026-10-23 ユーザー指定で変更）。
    private func noticeBand(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.4)))
    }

    /// 他スクリプトの割当一覧（空きキー探しの助け）。表示専用。重複した行は強調し、見える位置へスクロール。
    private var assignedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Assigned Shortcuts (\(vm.assigned.count))")
                .font(.caption).bold()
                .foregroundColor(Color.primary.opacity(0.75))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.assigned) { entry in
                            assignedRow(entry, highlighted: entry.shortcut == vm.conflict
                                                            || vm.isRelated(entry.shortcut))
                                .id(entry.id)
                        }
                    }
                    .padding(Self.listPadding)
                }
                // 高さは件数に合わせる（1〜8行）。9件以上は8行分で止めてスクロールバーを出す（2026-10-21 ユーザー指定）。
                .frame(height: CGFloat(min(vm.assigned.count, Self.maxVisibleRows)) * Self.rowHeight
                               + Self.listPadding * 2)
                .scrollIndicators(vm.assigned.count > Self.maxVisibleRows ? .visible : .hidden)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
                .onChange(of: vm.conflict) { conflict in
                    guard let conflict else { return }
                    withAnimation {
                        proxy.scrollTo("\(conflict.keyCode)-\(conflict.modifiers)", anchor: .center)
                    }
                }
                // 記録開始時、元ファイル／エイリアスの割当の行が見える位置へ（一覧順で先頭のもの）。
                .onChange(of: vm.startToken) { _ in
                    guard let first = vm.assigned.first(where: { vm.isRelated($0.shortcut) }) else { return }
                    proxy.scrollTo(first.id, anchor: .center)
                }
            }
        }
    }

    private func assignedRow(_ entry: AssignedShortcut, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Text(entry.shortcut.display)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 56, alignment: .trailing)
            HStack(spacing: 4) {   // アイコンは名前に寄せる（カード上部の名前行と同じ並び）
                Group {
                    ScriptIcon(isAlias: entry.isAlias, kind: entry.kind,
                               size: 12, selected: false)   // 12pt＝行の文字
                        .fixedSize()
                        .padding(.leading, 3)   // 矢印バッジが左へはみ出す分、キー表示から離す
                    Text(entry.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .opacity(entry.isMissing ? 0.45 : 1)   // ファイルが無い割当は淡く＋⚠（パネルと同じ。2026-10-23）
                if entry.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
            Text(entry.folder)
                .font(.system(size: 11))
                .foregroundColor(Color.primary.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)   // 長いフォルダ名は中央を省略
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)   // 一覧の高さを行数から正確に決めるため固定
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(highlighted ? Color.accentColor.opacity(0.22) : Color.clear)   // 旧 黄 30%（2026-10-23 アクセント色へ）
            .padding(.vertical, 1))   // 強調行が続いても1行ずつの帯に見えるよう、上下に1ptのすき間
    }

    /// 割当一覧の行の高さ・一覧の内側余白・スクロールせずに見せる最大行数。
    private static let rowHeight: CGFloat = 21
    private static let listPadding: CGFloat = 4
    private static let maxVisibleRows = 8
}
