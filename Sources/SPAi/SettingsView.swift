import SwiftUI
import AppKit
import ServiceManagement
import Combine   // ObservableObject（MemberImportVisibility 有効のため明示 import が必須）
import UniformTypeIdentifiers   // 登録フォルダの一覧へのドロップ（UTType.fileURL）

/// 設定ウインドウは「一般」「フォルダ」「パネル」「ショートカット」の4タブ（2026-11-15 ユーザー指定＝1タブ1対象：
/// アプリ／登録フォルダ／パネル／キー。2026-10-30〜は「一般」「スクリプト」「ショートカット」の3タブで、パネルの設定が
/// 「一般」と「スクリプト」に分かれていた。それ以前は「一般」に全セクションを縦に並べ、「組み込みショートカット」を別タブ）。
/// 各タブは SwiftUI の標準フォーム（`Form`＋`.formStyle(.grouped)`）＝白い地に薄いグレーの角丸カード。
/// macOS 26 でウインドウの地がほぼ白になり、旧来のフラットレイアウト（区切り線で分ける）ではまとまりが分からなくなったため、
/// 2026-11-09 に OS 純正の設定画面と同じ部品へ移した（共有資料「設定ウインドウ_macOS26のカード型レイアウト.md」・ステップ89）。
/// 各部品は `Section` を返し、ここで1つの `Form` に入れる。オン／オフはスイッチ（登録フォルダの表示切り替えだけチェックボックス）。
/// 項目は1画面に収まるのでスクロールを止め、内容の高さをそのままウインドウの高さにする。幅は `settingsWidth`。
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 設定ウインドウの幅（全タブ共通）。グループ化したフォームは左右の余白が大きいので、2026-11-09 の移行で 380pt から広げた
/// （「SPAi 3から読み込む…」を含むボタン3つ・「クリーンペースト（トリム）」の行が日本語で1行に収まる幅。モックで確認）。
let settingsWidth: CGFloat = 460

/// 見出しとその下の説明（システム設定の「ログイン時に開く／以下の項目が…」と同じ形。2026-11-10）。
/// 見出しは Section のヘッダーの書式のまま、説明は通常ウェイトの小さめの淡色。
struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 「一般」タブ：表示モード／ログイン時に起動。
struct GeneralSettingsView: View {
    var body: some View {
        SettingsPage {
            DisplayModeSettingsView()
            LaunchAtLoginSettingsView()
        }
    }
}

/// 「フォルダ」タブ：登録フォルダだけ（2026-11-15 に「スクリプト」タブから独立）。
struct FoldersSettingsPage: View {
    @ObservedObject var scriptStore: ScriptStore

    var body: some View {
        SettingsPage {
            FoldersSettingsView(scriptStore: scriptStore)
        }
    }
}

/// 「パネル」タブ：Illustrator が最前面にあるときだけパネルを表示・リストの文字サイズ・スクリプトを実行・
/// ショートカット一覧をキー順に並べる（2026-11-15。旧「スクリプト」タブの下半分＋「一般」にあった最前面のスイッチ）。
struct PanelSettingsPage: View {
    var body: some View {
        SettingsPage {
            PanelSettingsView()
        }
    }
}

/// 「ショートカット」タブ：組み込みショートカット／スクリプトのショートカットの書き出し・読み込み
/// （書き出し・読み込みは 2026-10-30 に「一般」の最下部から移設）。
struct ShortcutsSettingsPage: View {
    @ObservedObject var builtInModel: BuiltInShortcutsModel
    var onExportShortcuts: () -> Void = {}
    var onImportShortcuts: () -> Void = {}
    var onImportLegacyShortcuts: () -> Void = {}

    var body: some View {
        SettingsPage {
            BuiltInShortcutsSettingsView(model: builtInModel)
            ShortcutsSettingsView(onExport: onExportShortcuts, onImport: onImportShortcuts,
                                  onImportLegacy: onImportLegacyShortcuts)
        }
    }
}

// MARK: - パネル

/// パネルの設定。「リストの文字サイズ」と、その下の「スクリプトを実行」（2026-10-30 追加）。
/// 見出し「スクリプトパネル」（2026-11-01）。ポップアップは標準フォームの形＝ラベルが左・ポップアップが右端（2026-11-09）。
/// その下に「ショートカット一覧をキー順に並べる」（2026-10-30 ユーザー指定で最下部のセクションから移設。
/// 「Illustrator が最前面にあるときだけパネルを表示」も一度ここへ移したが、同日ユーザー指定で「ログイン時に起動」の上へ戻した）。
/// 2026-11-15 の4タブ化で「パネル」タブの唯一のカードになったので見出しを外し（タブ名と重なる）、
/// 「Illustrator が最前面にあるときだけパネルを表示」を先頭に置いた（いつ出るか → 見え方 → 操作の順。ユーザー確定）。
/// 2026-11-28 ユーザー指定で見出し「スクリプトパネル」を戻した（スクリプトパネルの設定であることを明示する）。
struct PanelSettingsView: View {
    @AppStorage(Prefs.onlyWithIllustratorKey) private var onlyWithIllustrator = true
    @AppStorage(Prefs.listTextSizeKey) private var rawTextSize: String = ListTextSize.medium.rawValue
    @AppStorage(Prefs.runOnSingleClickKey) private var runOnSingleClick = false
    @AppStorage(Prefs.sortPanelShortcutsByKeyKey) private var sortByKey = true

    var body: some View {
        Section("Script Panel") {
            // 2026-10-21 にメニューバーのメニューから設定へ移設。2026-11-15 に「一般」からここへ
            Toggle("Show Panel Only When Illustrator Is Frontmost", isOn: $onlyWithIllustrator)
                .onChange(of: onlyWithIllustrator) { _ in
                    // パネルの自動隠し/再表示を即時に反映させる（AppDelegate が受ける）
                    NotificationCenter.default.post(name: .onlyWithIllustratorChanged, object: nil)
                }
            // パネルのリスト文字サイズ（スクリプト名基準。アイコン・フォルダ行も連動）
            Picker("List Text Size", selection: $rawTextSize) {
                ForEach(ListTextSize.allCases) { size in
                    Text(size.label).tag(size.rawValue)
                }
            }
            .pickerStyle(.menu)
            // パネルのスクリプト行をダブルクリック／シングルクリックのどちらで実行するか（既定はダブルクリック）
            Picker("Run Scripts", selection: $runOnSingleClick) {
                Text("Double-Click").tag(false)
                Text("Single-Click").tag(true)
            }
            .pickerStyle(.menu)
            // パネルの「ショートカット付きのみ表示」の並び順。既定 ON＝キー順（記録カードの一覧と同じ）。OFF で名前順
            // （2026-10-28 に「名前順に並べる（既定 OFF）」で追加、2026-10-30 ユーザー指定で表記と向きを反転）
            Toggle("Sort Shortcut List by Key", isOn: $sortByKey)
                .onChange(of: sortByKey) { _ in
                    NotificationCenter.default.post(name: .panelShortcutSortChanged, object: nil)
                }
        }
    }
}

// MARK: - 表示モード

struct DisplayModeSettingsView: View {
    @AppStorage(Prefs.displayModeKey) private var rawMode: String = DisplayMode.both.rawValue
    /// ノッチ付きディスプレイがあるか。ディスプレイ構成の変化に追従して更新する。
    @State private var hasNotch = NotchDetector.hasNotchedDisplay

    private var displayMode: Binding<DisplayMode> {
        Binding(
            get: {
                let stored = DisplayMode(rawValue: rawMode) ?? .both
                // ノッチ環境では「メニューバーのみ」を選べない → 実効モード（両方表示）を選択表示する。
                if stored == .menuBar && hasNotch { return .both }
                return stored
            },
            set: { newValue in
                rawMode = newValue.rawValue
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
        )
    }

    var body: some View {
        // 表示モード（ラジオはボタンがラベルの左に縦並び＝システム設定と同じ。1つのカード行にまとめる）。
        // Picker(.radioGroup) は1項目だけ .disabled にしても文字が薄くならないので、自前の RadioRow のまま（2026-11-09）
        // 見出し「表示モード」は FILL Id など他のアプリと共通の表記なので変えない（2026-11-15 に一度
        // 「アイコンの表示場所」へ変えたが、何のアイコンか分からなくなるためユーザー指定で戻した）
        Section("Display Mode") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DisplayMode.allCases) { mode in
                    // ノッチ環境では「メニューバーのみ」を無効化（アイコンがノッチの陰に隠れるため）。
                    RadioRow(title: mode.label,
                             isSelected: displayMode.wrappedValue == mode,
                             isDisabled: mode == .menuBar && hasNotch) {
                        displayMode.wrappedValue = mode
                    }
                }
            }

            if hasNotch {
                Text("“Menu Bar Only” is unavailable because this Mac's built-in display has a notch and the menu bar icon can be hidden behind it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ⌘ キーを押しながら起動して表示モードを戻す注記は、2026-10-30 の整理で画面から外した（ヘルプの「ヒント」に記載）
        }
        // ディスプレイ構成が変わったらノッチ判定を更新（メニューバーのみの有効/無効に反映）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = NotchDetector.hasNotchedDisplay
        }
    }
}

// MARK: - ログイン時に起動

/// 「一般」タブの末尾のカード。「ログイン時に起動」だけ（「Illustrator が最前面にあるときだけパネルを表示」は
/// 2026-11-15 の4タブ化で「パネル」タブ＝`PanelSettingsView` へ移した）。
struct LaunchAtLoginSettingsView: View {
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        // 見出しなしのカード（オン／オフはスイッチ＝2026-11-09 ユーザー確定）
        Section {
            // 登録・解除はユーザーがクリックしたときだけ（読み直しで値を書き換えても走らないよう、onChange ではなく set で行う）
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    setLaunchAtLogin(newValue)
                }))
        }
        // ログイン項目の状態を読み直す（2026-10-24 実機）。設定ウインドウは使い回すので、最初に開いたときの値のままだと、
        // システム設定の「ログイン項目」から削除しても ON のまま見えた。開くたびと SPAi が前面に戻るたびに見直す
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowWillShow)) { _ in refreshLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLogin()
        }
    }

    private func refreshLaunchAtLogin() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[SPAi] Failed to change login item: %@", error.localizedDescription)
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

// MARK: - ショートカットの書き出し／読み込み

/// 割当ショートカットを別の Mac へ移すためのファイル書き出し・読み込み（実処理は `ShortcutTransferController`）。
/// 「ショートカット」タブの組み込みショートカットの下に置く（2026-10-30 に「一般」の最下部から移設）。
/// 旧版（Xojo 版 SPAi 3）の設定ファイルがあれば、2つのボタンの右に「SPAi 3から読み込む…」を出す（2026-10-30 ユーザー指定）。
struct ShortcutsSettingsView: View {
    var onExport: () -> Void
    var onImport: () -> Void
    var onImportLegacy: () -> Void = {}
    @State private var legacyExists = ShortcutTransfer.legacySettingExists

    var body: some View {
        // カードの1行にボタンを並べる。
        Section {
            // 「SPAi 3から読み込む…」は旧版の設定ファイルがあるときだけ、同じ行の右端に出す（幅は settingsWidth で確保）
            HStack(spacing: 8) {
                Button("Export…") { onExport() }
                    .fixedSize()   // ボタンを文字幅なりに固定（詰められて「書き…」と切れた＝2026-10-30 実機）
                Button("Import…") { onImport() }
                    .fixedSize()
                Spacer(minLength: 0)
                if legacyExists {
                    Button("Import from SPAi 3…") { onImportLegacy() }
                        .fixedSize()
                }
            }
        } header: {
            // 説明は見出しの下（2026-11-10 ユーザー指定でカードの下から移した）
            SettingsSectionHeader(title: "Script Shortcuts",
                                  note: "Use these to move your script shortcuts to another Mac.")
        }
        // 設定ウインドウは使い回すので、開くたびと SPAi が前面に戻るたびにファイルの有無を見直す
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowWillShow)) { _ in refreshLegacy() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLegacy()
        }
    }

    private func refreshLegacy() {
        let exists = ShortcutTransfer.legacySettingExists
        if exists != legacyExists { legacyExists = exists }
    }
}

/// ラジオ1行。ボタン（円）をラベルの左に置く（FILL Id と同じ体裁）。無効時はグレーアウトして選択不可にする。
private struct RadioRow: View {
    let title: String
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)   // .plain スタイルは自動で薄くならないため明示的にグレーアウト
    }
}

// MARK: - 登録フォルダ

/// 登録フォルダの一覧と追加/削除。実体のフォルダには触れない（登録を外すだけ）。
struct FoldersSettingsView: View {
    @ObservedObject var scriptStore: ScriptStore
    @State private var selectedPath: String?
    /// 一覧が空のときのドロップ受け（オーバーレイ）の上にフォルダがあるか。枠を強調する。
    @State private var isEmptyDropTargeted = false

    var body: some View {
        // カードの中に一覧、その下に ＋／−／Finderに表示（システム設定の「ログイン項目」と同じ形＝2026-11-09 モックの A案）。
        // フォルダを行として Form に直接並べる案（B案）は、選択・並び替え・ドロップを作り直す必要があるので見送った
        Section("Registered Folders") {
            VStack(spacing: 0) {
                // 一覧（フォルダ名で表示。消えているフォルダは警告アイコン）。List 自体の地は隠し、下の VStack の地を見せる
                List(selection: $selectedPath) {
                    ForEach(scriptStore.rootURLs, id: \.path) { url in
                        FolderRow(displayName: displayName(of: url),
                                  missingStatus: missingStatus(of: url),
                                  isVisible: Binding(
                                    get: { scriptStore.isVisible(url) },
                                    set: { scriptStore.setVisible($0, for: url) }),
                                  showsBottomLine: url == scriptStore.rootURLs.last,
                                  onReveal: { FinderActions.reveal(url) })
                            .tag(url.path)
                            // 各行の下に標準の区切り線（2026-11-12 ユーザー指定。それまでは隠していた）
                            .listRowSeparator(.visible)
                    }
                    // ドラッグで並び替え。パネルの登録フォルダもこの順に並ぶ（2026-10-24 ユーザー指定）
                    .onMove { scriptStore.moveRoots(fromOffsets: $0, toOffset: $1) }
                    // Finder からフォルダをドロップして、差し込み線の位置に登録（2026-10-25 ユーザー指定）。
                    // List に .onDrop を付けると並び替えとぶつかるので、ForEach の onInsert で受ける
                    .onInsert(of: [.fileURL]) { index, providers in
                        dropFolders(providers, at: index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: Self.listHeight)
                // 行の無いところのクリックで選択を外す（2026-11-10 ユーザー指定。List は空き場所のクリックで選択を外さない）
                .background(DeselectOnEmptyClick { selectedPath = nil })
                // macOS 15 までは一覧の地を白（標準のリストの地）に。＋／− の行はそのまま（2026-11-11 ユーザー指定）
                // 地だけカードの上端（内側余白 10pt ぶん）まで広げる。広げないと一覧の上にグレーの帯が残る（行の位置は変えない）
                .background(Self.listBackground.padding(.top, -10))
                // 行が無いと onInsert はドロップを受けないので、空のときだけ一覧全体で受ける
                .overlay {
                    if scriptStore.rootURLs.isEmpty {
                        Color.clear
                            .contentShape(Rectangle())
                            .onDrop(of: [.fileURL], isTargeted: $isEmptyDropTargeted) { providers in
                                dropFolders(providers, at: 0)
                                return true
                            }
                            .overlay {
                                if isEmptyDropTargeted {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                    }
                }
                // ゴミ箱を空にする等は登録フォルダの外の変化で再走査が走らないので、SPAi に戻ったときに見直す
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !scriptStore.missingRootPaths.isEmpty { scriptStore.rescan() }
                }
                // Finderに表示は各行の行末のボタン（`FolderRow`）。右クリック・ダブルクリック・一覧の下のボタンは
                // 2026-11-17 に廃止（ユーザー指定。DTP Zipper の通知の一覧と同じ形）

                // 追加／削除（一覧の下、細線で区切ってカードの左下に小さく）
                Divider()
                HStack(spacing: 8) {
                    Button(action: addFolders) {
                        Self.iconButtonLabel("plus")
                    }
                    Button(action: removeSelected) {
                        Self.iconButtonLabel("minus")
                    }
                    .disabled(selectedPath == nil)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)   // 「＋」の左端を一覧のチェックボックスの左端（カードの端から 10pt）にそろえる
                .padding(.vertical, 3)      // ＋／− の行は低く（2026-11-10 ユーザー指定。上下 6pt から詰めた）
                // 濃い地は ＋／− の行だけ。一覧はほかのカードと同じ地（2026-11-11 ユーザー指定。
                // ステップ90 ではカード全体を濃くしていた）
                .background(Self.listGround)
            }
            // 一覧・細線・＋／− をカードの左右と下の内側余白（10pt）まで広げる。選択色が左右いっぱいに届き、
            // ＋／− の行がカードの下端に付く（2026-11-10 ユーザー指定。ログイン項目と同じ）
            .padding(.horizontal, -10)
            .padding(.bottom, -10)
        }
    }

    /// 一覧の高さ（行の間隔 24pt × 10行）。2026-11-15 の4タブ化で専用タブになったので 110pt から拡げた
    /// （ユーザー指定。実機を見て変えるかもしれない）。
    private static let listHeight: CGFloat = 240

    /// ＋／− の行の地（ステップ90 では一覧も含むカード全体の地だった）。カード（地に 8/255 を重ねた色）にさらに重ねる。値はシステム設定「ログイン項目」の実測
    /// （Digital Color Meter「ネイティブの値を表示」、2026-11-10）に合わせた：
    /// - ライト：純正 240/240/240。標準のカード 247 に黒 7.4/255 を重ねると 240（247 × (1 − a) = 240）
    /// - ダーク：純正 53/52/51＝**標準のカード（42/41/40）より明るい**。白 5.2% を重ねると 53/52/51
    private static let listGround = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.052)
            : NSColor(white: 0, alpha: 7.4 / 255.0)
    })

    /// 一覧の地。macOS 15 まではカードがグレーなので、一覧だけ標準のリストの地（ライト＝白・ダーク＝暗い地）にする。
    /// macOS 26 以降はほかのカードと同じ地のまま（透明）。2026-11-11 ユーザー指定
    private static let listBackground: Color = {
        if #available(macOS 26, *) { return .clear }
        return Color(nsColor: .controlBackgroundColor)
    }()

    /// ＋／− のボタンのラベル。`.borderless` のボタンは字形の形だけがクリック範囲になり、「−」は
    /// 高さ 4pt の横棒しか反応しなかった（2026-10-24 実機・実測）。15×15pt の四角にそろえて全体で受ける
    /// （幅は従来の字形の幅と同じなので並びの見た目は変わらない）。
    private static func iconButtonLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
    }

    /// 見当たらない登録フォルダの、行末に出す状態（記録カードのショートカット一覧と同じ表記。2026-10-23 ユーザー指定）。
    /// 見当たる場合は nil。
    /// - ゴミ箱の中にある →「ゴミ箱」（戻せば使える）
    /// - 元の場所のボリューム（外付けディスク・サーバの共有）がつながっていない →「未接続」。ボリューム名は出さない
    ///   （一覧は幅が狭く、英語の「名前 (Not Connected)」が大きく省略された＝2026-10-23。ツールチップで出していたが、
    ///   SPAi ではツールチップを使わない＝2026-10-26）
    /// - それ以外 →「削除済み」
    private func missingStatus(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard scriptStore.missingRootPaths.contains(path) else { return nil }
        if scriptStore.trashedRootPaths.contains(path) { return String(localized: "Trash") }
        if ScriptItem.disconnectedVolumeName(path) != nil { return String(localized: "Not Connected") }
        return String(localized: "Deleted")
    }

    private func displayName(of url: URL) -> String {
        ScriptStore.displayNames(for: scriptStore.rootURLs)[url.standardizedFileURL.path]
            ?? url.lastPathComponent
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Select script folders to register with SPAi")
        if panel.runModal() == .OK {
            for url in panel.urls {
                scriptStore.addRoot(url)
            }
        }
    }

    /// ドロップされた項目のうちフォルダだけを `index` の位置に登録する。エイリアス・シンボリックリンクは実体に解決。
    /// ファイル・アプリ等のパッケージ・ゴミ箱の中は黙って無視、登録済みは何もしない（2026-10-25 ユーザー指定）。
    private func dropFolders(_ providers: [NSItemProvider], at index: Int) {
        Task { @MainActor in
            var folders: [URL] = []
            for provider in providers {
                guard let url = await Self.loadFileURL(provider) else { continue }
                let resolved = ScriptItem.resolvedURL(url)
                if Self.isPlainFolder(resolved) { folders.append(resolved) }
            }
            scriptStore.addRoots(folders, at: index)
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// 登録できるフォルダか（実在・ゴミ箱の外・.app 等のパッケージでない）。
    nonisolated static func isPlainFolder(_ url: URL) -> Bool {
        guard ScriptStore.rootExists(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    private func removeSelected() {
        guard let path = selectedPath else { return }
        scriptStore.removeRoot(URL(fileURLWithPath: path, isDirectory: true))
        selectedPath = nil
    }
}

/// 登録フォルダ1行。表示チェックボックス＋フォルダ名＋（存在しない場合は）警告アイコン。
/// チェックを外すとパネル・検索パレットに出さない（割当ショートカットは効いたまま。2026-10-22。メニューの一覧は同日に削除）。
/// 外した行はフォルダ名を淡色にする。
/// 有無は `ScriptStore.missingRootPaths`（走査のたびに更新）から受け取る＝消えたらその場で ⚠ が付く（2026-10-23）。
/// 見当たらない行は行末に状態（ゴミ箱／未接続／削除済み）をグレーで出す（2026-10-23 ユーザー指定）。
private struct FolderRow: View {
    let displayName: String
    let missingStatus: String?   // 行末の状態表示（ゴミ箱／未接続／削除済み）。nil＝見当たる
    @Binding var isVisible: Bool
    /// 最後の行だけ true。List 標準の区切り線は行と行のあいだにしか出ないので、最後の行の下は自前で引く（2026-11-12 ユーザー指定）
    var showsBottomLine = false
    /// 行末の「Finderに表示」ボタンの動作。見当たらないフォルダ（⚠ の行）にはボタンを出さない
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $isVisible) { EmptyView() }   // 空文字列ラベルは xcstrings に "" を出すので EmptyView
                .toggleStyle(.checkbox)
                .labelsHidden()
            FolderIcon(fillOpacity: isVisible ? 0.22 : 0.11)   // 非表示の行は輪郭と同じく塗りも淡く
                .foregroundStyle(isVisible ? .secondary : .tertiary)
            // 名前から右端まで（標準の区切り線と同じく、線は名前の左端から引く）
            HStack(spacing: 6) {
                Text(displayName)
                    .foregroundStyle(isVisible ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if missingStatus != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Spacer(minLength: 0)
                if let missingStatus {
                    Text(missingStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // 行末の「Finderに表示」（2026-11-17 ユーザー指定。DTP Zipper の通知の一覧の行と同じ小さい枠付きボタン）
                    Button("Reveal in Finder", action: onReveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            .overlay(alignment: .bottom) {
                if showsBottomLine {
                    Divider().offset(y: Self.bottomLineOffset)
                }
            }
        }
    }

    /// 名前の下端から行の下端（標準の区切り線の位置）までの距離。描画の実測で合わせた（行の間隔 24pt・線は行の下端の 1px）
    private static let bottomLineOffset: CGFloat = 4
}

/// 一覧の空き場所（行の無いところ）をクリックしたら `onEmptyClick` を呼ぶ（登録フォルダの選択を外すため。2026-11-10）。
/// SwiftUI の List（macOS）は空き場所のクリックで選択を外さないので、一覧の背面に置いたこのビューが
/// ウインドウ内のマウスダウンを見張り、自分の範囲内で、一覧（NSTableView）の行に当たっていないクリックを拾う。
/// イベントはそのまま流す（チェックボックス・ドラッグ・右クリックの動作は変えない）。
private struct DeselectOnEmptyClick: NSViewRepresentable {
    let onEmptyClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEmptyClick = onEmptyClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEmptyClick = onEmptyClick
    }

    final class MonitorView: NSView {
        var onEmptyClick: () -> Void = {}
        private var monitor: Any?

        /// クリックは受けない（見張るだけ）
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return }
            // クリックした場所から上へたどり、この範囲に収まるスクロールビュー（＝一覧）を探す。
            // 設定のフォーム自体も NSTableView なので、範囲で見分けないとフォームの行を一覧の行と取り違える
            let myRect = convert(bounds, to: nil).insetBy(dx: -2, dy: -2)
            var view: NSView? = hit
            while let current = view {
                if let scroll = current as? NSScrollView,
                   myRect.contains(scroll.convert(scroll.bounds, to: nil)) {
                    guard let table = scroll.documentView as? NSTableView else { return }
                    if table.row(at: table.convert(event.locationInWindow, from: nil)) < 0 { onEmptyClick() }
                    return
                }
                view = current.superview
            }
        }
    }
}

