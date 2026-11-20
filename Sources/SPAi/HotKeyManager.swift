import AppKit
import Carbon

/// グローバルホットキー管理。`RegisterEventHotKey`（Carbon Event Manager）を使用。
/// **Accessibility 権限は不要**（FILL Id で実証済み）。Illustrator 文脈（Illustrator または
/// SPAi 自身が最前面）のときだけ `activate()` で登録する（仕様書 §3-1・§6.4）。
///
/// キー：
/// - 組み込みショートカット（設定の「組み込みショートカット」タブで変更・なしにできる。2026-10-30）。既定は
///   ⇧⌘Space＝検索パレット（§3B。表示中にもう一度押すと閉じるトグル）／⇧⌥⌘Space＝スクリプトパネルの表示/非表示トグル（§3-1）
///   （当初案 ⌥⌘Space は Spotlight/Finder 検索と衝突するため実機確認の上で変更・2026-07-07）／
///   ⌥V＝クリーンペースト／⇧⌥V＝クリーンペースト（トリム）。ペーストの2つは Illustrator そのものが最前面のときだけ登録する
/// - ユーザー割当のスクリプト個別キー（§5。`ShortcutStore` の内容を `setUserShortcuts` で受け取る）
///
/// 個別キーも同じ `RegisterEventHotKey` で登録する。当初案の `KeyboardShortcuts`(sindresorhus) は
/// 採用しない：本アプリはパネルが key にならないため記録 UI を専用パレットに分けるしかなく、
/// 同ライブラリの Recorder ビューが活かせない。TCC 不要という本来の目的は Carbon で満たせている。
@MainActor
final class HotKeyManager {

    /// 組み込みショートカット発火時に呼ばれる。
    var onBuiltIn: ((BuiltInAction) -> Void)?
    /// スクリプト個別キー（§5）発火時に呼ばれる。引数はスクリプトのフルパス。
    var onRunScriptShortcut: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let signature: OSType = 0x53504169  // 'SPAi'

    /// ユーザー割当（パスの昇順で安定化）。登録中の id → パスの対応は idToPath。
    private var userShortcuts: [(path: String, shortcut: ScriptShortcut)] = []
    private var idToPath: [UInt32: String] = [:]
    private var builtIns: [BuiltInAction: ScriptShortcut] = [:]
    private var isActive = false
    /// ペーストの組み込みキーも登録するか（Illustrator そのものが最前面）。直近の `activate` の値を持ち回る。
    private var includesPaste = false
    private static let userIDBase: UInt32 = 1000

    /// 組み込みショートカットの id。1 はテストキー（⌃⌥⌘T）が使っていた（2026-10-21 削除）。
    private static let builtInIDs: [BuiltInAction: UInt32] = [
        .togglePanel: 2, .searchPalette: 3, .cleanPaste: 4, .cleanPasteTrim: 5,
    ]

    /// 全ホットキー（組み込み＋ユーザー割当）を登録する（Illustrator 文脈に入ったら呼ぶ）。
    /// `includePaste` はペーストの組み込みキーも登録するか（Illustrator そのものが最前面のときだけ true）。
    func activate(includePaste: Bool) {
        deactivate()
        isActive = true
        includesPaste = includePaste
        installHandlerIfNeeded()
        for (action, shortcut) in builtIns.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where includePaste || !action.needsIllustratorFrontmost {
            guard let id = Self.builtInIDs[action] else { continue }
            registerWithKeypad(shortcut, rawID: id)
        }
        registerUserShortcuts()
    }

    /// 組み込みショートカットを差し替える（起動時と設定で変えたとき）。有効な間なら、その場で登録し直す。
    func setBuiltInShortcuts(_ map: [BuiltInAction: ScriptShortcut]) {
        builtIns = map
        if isActive { activate(includePaste: includesPaste) }
    }

    /// 全ホットキーを解除する（Illustrator 文脈を離れたら／記録パレット表示中に呼ぶ）。
    func deactivate() {
        isActive = false
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    /// ユーザー割当の一覧を差し替える（AppDelegate が起動時と割当変更時に呼ぶ）。
    /// Illustrator 文脈で有効な間に変わったら、その場で登録し直す。
    func setUserShortcuts(_ map: [String: ScriptShortcut]) {
        userShortcuts = map.sorted { $0.key < $1.key }
            .map { (path: $0.key, shortcut: $0.value) }
        if isActive { activate(includePaste: includesPaste) }
    }

    private func registerUserShortcuts() {
        idToPath.removeAll()
        for (i, entry) in userShortcuts.enumerated() {
            let id = Self.userIDBase + UInt32(i)
            idToPath[id] = entry.path
            registerWithKeypad(entry.shortcut, rawID: id)
        }
    }

    /// 上段の数字はテンキーの同じ数字でも発火させる（同じキー扱い＝旧版と同じ。2026-10-30）
    private func registerWithKeypad(_ shortcut: ScriptShortcut, rawID: UInt32) {
        register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, rawID: rawID)
        if let keypad = KeyDisplay.keypadDigit(for: shortcut.keyCode) {
            register(keyCode: keypad, modifiers: shortcut.modifiers, rawID: rawID)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, rawID: UInt32) {
        let hkID = EventHotKeyID(signature: signature, id: rawID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        } else {
            // 他アプリ/システムが同じキーを既に確保していると失敗し得る。
            NSLog("[SPAi] RegisterEventHotKey(id=%u) failed: %d", rawID, status)
        }
    }

    fileprivate func fire(id: UInt32) {
        if id >= Self.userIDBase {
            if let path = idToPath[id] { onRunScriptShortcut?(path) }
            return
        }
        if let action = Self.builtInIDs.first(where: { $0.value == id })?.key {
            onBuiltIn?(action)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let st = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                if st != noErr { return st }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hkID.id
                Task { @MainActor in manager.fire(id: id) }
                return noErr
            },
            1, &spec, selfPtr, &handlerRef)
    }
}
