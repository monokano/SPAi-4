import AppKit
import SwiftUI

/// アプリのライフサイクルとメニューバー常駐、最前面監視を担う。
/// （雛形段階の疎通確認用テストホットキー ⌃⌥⌘T は 2026-10-21 に撤去。）
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// ⌘キー起動で表示モードをリセットしたことを起動後に知らせる（SPAiApp.init が立てる）。
    static var shouldShowResetAlert = false

    private var statusItem: NSStatusItem?
    private var appSwitchObserver: Any?
    private var volumeObservers: [Any] = []
    private var settingsWindow: NSWindow?
    private var helpWindowController: HelpWindowController?

    private let illustrator = IllustratorController()
    private let appleScriptRunner = AppleScriptRunner()
    private let appLauncher = AppLauncher()
    /// 「SPAi を終了するまで表示しない」が選ばれたら true（AppleScript の複数起動警告。保存しない＝次回起動で戻る）。
    private var suppressMultipleIllustratorWarning = false
    /// 上記の確認アラートを表示中か。表示中に割当キー等で実行が重なり、アラートが入れ子で開くのを防ぐ。
    private var isConfirmingAppleScript = false
    private let hotKeys = HotKeyManager()
    private let scriptStore = ScriptStore()
    private var panelController: ScriptPanelController?
    private var searchPalette: SearchPaletteController?
    private var shortcutRecorder: ShortcutRecorderController?
    private let shortcutTransfer = ShortcutTransferController()

    /// スクリプト個別ショートカット（パス → キー）。ShortcutStore と同期して持つ。
    private var shortcuts: [String: ScriptShortcut] = [:]

    /// 組み込みショートカット（パネル・検索・クリーンペースト。設定の「組み込みショートカット」タブで変更。2026-10-30）。
    /// 起動時に保存から読み込み直す（初回の既定キーの保存は、スクリプトの割当を読み込んでから行うため）。
    private var builtInModel = BuiltInShortcutsModel(shortcuts: [:])
    private lazy var cleanPaste = CleanPasteService(illustrator: illustrator)

    /// 割当ファイルの状態（有無・エイリアス・種類・無い理由）。裏のキューで調べた最新の結果（2026-10-24）。
    /// アプリの切り替えのたびにメインスレッドでファイルを確かめると、応答しないサーバの共有があるとそこで固まる
    /// （付録B-3(c) と同型）。メインスレッドはこの結果を使うだけにする。まだ調べていない割当は使える扱い。
    private var shortcutStates: [String: ShortcutFileState] = [:]
    private let fileCheckQueue = DispatchQueue(label: "com.tama-san.SPAi.file-check", qos: .utility)
    /// 調べている最中か・その間に再確認の要求が来たか（応答しない共有で止まっても要求を積み上げない）
    private var isCheckingStates = false
    private var needsStateRecheck = false

    /// 直近に最前面だった Illustrator（§6.2 の pid 持ち回り）。パネル上部の表示と実行先の両方に使う。
    private var trackedTarget: IllustratorTarget?

    // MARK: - ライフサイクル

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隔離起動（App Translocation）中なら、Finder での移動を案内する（2026-11-09。共有資料 AppTranslocation対策.md）。
        // ほかの起動処理より先に行う（「終了」なら動いている別インスタンスも止めず、設定も書かずに終わる）。
        // 移動すれば出なくなるので毎回出す。「このまま続ける」なら通常どおり起動する。
        if !AppTranslocation.confirmLaunchIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        terminateOtherInstances()               // 二重起動を防ぐ（残存インスタンスのアイコン残りを防止）
        Prefs.registerDefaults()
        applyDisplayMode()                      // 表示モード（メニューバー / Dock / 両方）に従い常駐先を決める

        // 失敗だけをダイアログで知らせる（§8。2026-10-24 に通知センターからダイアログへ）
        let notifyFailure: (String, ScriptFailure) -> Void = { FailureAlert.shared.scriptFailed($0, $1) }
        illustrator.onFailure = notifyFailure
        appleScriptRunner.onFailure = notifyFailure
        appLauncher.onFailure = notifyFailure

        // スクリプトパネル（マウスの道具・仕様書 §3）
        let panel = ScriptPanelController()
        panel.onRun = { [weak self] item in self?.runScript(item.url) }
        panel.viewModel.onAssignShortcut = { [weak self] item in self?.beginShortcutRecording(item) }
        panel.viewModel.onClearShortcut = { [weak self] item in self?.setShortcut(nil, for: item.url.path) }
        panel.viewModel.onOpenSearch = { [weak self] in self?.showSearchPaletteFromMenu() }
        panel.viewModel.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        panelController = panel

        // 検索パレット（キーボードの道具・仕様書 §3B）
        let palette = SearchPaletteController()
        palette.onRun = { [weak self] item in self?.runScript(item.url) }
        searchPalette = palette

        // スクリプト個別ショートカット（§5）：保存済みの割当を読み込み、発火→実行に配線。
        shortcuts = ShortcutStore.load()
        panel.viewModel.updateShortcuts(shortcuts)
        applyAvailableShortcutsToHotKeys()
        refreshShortcutStates()
        hotKeys.onRunScriptShortcut = { [weak self] path in
            self?.runScript(URL(fileURLWithPath: path))
        }

        // 組み込みショートカット：初回だけ既定のキーを保存（スクリプトに割当済みの既定キーは「なし」で始める）してから読み込む
        BuiltInShortcutStore.initializeIfNeeded(scriptShortcuts: shortcuts)
        builtInModel = BuiltInShortcutsModel(shortcuts: BuiltInShortcutStore.load())
        builtInModel.scriptShortcuts = { [weak self] in self?.shortcuts ?? [:] }
        builtInModel.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            // 記録しようとしたキーが即発火しないよう、記録中はホットキーを止める
            if recording {
                self.hotKeys.deactivate()
            } else if self.isIllustratorContext, !(self.shortcutRecorder?.isRecording ?? false) {
                self.activateHotKeys()
            }
        }
        builtInModel.onChange = { [weak self] map in self?.hotKeys.setBuiltInShortcuts(map) }
        builtInModel.onRemoveScriptShortcut = { [weak self] path in self?.setShortcut(nil, for: path) }
        hotKeys.setBuiltInShortcuts(builtInModel.shortcuts)
        hotKeys.onBuiltIn = { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel:    self.togglePanel()
            case .searchPalette:  self.toggleSearchPalette()
            case .cleanPaste:     self.runCleanPaste(trim: false)
            case .cleanPasteTrim: self.runCleanPaste(trim: true)
            }
        }

        // 設定ウィンドウ（アプリメニューの「設定…」）と表示モード変更の通知を受ける。
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings),
                                               name: .openSettingsRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged),
                                               name: .displayModeChanged, object: nil)
        // 設定の「Illustrator が最前面にあるときだけパネルを表示」が切り替わったら即時適用する。
        NotificationCenter.default.addObserver(self, selector: #selector(onlyWithIllustratorChanged),
                                               name: .onlyWithIllustratorChanged, object: nil)
        // ディスプレイ構成の変化（外部ディスプレイの抜き差し・蓋の開閉）でノッチの有無が
        // 変わり得る。実効表示モードを再適用する（ノッチ出現時に「メニューバーのみ」→「両方」）。
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // スクリプトフォルダの走査＋監視。変化があればパネル・パレットを更新する
        // （メニューにはスクリプト一覧を出さないので組み直し不要。2026-10-22 に「登録フォルダ」を削除）。
        scriptStore.onChange = { [weak self] in
            guard let self else { return }
            self.panelController?.viewModel.update(items: self.scriptStore.items,
                                                   includingHidden: self.scriptStore.allItems)
            self.searchPalette?.viewModel.update(items: self.scriptStore.items)
            self.refreshShortcutsAfterScan()
        }
        scriptStore.start()

        // ボリューム（外付けディスク・サーバの共有）の接続／取り外しで再走査する。取り外しでは FSEvents が来ず、
        // 外したボリューム上のスクリプトが走査結果に残って、割当が淡色＋⚠にならなかった（2026-10-23 実機）
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scriptStore.rescan() }   // queue: .main で届く
            }
        }

        // 最前面アプリの監視（Illustrator の出入りでホットキーを有効/無効化）
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.frontmostAppChanged()
        }

        // 前回終了時にパネルを表示していたら復元する（Illustrator 連動 ON で前面にいなければ
        // 自動再表示待ちになり、直後の frontmostAppChanged() 以降の切替で出る）。
        panelController?.restoreVisibilityAtLaunch(illustratorFrontmost: illustrator.isFrontmost)

        frontmostAppChanged()

        // ⌘キー起動での表示モードリセット（SPAiApp.init）を知らせる。
        if Self.shouldShowResetAlert {
            Self.shouldShowResetAlert = false
            let alert = NSAlert()
            alert.messageText = String(localized: "Display Mode Reset")
            alert.informativeText = String(localized: "The display mode has been reset to the default (Menu Bar and Dock).")
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        hotKeys.deactivate()
        scriptStore.stop()
        panelController?.teardown()
        searchPalette?.teardown()
        shortcutRecorder?.teardown()
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers = []
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 終了処理で AppKit がパネルを閉じる（windowWillClose が飛ぶ）前に、
        // この瞬間の表示状態を次回起動用に確定保存する。
        panelController?.saveVisibilityForRelaunch()
        return .terminateNow
    }

    /// 同じ Bundle ID の他インスタンス（古い残存プロセス等）を終了し、常に単一起動にする。
    private func terminateOtherInstances() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let myPid = NSRunningApplication.current.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        where app.processIdentifier != myPid {
            app.forceTerminate()
        }
    }

    // MARK: - 表示モード（メニューバー / Dock / 両方・仕様書 §4）

    /// 設定の表示モードに従い、activationPolicy とメニューバーアイコンの有無を切り替える。
    /// ノッチ機では「メニューバーのみ」を「両方」へ読み替えた実効モードを使う（`resolvedDisplayMode`）。
    private func applyDisplayMode() {
        let mode = Prefs.resolvedDisplayMode
        switch mode {
        case .menuBar:     NSApp.setActivationPolicy(.accessory)
        case .dock, .both: NSApp.setActivationPolicy(.regular)
        }

        let needStatusItem = (mode == .menuBar || mode == .both)
        if needStatusItem {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// 設定画面で表示モードが変わったとき。「メニューバーのみ」への切替は activationPolicy が
    /// .accessory になりアプリごと非アクティブ化されて設定ウィンドウが背面に落ちる。ポリシー変更は
    /// 非同期に反映されるため、少し遅らせて設定ウィンドウを前面へ戻す（FILL Id と同じ対処）。
    @objc private func displayModeChanged() {
        applyDisplayMode()
        if let window = settingsWindow, window.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard window.isVisible else { return }
                self?.bringToFront(window)
            }
        }
    }

    /// ディスプレイ構成が変わったとき（ノッチの出現/消失を含む）に実効表示モードを再適用する。
    @objc private func screenParametersChanged() {
        applyDisplayMode()
    }

    // MARK: - メニューバー

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon(active: illustrator.isFrontmost)
        statusItem = item
        rebuildMenu()
    }

    /// メニューを組み立てて status item に割り当てる（中身は固定なので status item 生成時に1回）。
    /// 素の `NSMenu` で確定（仕様書 §4。当初案の「検索付き `NSPopover`」は検索パレットの分離で廃止）。
    /// 文言の切替・有効/無効は開くたびに `validateMenuItem(_:)` で行う。
    private func rebuildMenu() {
        let menu = NSMenu()

        // 最上部はパネルと検索パレット（2026-10-21 ユーザー指定で整理：状態表示の行「Illustrator ～」と
        // 「テストスクリプトを実行」を削除し、「パネルを表示/隠す」を先頭へ）。状態はアイコンの淡色表示で伝える。
        addPanelAndSearchItems(to: menu)
        menu.addItem(.separator())

        // スクリプト一覧のサブメニュー「登録フォルダ」は削除（2026-10-22 ユーザー指定。スクリプトはパネルと検索パレットから実行する）。
        // フォルダの登録・解除は設定ウィンドウ、Finder で開くのはパネルの右クリック「Finderに表示」で行う。
        // 「再読み込み」は FSEvents の自動再走査で不要になったため削除（2026-07-09・ユーザー確定）。
        // 「Illustrator が最前面にあるときだけパネルを表示」は設定ウィンドウへ移設（2026-10-21）。

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(helpMenuItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Quit SPAi"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        updateAppearance()   // アイコンのグレーアウトを同期
    }

    /// 「パネルを表示/隠す」と「スクリプトを検索…」。メニューバーと Dock の両メニューの先頭に置く。
    /// キー表示は案内用（Dock メニューでは OS がキー表示を出さない）。組み込みショートカットの設定に合わせ、なしなら出さない。
    private func addPanelAndSearchItems(to menu: NSMenu) {
        let showPanel = NSMenuItem(title: panelToggleTitle(),
                                   action: #selector(togglePanelFromMenu), keyEquivalent: "")
        showPanel.target = self
        applyKeyEquivalent(to: showPanel, for: .togglePanel)
        menu.addItem(showPanel)
        let search = NSMenuItem(title: String(localized: "Search Scripts…"),
                                action: #selector(showSearchPaletteFromMenu), keyEquivalent: "")
        search.target = self
        applyKeyEquivalent(to: search, for: .searchPalette)
        menu.addItem(search)
    }

    /// メニュー項目のキー表示を組み込みショートカットの今の設定にそろえる（メニューバーのメニューは開くたびに呼ぶ）。
    private func applyKeyEquivalent(to item: NSMenuItem, for action: BuiltInAction) {
        if let shortcut = builtInModel.shortcuts[action] {
            item.keyEquivalent = KeyDisplay.menuKeyEquivalent(shortcut.keyCode)
            item.keyEquivalentModifierMask = KeyDisplay.cocoaModifiers(shortcut.modifiers)
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Dock メニュー（表示モードが Dock / 両方のとき）

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // 「終了」は OS が自動付加するのでカスタムでは付けない。
        let menu = NSMenu()
        // メニューバーのメニューと同じく、先頭にパネルと検索パレット（2026-10-21 ユーザー指定）。
        addPanelAndSearchItems(to: menu)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(helpMenuItem())
        return menu
    }

    /// 「ヘルプ」（メニューバーと Dock の両メニューで「設定…」の下に置く）。
    private func helpMenuItem() -> NSMenuItem {
        let help = NSMenuItem(title: String(localized: "Help"), action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        return help
    }

    // MARK: - 最前面監視 → ホットキー

    /// Illustrator 文脈か＝Illustrator が最前面、または SPAi 自身が最前面（パネル操作中・ダイアログ表示中）。
    /// SPAi 自身を含めないと「パネルをクリックした瞬間に自分を隠す」自己矛盾になる（仕様書 §6.4）。
    private var isIllustratorContext: Bool {
        if illustrator.isFrontmost { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
            == NSRunningApplication.current.processIdentifier
    }

    private func frontmostAppChanged() {
        // 割当ファイルの有無（ホットキーに登録するもの・一覧の淡色＋⚠・Finderに表示の可否）を見直す。ゴミ箱を空にする・
        // 外付けディスクの抜き差し等は再走査が走らないことがあるため、アプリの切り替えを区切りにする。
        // 調べるのは裏のキュー（メインスレッドでファイルを確かめない＝2026-10-24）。結果が変われば反映される
        refreshShortcutStates()
        // Illustrator に戻ったら、サーバの共有上の登録フォルダを裏で再走査する（他の Mac からの変更は FSEvents が
        // 知らせない。出したままのパネルもこれで追従する。2026-10-24）
        if illustrator.isFrontmost { scriptStore.rescanIfNetworkRoots() }
        let context = isIllustratorContext
        if context, !(shortcutRecorder?.isRecording ?? false), !builtInModel.isRecording {
            activateHotKeys()   // 登録するのは直近の確認で使えた割当（`applyAvailableShortcutsToHotKeys`）
        } else if !context {
            hotKeys.deactivate()
        }
        refreshTrackedTarget()
        if !context { builtInModel.stopRecording() }
        // 「Illustrator が最前面にあるときだけパネルを表示」ON 時の自動隠し/再表示（§6.4）
        if Prefs.showPanelOnlyWithIllustrator {
            if context {
                panelController?.autoShowIfNeeded(illustratorFrontmost: illustrator.isFrontmost)
            } else {
                panelController?.autoHide()
            }
        }
        // 検索パレットは一時表示の道具：Illustrator 文脈を離れたら常に閉じる
        // （通常は resignKey で閉じるが、取りこぼしの保険）。
        if !context {
            searchPalette?.close()
        }
        updateAppearance()
    }

    /// アイコン（通常／淡色）を、Illustrator 最前面かどうかに合わせる。
    /// カラーアイコンなので appearsDisabled ではなく画像の差し替えで表す。
    /// ツールチップは出さない（SPAi ではツールチップを一切使わない。2026-10-26 ユーザー指定）。
    private func updateAppearance() {
        statusItem?.button?.image = menuBarIcon(active: illustrator.isFrontmost)
    }

    /// メニューバー用アイコン。アプリアイコンをメニューバーサイズへ縮小して使う（カラー・FILL Id と同じ方式）。
    /// Illustrator 非最前面時は淡く描いて状態を伝える。
    private func menuBarIcon(active: Bool) -> NSImage? {
        let size = NSSize(width: 19, height: 19)
        guard let source = NSApp.applicationIconImage ?? NSImage(named: "AppIcon") else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: active ? 1.0 : 0.4)
            return true
        }
        image.isTemplate = false  // アプリアイコンの色を活かす
        image.accessibilityDescription = "SPAi"
        return image
    }

    // MARK: - 送信先 Illustrator の持ち回り（§6.2）とパネル上部の表示

    /// 「直近に最前面だった Illustrator」を更新し、パネル上部の表示（アイコン＋名前＋バージョン）に反映する。
    /// 捕捉済みの pid が死んでいたら、起動中の別インスタンスへフォールバック（無ければ未起動表示）。
    private func refreshTrackedTarget() {
        if let t = illustrator.captureFrontmostTarget() {
            trackedTarget = t
        } else if trackedTarget == nil
                    || NSRunningApplication(processIdentifier: trackedTarget!.pid) == nil {
            trackedTarget = illustrator.anyRunningTarget()
        }
        panelController?.viewModel.updateTarget(Self.targetInfo(for: trackedTarget))
    }

    /// パネル上部の控えめな1行表示（例 "Illustrator 2026 (30.5.1)"）。
    private static func targetInfo(for target: IllustratorTarget?) -> PanelTargetInfo? {
        guard let target,
              let app = NSRunningApplication(processIdentifier: target.pid) else { return nil }
        let folderName = IllustratorController.displayName(of: app)   // 例 "Adobe Illustrator 2026"
        let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]
        let icon = app.bundleURL.flatMap { bundleIcon(appURL: $0, info: info) } ?? app.icon
        return PanelTargetInfo(icon: icon, label: targetLabel(folderName: folderName, info: info))
    }

    /// アプリのアイコンを Info.plist の CFBundleIconFile の .icns から直接読む（Glow Ai と同じ方式）。
    /// macOS 26 以降の NSRunningApplication.icon／NSWorkspace.icon(forFile:) は、Icon Composer 形式の
    /// アイコンを持たないアプリ（Adobe 製品など）のアイコンを縮めてグレーの角丸の枠に入れて返すため、
    /// 15pt のヘッダでは視認性が悪い。読めなければ nil（呼び出し側で従来の app.icon に戻す）
    private static func bundleIcon(appURL: URL, info: [String: Any]) -> NSImage? {
        guard let name = info["CFBundleIconFile"] as? String, !name.isEmpty else { return nil }
        let file = name.hasSuffix(".icns") ? name : name + ".icns"
        return NSImage(contentsOf: appURL.appendingPathComponent("Contents/Resources/\(file)"))
    }

    /// 送信先の表示名。正式版は "Illustrator 2026 (30.8.2)"（フォルダ名＋バージョン。従来どおり）。
    /// 非正式版（インストールフォルダ名に Beta／Prerelease）は AVer と同じ表記で
    /// "Illustrator 2027 (Beta) (31.0.0 #64)"（2026-10-26 ユーザー指定）。フォルダ名に年が無い
    /// （"Adobe Illustrator (Beta)"）ので年はメジャー番号＋1996、ビルドはバージョンの4つ目か
    /// Info.plist の "Adobe Product Build"（数値なら " #64"、数値でなければ ", 名前"）。
    static func targetLabel(folderName: String, info: [String: Any]) -> String {
        var name = folderName
        if name.hasPrefix("Adobe ") { name.removeFirst("Adobe ".count) }
        let version = info["CFBundleShortVersionString"] as? String ?? ""

        let releaseLabel = folderName.contains("Beta") ? "Beta"
            : folderName.contains("Prerelease") ? "Prerelease" : ""
        guard !releaseLabel.isEmpty, !version.isEmpty else {
            return version.isEmpty ? name : "\(name) (\(version))"
        }

        // バージョンを X.Y.Z にそろえ、4つ目があればビルド番号として外す（AVer の解析と同じ）
        var parts = version.components(separatedBy: ".")
        if parts.count == 2 { parts.append("0") }
        var build = parts.count >= 4 ? parts[3] : ""
        parts = Array(parts.prefix(3))
        if build.isEmpty { build = info["Adobe Product Build"] as? String ?? "" }

        name = name.replacingOccurrences(of: " (\(releaseLabel))", with: "")
            .replacingOccurrences(of: " \(releaseLabel)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let major = Int(parts[0]), major >= 24, !name.contains("\(major + 1996)") {
            name += " \(major + 1996)"
        }
        let buildSuffix = build.isEmpty ? ""
            : build.allSatisfy(\.isNumber) ? " #\(build)" : ", \(build)"
        return "\(name) (\(releaseLabel)) (\(parts.joined(separator: "."))\(buildSuffix))"
    }

    // MARK: - スクリプト個別ショートカット（§5）

    /// 行末バッジ・コンテキストメニューからの割当開始。記録パレット（key を取る）を出す間、
    /// グローバルホットキーを止めて「記録しようとしたキーが即発火する」事故を防ぐ。
    private func beginShortcutRecording(_ item: ScriptItem) {
        let recorder = shortcutRecorder ?? ShortcutRecorderController()
        shortcutRecorder = recorder
        guard !recorder.isRecording else { return }
        // 無いファイル（ゴミ箱の中・取り外したボリューム上を含む）の割当は変更させない（右クリックで解除する）。
        // パネルのバッジは淡色の行で押せないが、一覧の判定が古いときの保険（2026-10-23）
        guard ScriptItem.isAvailable(item.url.path) else { NSSound.beep(); return }

        // 記録中のスクリプト自身を除いた割当一覧（記録カードの一覧表示と重複警告に使う）。
        // ファイルの状態は裏で調べた最新の結果を使う（ここでは割当の数だけファイルを確かめない＝2026-10-24）
        let assigned = shortcuts
            .filter { $0.key != item.url.path }
            .map { path, shortcut in
                let url = URL(fileURLWithPath: path)
                let state = shortcutStates[path]
                let status = state?.missing.map(Self.missingStatus)
                return AssignedShortcut(shortcut: shortcut,
                                        name: url.deletingPathExtension().lastPathComponent,
                                        folder: status ?? url.deletingLastPathComponent().lastPathComponent,
                                        isAlias: state?.isAlias ?? false,
                                        kind: state?.kind ?? .javaScript,
                                        isMissing: !(state?.isAvailable ?? true))
            }

        hotKeys.deactivate()
        recorder.begin(for: item,
                       current: shortcuts[item.url.path],
                       near: panelController?.frame,
                       assigned: assigned,
                       related: relatedShortcuts(for: item)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .assigned(let shortcut): self.setShortcut(shortcut, for: item.url.path)
            case .cleared:                self.setShortcut(nil, for: item.url.path)
            case .cancelled:              break
            }
            if self.isIllustratorContext { self.activateHotKeys() }
        }
    }

    /// ホットキーを登録する。クリーンペーストの組み込みキーは Illustrator そのものが最前面のときだけ
    /// （SPAi 自身が前面のときに登録すると、検索パレットの検索欄などで ⌥V が打てなくなる。2026-10-30）。
    private func activateHotKeys() {
        hotKeys.activate(includePaste: illustrator.isFrontmost)
    }

    /// クリーンペースト（組み込みショートカット）。押した瞬間に最前面の Illustrator へ流し込む。
    /// ダイアログ（失敗・AppleScript の確認）の表示中は黙って無視する。
    private func runCleanPaste(trim: Bool) {
        guard !isConfirmingAppleScript, !FailureAlert.shared.isPresenting,
              let target = illustrator.captureFrontmostTarget() else { return }
        cleanPaste.run(target: target, trim: trim)
    }

    /// ファイルが無い割当の、記録カードのフォルダ名欄に出す状態（2026-10-23 ユーザー指定）。元のフォルダ名だと
    /// まだそこにあるように見えて紛らわしいため、状態を出す。割当の場所は元のまま（ゴミ箱へは付け替えない）なので、
    /// 今の場所はブックマークで調べる（`ShortcutStore.inspect` が裏で判定した理由を表示にする）。
    /// - ゴミ箱の中にある →「ゴミ箱」（戻せば使える）
    /// - 元の場所のボリューム（外付けディスク・サーバの共有）がつながっていない →「未接続」
    ///   （つなげば使える。削除と区別する。「ディスク未接続」はサーバで違和感があった）。ボリューム名は出さない
    ///   （行に出すと英語で大きく省略された＝2026-10-23。ツールチップで出していたが、SPAi ではツールチップを使わない＝2026-10-26）
    /// - それ以外 →「削除済み」
    nonisolated private static func missingStatus(_ reason: ShortcutFileState.MissingReason) -> String {
        switch reason {
        case .trash:
            return String(localized: "Trash")
        case .notConnected:
            return String(localized: "Not Connected")
        case .deleted:
            return String(localized: "Deleted")
        }
    }

    /// 記録中のスクリプトと同じ実体を指す、他の行（元ファイル／エイリアス）の割当（2026-10-22）。
    /// 割当は行ごとに別々（エイリアスは別の入口として扱う）なので、照合は実体のパスで行う。
    /// 解決が要るのはエイリアスだけ（割当は数件なので毎回解決して軽い）。
    private func relatedShortcuts(for item: ScriptItem) -> [RelatedShortcut] {
        let target = ScriptItem.resolvedURL(item.url).standardizedFileURL.path
        var related: [RelatedShortcut] = []
        for (path, shortcut) in shortcuts where path != item.url.path {
            let url = URL(fileURLWithPath: path)
            let isAlias = ScriptItem.isAlias(url)
            guard isAlias || item.isAlias,   // 元ファイル同士は同じ実体になり得ない
                  ScriptItem.resolvedURL(url).standardizedFileURL.path == target else { continue }
            related.append(RelatedShortcut(shortcut: shortcut, isAlias: isAlias))
        }
        return related
    }

    /// 再走査のたびに保存済みショートカットを読み直す。`ShortcutStore.load()` がブックマークで
    /// 改名・移動を解決してキーを付け替えるので、割当がファイルに追随する（バッジ表示・発火先とも）。
    private func refreshShortcutsAfterScan() {
        let latest = ShortcutStore.load()
        if latest != shortcuts {
            shortcuts = latest
            panelController?.viewModel.updateShortcuts(shortcuts)
            applyAvailableShortcutsToHotKeys()
        }
        // 割当が同じでもファイルの有無（ゴミ箱へ入れた・戻した等）は変わり得るので、毎回見直す（裏で）
        refreshShortcutStates()
    }

    /// 割当のうち、ファイルが使える（実在し、ゴミ箱の中ではない）ものだけをグローバルキーに登録する（2026-10-23）。
    /// 無いファイルの割当は記録に残したまま（外付けディスクを外した等で一時的に無いだけかもしれない）、キーだけ
    /// 解放して Illustrator 側で使えるようにする。ファイルが戻れば、再走査か Illustrator の前面化で再登録される。
    /// 有無は裏で調べた `shortcutStates` を使い、ここではファイルを確かめない（まだ調べていない割当は使える扱い）。
    private func applyAvailableShortcutsToHotKeys() {
        hotKeys.setUserShortcuts(shortcuts.filter { shortcutStates[$0.key]?.isAvailable ?? true })
    }

    /// 割当ファイルの状態を裏のキューで調べ直し、結果が変わったらホットキーと一覧に反映する（2026-10-24）。
    /// 調べている最中に呼ばれたら、終わってからもう一度だけ調べる（応答しない共有で止まっても要求を積み上げない）。
    private func refreshShortcutStates() {
        guard !isCheckingStates else {
            needsStateRecheck = true
            return
        }
        isCheckingStates = true
        let paths = Array(shortcuts.keys)
        // 外側のクロージャも weak で受ける（内側だけ weak だと、外側が self を暗黙に強参照して食い違う＝
        // Xcode 27 の警告 ImplicitStrongCapture。2026-11-15）
        fileCheckQueue.async { [weak self] in
            let states = ShortcutStore.inspect(paths)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCheckingStates = false
                self.applyShortcutStates(states)
                if self.needsStateRecheck {
                    self.needsStateRecheck = false
                    self.refreshShortcutStates()
                }
            }
        }
    }

    private func applyShortcutStates(_ states: [String: ShortcutFileState]) {
        guard states != shortcutStates else { return }
        shortcutStates = states
        applyAvailableShortcutsToHotKeys()
        panelController?.viewModel.updateShortcutStates(states)
    }

    /// 割当の保存と反映（nil で解除）。同じキーが他のスクリプトに付いていたら外す（後勝ち）。
    private func setShortcut(_ shortcut: ScriptShortcut?, for path: String) {
        if let shortcut {
            for (p, s) in shortcuts where s == shortcut && p != path {
                shortcuts[p] = nil
            }
            shortcuts[path] = shortcut
        } else {
            shortcuts[path] = nil
        }
        replaceShortcuts(shortcuts)
    }

    /// 割当全体を差し替えて保存・反映する（設定の「読み込む…」からも使う）。
    private func replaceShortcuts(_ map: [String: ScriptShortcut]) {
        shortcuts = map
        ShortcutStore.save(shortcuts)
        applyAvailableShortcutsToHotKeys()
        panelController?.viewModel.updateShortcuts(shortcuts)
        refreshShortcutStates()   // 新しい割当のファイルの状態（エイリアス・種類など）を調べる
    }

    /// 設定の「書き出す…」：割当を登録フォルダからの相対パスでファイルへ（別の Mac への移行用）。
    private func exportShortcuts() {
        shortcutTransfer.export(shortcuts: shortcuts, roots: scriptStore.rootURLs, from: settingsWindow)
    }

    /// 設定の「読み込む…」：ファイルを選び、照合結果の確認シートで確定したら割当を差し替える。
    private func importShortcuts() {
        shortcutTransfer.importShortcuts(roots: scriptStore.rootURLs,
                                         current: { [weak self] in self?.shortcuts ?? [:] },
                                         from: settingsWindow) { [weak self] map in
            self?.replaceShortcuts(map)
        }
    }

    /// 設定の「SPAi 3から読み込む…」：旧版（Xojo 版）の設定ファイルを照合し、確認シートで確定したら割当を差し替える。
    private func importLegacyShortcuts() {
        shortcutTransfer.importLegacyShortcuts(roots: scriptStore.rootURLs,
                                               current: { [weak self] in self?.shortcuts ?? [:] },
                                               from: settingsWindow) { [weak self] map in
            self?.replaceShortcuts(map)
        }
    }

    // MARK: - スクリプト実行 / フォルダ操作

    /// スクリプトを実行する。パネル・メニュー・個別キー共通の実行経路。
    /// .jsx/.js は Illustrator へ pid 指定の `do javascript`、AppleScript は `osascript`、
    /// .app（アプレット・ふつうのアプリ）は起動（2026-10-23）。
    /// 送信先は「実行の瞬間の最前面」→「直近に最前面だった Illustrator（§6.2 の持ち回り。
    /// パネル上部に表示しているもの）」→「起動中のどれか」の順で決める。
    /// 「Illustrator が起動していない」「ファイルが無い」は知らせない（パネル上部の表示・淡色＋⚠ の行で分かる。
    /// 2026-10-23 ユーザー指定）。前の実行中で無視したときと、実行の失敗はダイアログで知らせる（`FailureAlert`）。
    private func runScript(_ url: URL) {
        // AppleScript の確認アラート・失敗のダイアログの表示中は、ダイアログが見えているので黙って無視する
        guard !isConfirmingAppleScript, !FailureAlert.shared.isPresenting else { return }
        guard !illustrator.isBusy && !appleScriptRunner.isBusy && !appLauncher.isBusy else {
            FailureAlert.shared.scriptIgnoredBusy(url.deletingPathExtension().lastPathComponent)
            return
        }
        guard ScriptItem.isAvailable(url.path) else {   // 無い／ゴミ箱の中（一覧の淡色の行など）
            NSLog("[SPAi] Script not found: %@", url.path)
            return
        }
        let tracked = trackedTarget.flatMap {
            NSRunningApplication(processIdentifier: $0.pid) != nil ? $0 : nil
        }
        let target = illustrator.captureFrontmostTarget() ?? tracked ?? illustrator.anyRunningTarget()
        let kind = ScriptItem.kind(of: url)

        // AppleScript（アプレット含む）は送信先を選べない（Illustrator が起動していなくても実行はできる＝スクリプト次第）
        if kind.usesAppleScript {
            guard confirmAppleScriptTarget(expected: target) else { return }
        }
        switch kind {
        case .javaScript:
            guard let target else {
                NSLog("[SPAi] Illustrator is not running")
                return
            }
            illustrator.runFile(ScriptItem.resolvedURL(url), target: target)
        case .appleScript:
            appleScriptRunner.run(ScriptItem.resolvedURL(url))
        case .applet, .app:
            appLauncher.launch(ScriptItem.resolvedURL(url), guardsUntilExit: kind == .applet)
            // 起動したアプリ（アプレットのダイアログ等）が Illustrator の後ろに隠れないよう、前面を戻さない
            return
        }
        guard let target else { return }
        // 検索欄がフォーカスを持ったままだと以後のキー入力が Illustrator に届かないので、
        // 実行を区切りにキーボードを対象 Illustrator へ返す（仕様書 §6.5）。
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    /// AppleScript の実行前確認。Illustrator（Beta を含む）が複数起動していると、AppleScript はどのバージョンに
    /// 届くか分からない（付録B-3(a)。Beta にも届く＝ステップ31）ので、確認のアラートを出す。実行してよければ true（2026-10-23）。
    /// 「SPAi を終了するまで表示しない」を選ぶと以後は確認しない（保存しない）。
    private func confirmAppleScriptTarget(expected target: IllustratorTarget?) -> Bool {
        guard !suppressMultipleIllustratorWarning, IllustratorController.runningCount >= 2 else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Multiple versions of Illustrator are running")
        if let target {
            alert.informativeText = String(localized: "AppleScript can’t choose which Illustrator to send to, so the script may run in a version other than \(target.name).")
        } else {
            alert.informativeText = String(localized: "AppleScript can’t choose which Illustrator to send to, so the script may run in a version you didn’t intend.")
        }
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t show this again until SPAi quits")

        // パネルは key にならない（nonactivating）ので、アラートを前面に出すため SPAi を一時的にアクティブにする。
        // 実行後は呼び出し側が送信先の Illustrator をアクティブに戻す。
        NSApp.activate(ignoringOtherApps: true)
        isConfirmingAppleScript = true
        let response = alert.runModalAboveOtherApps()   // Illustrator をクリックしても背面に隠れない
        isConfirmingAppleScript = false
        if alert.suppressionButton?.state == .on {
            suppressMultipleIllustratorWarning = true
        }
        guard response == .alertFirstButtonReturn else {
            if let target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
            return false
        }
        return true
    }

    /// 検索パレットを表示（メニューから。ホットキー ⇧⌘Space と同じ）。
    @objc private func showSearchPaletteFromMenu() {
        scriptStore.rescanIfNetworkRoots()
        searchPalette?.show()
    }

    /// パネル・検索パレットの表示/非表示（ホットキー・メニュー共通）。開くときは、サーバの共有上の登録フォルダが
    /// あれば裏で再走査する（他の Mac からの追加・変更は FSEvents が知らせないため。2026-10-24）。
    /// 一覧はいったん前回の走査結果で出て、走査が終われば更新される。
    private func togglePanel() {
        if panelController?.isVisible == false { scriptStore.rescanIfNetworkRoots() }
        panelController?.toggle()
    }

    private func toggleSearchPalette() {
        if searchPalette?.isVisible == false { scriptStore.rescanIfNetworkRoots() }
        searchPalette?.toggle()
    }

    /// パネルの表示/非表示（メニューから。ホットキー ⇧⌥⌘Space と同じ）。
    @objc private func togglePanelFromMenu() {
        togglePanel()
    }

    /// 「パネルを表示」/「パネルを隠す」：今の表示状態が分かるよう、押したときの動作を文言にする（2026-10-22 ユーザー指定）。
    /// メニューバーのメニューは使い回すので、開くたびに `validateMenuItem(_:)` で付け直す。
    private func panelToggleTitle() -> String {
        panelController?.isVisible == true
            ? String(localized: "Hide Panel")
            : String(localized: "Show Panel")
    }

    /// 設定ウィンドウで「Illustrator が最前面にあるときだけパネルを表示」が切り替わった。
    /// OFF にしたとき自動隠し中のパネルを戻すため、再表示を先に試してから現在の前面状態で判定し直す。
    @objc private func onlyWithIllustratorChanged() {
        if !Prefs.showPanelOnlyWithIllustrator {
            panelController?.autoShowIfNeeded()
        }
        frontmostAppChanged()   // ON にした瞬間に、Illustrator 文脈でなければ隠す
    }

    // MARK: - ヘルプウィンドウ

    /// バンドルしたヘルプブックを表示する（ヘルプメニューの ⌘? とメニューバー／Dock の「ヘルプ」から）。
    @objc func openHelp() {
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    // MARK: - 設定ウィンドウ

    @objc private func showSettings() {
        openSettingsWindow()
    }

    /// 設定ウインドウ。「一般」「フォルダ」「パネル」「ショートカット」の4タブ（macOS 標準のツールバー型。
    /// 2026-11-15 ユーザー指定で「一般」「スクリプト」「ショートカット」の3タブから整理）。
    /// ウインドウの大きさはタブごとの中身（`preferredContentSize`）に合わせて切り替わる。
    private func openSettingsWindow() {
        if settingsWindow == nil {
            let general = NSHostingController(rootView: GeneralSettingsView())
            let folders = NSHostingController(rootView: FoldersSettingsPage(scriptStore: scriptStore))
            let panel = NSHostingController(rootView: PanelSettingsPage())
            let shortcuts = NSHostingController(rootView: ShortcutsSettingsPage(
                builtInModel: builtInModel,
                onExportShortcuts: { [weak self] in self?.exportShortcuts() },
                onImportShortcuts: { [weak self] in self?.importShortcuts() },
                onImportLegacyShortcuts: { [weak self] in self?.importLegacyShortcuts() }))
            general.sizingOptions = [.preferredContentSize]
            folders.sizingOptions = [.preferredContentSize]
            panel.sizingOptions = [.preferredContentSize]
            shortcuts.sizingOptions = [.preferredContentSize]
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            // 並びは「一般」「パネル」「登録」「ショートカット」（2026-11-28 ユーザー指定で「パネル」を「一般」の右へ。
            // 「フォルダ」タブは同日に ja 表記を「登録」・アイコンを plus.app に変更＝英語は Folders のまま）。
            // 「パネル」のアイコンだけ自前の SVG（Assets の `PanelTabIcon`＝テンプレート画像・高さ 22pt）。
            let pages: [(NSViewController, String, NSImage?)] = [
                (general, String(localized: "General"), NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)),
                (panel, String(localized: "Panel"), Self.panelTabIcon()),
                (folders, String(localized: "Folders"), NSImage(systemSymbolName: "plus.app", accessibilityDescription: nil)),
                (shortcuts, String(localized: "Shortcuts"), NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)),
            ]
            for (vc, title, image) in pages {
                vc.title = title
                let item = NSTabViewItem(viewController: vc)
                item.label = title
                image?.accessibilityDescription = title
                item.image = image
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.title = String(localized: "General")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            restoreFrameOrCenter(window, name: "SPAiSettingsWindow")
            settingsWindow = window
        }
        // 窓は使い回すので、開くたびに外部で変わり得る状態（ログイン項目）を読み直させる
        NotificationCenter.default.post(name: .settingsWindowWillShow, object: nil)
        if let window = settingsWindow { bringToFront(window) }
    }

    /// 設定「パネル」タブのアイコン。SVG（縦長 82.13×104.69）を縦横比を保って高さ 22pt で描く。
    /// ⚠️ ツールバーは SF Symbols 以外の画像を約 32pt の枠いっぱいに拡大する（`size` を 22pt にしても
    /// 実測 31pt になりラベルにかぶった）。そこで 32pt 四方の透明な画像の中央に 22pt で描いて渡す
    /// （オフスクリーン描画の実測で高さ 22pt・歯車アイコンと同じ縦位置＝2026-11-28）。
    private static func panelTabIcon() -> NSImage? {
        guard let source = NSImage(named: "PanelTabIcon") else { return nil }
        let slot: CGFloat = 32, height: CGFloat = 22
        let aspect = source.size.height > 0 ? source.size.width / source.size.height : 82.13 / 104.69
        let width = height * aspect
        let image = NSImage(size: NSSize(width: slot, height: slot), flipped: false) { _ in
            source.draw(in: NSRect(x: (slot - width) / 2, y: (slot - height) / 2, width: width, height: height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// ウィンドウ位置を記憶する。`name` でフレームを自動保存し、保存済みがあれば復元、なければ中央に置く。
    /// 高さは SwiftUI コンテンツ（fixedSize）で決まるため、**表示前に**レイアウトを確定（`fittingSize` に
    /// 合わせる）してから左上で再配置する。これで表示時にリサイズ＝上端の移動が起きず、ちらつかない。
    private func restoreFrameOrCenter(_ window: NSWindow, name: String) {
        window.setFrameAutosaveName(name)          // 以後の移動を自動保存
        let restored = window.setFrameUsingName(name)
        // 復元できたら、保存フレームの左上（上端位置）を控えておく。
        let savedTopLeft = restored ? NSPoint(x: window.frame.minX, y: window.frame.maxY) : nil

        // 表示前にコンテンツ高さを確定させる（setFrameUsingName の保存サイズは自然サイズに戻す）。
        if let contentView = window.contentView {
            contentView.layoutSubtreeIfNeeded()
            window.setContentSize(contentView.fittingSize)
        }

        if let topLeft = savedTopLeft {
            window.setFrameTopLeftPoint(topLeft)   // 保存位置（左上）へ再配置
        } else {
            window.center()                        // 初回（保存なし）のみ中央
        }
    }

    /// ウィンドウを最前面に出し、SPAi をアクティブにする。
    /// Illustrator が最前面のときに設定を開くと、ドキュメントウィンドウの背後に隠れることがある。
    /// `NSApp.activate` だけでは隠れることがあるため、`orderFrontRegardless()` で確実に前面化する。
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// メニュー表示の直前に呼ばれる（メニューバー・Dock とも）。
    /// - 「パネルを表示/隠す」：文言を現在の状態に合わせる。常に有効——Illustrator が最前面でなくても出せるのは
    ///   便利（他のアプリの作業中でもショートカットの登録などができる。旧 v3 は Illustrator 最前面のときしか出せず
    ///   不便だった＝2026-10-24 ユーザー判断）。
    /// - 「スクリプトを検索…」：ホットキー（⇧⌘Space）と同じく Illustrator 文脈（Illustrator か SPAi 自身が最前面）の
    ///   ときだけ有効。それ以外はグレーアウト（2026-10-24 ユーザー指定）。メニューを開いても最前面のアプリは
    ///   切り替わらないので、開いた時点の判定がそのまま使える。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePanelFromMenu) {
            menuItem.title = panelToggleTitle()
            applyKeyEquivalent(to: menuItem, for: .togglePanel)
        }
        if menuItem.action == #selector(showSearchPaletteFromMenu) {
            applyKeyEquivalent(to: menuItem, for: .searchPalette)
            return isIllustratorContext
        }
        return true
    }
}
