import SwiftUI

/// スクリプトパネルの中身（仕様書 §3）。上部の送信先表示＋階層リスト＋下部バー。
/// 省スペース志向：リストの左右マージンはほぼゼロ、行の縦パディングも最小。
/// キーボードは一切受け取らない（パネルは key にならない・§6.5）。操作はマウスのみ：
/// クリックで選択／フォルダ開閉（⌥クリックで配下ごと）、ダブルクリックで実行、
/// 行末バッジまたは右クリックでショートカット割当。検索は検索パレット（⇧⌘Space）へ分離。
struct ScriptPanelView: View {
    @ObservedObject var vm: ScriptPanelViewModel
    @AppStorage(Prefs.listTextSizeKey) private var rawTextSize = ListTextSize.medium.rawValue

    private var textSize: ListTextSize { ListTextSize(rawValue: rawTextSize) ?? .medium }

    var body: some View {
        if vm.isCollapsed {
            // 畳んだ状態：ヘッダー1行だけ。縦を fixedSize にして、NSHostingView がウィンドウの
            // 最大高さもヘッダー分に揃えるようにする（maxHeight: .infinity だと NSHostingView が
            // window の maxSize を無限大へ上書きし、畳んだまま縦にリサイズできてしまう。実測 2026-10-21）。
            targetHeader
                .frame(minWidth: 220)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                targetHeader
                Divider()
                if vm.rows.isEmpty {
                    emptyPlaceholder
                } else {
                    scriptList
                }
                Divider()
                bottomBar
            }
            .frame(minWidth: 220, minHeight: 160)
        }
    }

    // MARK: - 上部：送信先 Illustrator（§3-1。控えめな1行）

    /// ヘッダーの文字は 11pt・primary（secondary→primary 75%→primary と段階的に濃く。2026-10-21 ユーザー指定）。
    /// 空き部分のダブルクリックでパネルを畳む／戻す（Xojo 版の「タイトルバー下ダブルクリックで畳む」を踏襲）。
    /// ヘッダーの左余白。畳んだときはヘッダーがパネルの下端に接し、macOS 26 以降の大きい角丸
    ///（macOS 27 で実測 半径約16pt）に左端のアイコンがかかるので、左だけ広げて角丸の内側へ逃がす
    ///（2026-11-18 ユーザー指定＝左12pt・上下と右は従来どおり）。広げた状態と macOS 25 以前は従来の 6pt。
    private var headerLeadingPadding: CGFloat {
        if vm.isCollapsed, #available(macOS 26, *) { return 12 }
        return 6
    }

    private var targetHeader: some View {
        HStack(spacing: 4) {
            Group {
                if let info = vm.targetInfo {
                    if let icon = info.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 15, height: 15)
                    }
                    Text(info.label)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Illustrator Not Running")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            // 虫眼鏡・歯車・⌘ は外側の spacing を使わず詰めて並べる（ボタン自身の左右余白 4pt ずつで足りる。2026-10-29 ユーザー指定。
            // 歯車は 2026-10-30 ユーザー指定で虫眼鏡と ⌘ の間に追加）
            HStack(spacing: 0) {
                searchButton
                settingsButton
                shortcutFilterButton
            }
        }
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.requestToggleCollapse() }
        // ツールチップは出さない（SPAi ではツールチップを一切使わない。邪魔なため 2026-10-26 ユーザー指定）
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HeaderHeightKey.self) { vm.reportHeaderHeight($0) }
    }

    /// 検索パレットを開くボタン（§3-1。2026-10-29 ユーザー指定）。メニューの「スクリプトを検索…」と違い常に有効。
    /// 見た目は ⌘ フィルタボタンの OFF 状態に揃える（トグルではないので座布団は無し）。
    /// 押している間だけ淡い座布団を出して、押したことが分かるようにする（2026-10-29 ユーザー指定）。
    private var searchButton: some View {
        Button { vm.onOpenSearch?() } label: {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(Color.primary.opacity(0.75))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderPressButtonStyle())
    }

    /// 設定ウインドウを開くボタン（2026-10-30 ユーザー指定）。メニューの「設定…」と同じ。
    /// 見た目・押下の座布団は虫眼鏡ボタンに揃える（記号は設定「一般」タブと同じ gearshape）。
    private var settingsButton: some View {
        Button { vm.onOpenSettings?() } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundColor(Color.primary.opacity(0.75))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderPressButtonStyle())
    }

    /// 「ショートカット付きのみ表示」フィルタのトグル（§3-1）。ON 中はアクセント色＋淡い座布団。
    private var shortcutFilterButton: some View {
        Button { vm.showOnlyShortcuts.toggle() } label: {
            Image(systemName: "command")
                .font(.caption)
                .foregroundColor(vm.showOnlyShortcuts
                                 ? Color.accentColor
                                 : Color.primary.opacity(0.75))   // 旧 secondary 60% は薄すぎた（2026-10-22 ユーザー指定で濃く）
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(vm.showOnlyShortcuts
                              ? Color.accentColor.opacity(0.15)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - リスト

    /// 行の無い箇所のクリックで選択解除（2026-10-22 ユーザー指定）。中身を表示域の高さまで広げ、
    /// その背景でクリックを受ける（行は前面で自分のジェスチャを受けるので背景には届かない）。
    private var scriptList: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 2)
                .frame(minHeight: geo.size.height, alignment: .top)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectedID = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PanelRow) -> some View {
        switch row.kind {
        case .folder(let name):
            folderRow(row, name: name)
        case .script(let item):
            ScriptRowView(vm: vm, row: row, item: item)
        }
    }

    /// フォルダ行。クリックで開閉、⌥クリックで配下のフォルダごと一括開閉。
    /// 登録フォルダ（階層0）はアイコンと名前を文字色（ライト＝黒／ダーク＝白）にし、アイコンの塗りも 60% に濃くして
    /// サブフォルダと見分ける（2026-10-25 ユーザー指定。塗り 22%／35%／60%／100% を ui-snapshot で描き比べて選択）。
    /// 開閉シェブロンは淡色のまま。
    private func folderRow(_ row: PanelRow, name: String) -> some View {
        let expanded = vm.isExpanded(row.id)
        let isRoot = row.level == 0
        return HStack(spacing: 3) {
            Image(systemName: "chevron.right")
                .font(.system(size: textSize.chevron, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Group {
                FolderIcon(fillOpacity: isRoot ? 0.6 : 0.22)
                    .font(.system(size: textSize.folderIcon))
                Text(name)
                    .font(.system(size: textSize.folderName)).bold()
                    .lineLimit(1)
            }
            .foregroundColor(isRoot ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .foregroundColor(.secondary)
        .padding(.leading, CGFloat(row.level) * 12 + 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 行幅いっぱいの淡いグレーの帯でスクリプト行と見分けやすく（2026-10-25 ユーザー指定。4/7/10%・登録フォルダだけ等を
        // ui-snapshot で描き比べて 7% を選択。文字色の 7%＝ライト/ダークとも同程度に見える）
        .background(Color.primary.opacity(0.07))
        .contentShape(Rectangle())
        .onTapGesture {
            // 開閉は控えめ・短めのアニメーション（シェブロンの回転＋配下の行のフェード／下の行の移動。2026-10-27 ユーザー指定）。
            // 「視差効果を減らす」が ON なら動かさない。
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                vm.toggleFolder(row.id, deep: NSEvent.modifierFlags.contains(.option))
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                if let url = vm.folderURL(for: row.id) { vm.revealInFinder(url) }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack {
            Spacer()
            Text(vm.showOnlyShortcuts
                 ? String(localized: "No scripts with shortcuts")
                 : String(localized: "No scripts"))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 下部バー

    /// 本数表示だけ（「実行後にウインドウを閉じる」は 2026-10-23 に廃止）。
    private var bottomBar: some View {
        HStack {
            Spacer()
            Text(vm.countLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// ヘッダーの押しボタン（虫眼鏡）用。`.plain` は押下の見た目が無いので、押している間だけ
/// ⌘ フィルタ ON と同じ形の淡い座布団（primary 15%）を敷く（2026-10-29 ユーザー指定）。
private struct HeaderPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.15) : Color.clear)
            )
    }
}

/// ヘッダーの実測高さ（畳んだパネルの高さに使う）。
private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension ScriptItem {
    /// 行に出す名前。同じフォルダに同名・拡張子違いがあるときだけ、後ろに拡張子を淡色で付ける
    /// （2026-10-23 ユーザー指定。パネル・検索パレット共用）。選択行（アクセント色の地）では白の淡色。
    func nameText(selected: Bool) -> Text {
        guard showsExtension else { return Text(name) }
        return Text(name)
            + Text("." + url.pathExtension)
                .foregroundColor(selected ? Color.white.opacity(0.7) : .secondary)
    }
}

/// フォルダのアイコン。輪郭（呼び出し側の前景色）の中を淡いグレーで塗り、輪郭だけの書類アイコン（スクリプト）と
/// ひと目で見分けられるようにする（2026-10-23 ユーザー指定。塗りは文字色の 22%＝ライト/ダークとも同程度に目立つ）。
/// 大きさは呼び出し側の `.font` に従う。パネルのフォルダ行と設定の登録フォルダ一覧で共用。
struct FolderIcon: View {
    var fillOpacity: Double = 0.22

    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .foregroundColor(Color.primary.opacity(fillOpacity))
            Image(systemName: "folder")
        }
    }
}

/// スクリプト行のアイコン。エイリアス／シンボリックリンクは Finder と同じく左下に矢印バッジを重ね、
/// 元ファイルとは別の行（ショートカットも別々）だと見て分かるようにする（2026-10-22。パネル・検索パレット共用）。
/// AppleScript（アプレット含む）は書類アイコンの代わりに `applescript`（送信先 Illustrator を選べない種類だと
/// 分かるように）、ふつうのアプリは `app`（2026-10-23）。
struct ScriptIcon: View {
    let isAlias: Bool
    var kind: ScriptKind = .javaScript
    let size: CGFloat
    let selected: Bool

    var body: some View {
        if isAlias {
            document(color: selected ? .white : Color(nsColor: .secondaryLabelColor))
                // 下の書類アイコンの線と矢印が重ならないよう、矢印の場所を書類アイコンから欠く（偶奇塗りのマスク）。
                // 地色で塗る方式は強調行・記録カードの淡い地の上で白い四角に見え、blendMode(.destinationOut) の
                // くり抜きは行の地まで突き抜けた（2026-10-23 ui-snapshot）ため、合成に頼らない形にした。
                .mask {
                    GeometryReader { g in
                        Path { p in
                            p.addRect(CGRect(x: -size, y: -size, width: g.size.width + size * 2,
                                             height: g.size.height + size * 2))
                            p.addRoundedRect(in: badgeRect(in: g.size), cornerSize: CGSize(width: 2, height: 2))
                        }
                        .fill(style: FillStyle(eoFill: true))
                    }
                }
                // 書類アイコンとマスクを1枚に焼く。無いとライトで書類アイコンが白く飛んだ。また `.secondary`
                // （階層スタイル）もマスク下では白く飛ぶので固定の淡色にした（いずれも ui-snapshot）。
                .drawingGroup()
                .overlay(alignment: .bottomLeading) {
                    // 四角付きの記号は 10pt 前後で潰れて黒い点に見えた（ui-snapshot）ため、矢印だけを太く出す
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: size * 0.75, weight: .heavy))
                        .foregroundColor(selected ? .white : .primary)
                        .offset(x: -size * 0.3 + 1, y: size * 0.2 - 1)
                }
        } else {
            // 通常のスクリプトは従来どおり（マスク・焼き込みを掛けると濃さがわずかに変わるため分ける）
            document(color: selected ? .white : .secondary)
        }
    }

    private func document(color: Color) -> some View {
        Image(systemName: kind.usesAppleScript ? "applescript" : kind == .app ? "app" : "doc.text")
            .font(.system(size: size))
            .foregroundColor(color)
    }

    /// 矢印の占める範囲（＋1pt の余白）。書類アイコンの左下を基準に、矢印と同じだけずらす。
    private func badgeRect(in iconSize: CGSize) -> CGRect {
        let side = size * 0.75 + 2
        return CGRect(x: -size * 0.3, y: iconSize.height - side + size * 0.2, width: side, height: side)
    }
}

/// スクリプト1行。ホバー状態（ショートカット割当バッジの表示）を持つため個別 View に分離。
private struct ScriptRowView: View {
    @ObservedObject var vm: ScriptPanelViewModel
    let row: PanelRow
    let item: ScriptItem
    @State private var hovering = false
    /// 行末のショートカットバッジ（⌘ 記号を含む）の上にいる。シングルクリック実行のとき、バッジのクリックで実行しないため。
    @State private var hoveringBadge = false
    @AppStorage(Prefs.listTextSizeKey) private var rawTextSize = ListTextSize.medium.rawValue
    @AppStorage(Prefs.runOnSingleClickKey) private var runOnSingleClick = false

    var body: some View {
        let selected = vm.selectedID == row.id
        let shortcutLabel = vm.shortcutLabel(for: item)
        let textSize = ListTextSize(rawValue: rawTextSize) ?? .medium

        HStack(spacing: 4) {
            // ファイルが無い（ゴミ箱の中を含む）割当は、アイコンと名前を淡くして ⚠ を添える（2026-10-23）
            Group {
                ScriptIcon(isAlias: item.isAlias, kind: item.kind,
                           size: textSize.scriptIcon, selected: selected)
                item.nameText(selected: selected)
                    .font(.system(size: textSize.scriptName))
                    .lineLimit(1)
            }
            .opacity(item.isMissing && !selected ? 0.45 : 1)
            if item.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: textSize.scriptIcon))
                    .foregroundStyle(.yellow)
            }
            Spacer(minLength: 4)
            shortcutBadge(label: shortcutLabel, selected: selected)
        }
        // 「ショートカット付きのみ表示」はフラット一覧（階層0）で縁に詰まって見えたため、左だけ広げる（2026-10-23 ユーザー指定）
        // 階層表示では、フォルダ行のシェブロン列（左余白2＋幅10＋間隔3）ぶん足して、アイコンを同階層のフォルダアイコンに揃える。
        // 旧 +4 では子のアイコンが親フォルダのアイコンの真下に来て、字下げされていないように見えた（2026-10-28 ユーザー指摘）
        .padding(.leading, vm.showOnlyShortcuts ? 10 : CGFloat(row.level) * 12 + 15)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .foregroundColor(selected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        // シングルクリックで選択、ダブルクリックで実行（§3-2 の必須動線）。
        // ⌘クリックは選択中の行なら選択解除（Finder と同じ。2026-10-22 ユーザー指定）、それ以外は通常の選択。
        // 設定「スクリプトを実行」がシングルクリックなら、クリックで選択して実行する（2026-10-30 ユーザー指定）。
        // ⌘クリック・バッジのクリック・無いファイルの行では実行しない。
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            let command = NSEvent.modifierFlags.contains(.command)
            if command && vm.selectedID == row.id {
                vm.selectedID = nil
            } else {
                vm.selectedID = row.id
            }
            if runOnSingleClick && !command && !hoveringBadge && !item.isMissing {
                vm.runOnClick(item, rowID: row.id)
            }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !runOnSingleClick && !item.isMissing { vm.run(item) }
        })
        .onHover {
            hovering = $0
            // 行から出ると ⌘ 記号のボタンが消え、その onHover(false) が届かないことがあるので、ここでも戻す
            if !$0 { hoveringBadge = false }
        }
        .contextMenu {
            if item.isMissing {
                // 無いファイルは実行できないので、解除と「Finderに表示」だけ。ゴミ箱の中などにまだあれば
                // その場所を表示し、完全に削除されていればグレーアウト（2026-10-23 ユーザー指定）
                Button("Remove Shortcut") { vm.clearShortcut(item) }
                Divider()
                Button("Reveal in Finder") {
                    // 一覧を作った後に空にされた場合に備え、押した時点の場所で開く
                    if let location = ShortcutStore.currentLocation(of: item.url.path) { vm.revealInFinder(location) }
                }
                .disabled(item.foundAt == nil)
            } else {
                // 並び：実行／編集／─／ショートカット／─／Finderに表示（2026-11-18 ユーザー指定）
                Button("Run") { vm.run(item) }
                // 編集＝Finder でのダブルクリックと同じ（既定のアプリで開く）。.app は開くと起動＝実行と
                // 同じになるのでグレーアウト（2026-11-18 ユーザー指定）
                Button("Edit") { vm.openInDefaultApp(item.url) }
                    .disabled(item.kind.isApplication)
                Divider()
                Button(shortcutLabel == nil
                       ? String(localized: "Assign Shortcut…")
                       : String(localized: "Change Shortcut…")) {
                    vm.requestShortcut(item)
                }
                if shortcutLabel != nil {
                    Button("Remove Shortcut") { vm.clearShortcut(item) }
                }
                Divider()
                Button("Reveal in Finder") { vm.revealInFinder(item.url) }
            }
        }
    }

    /// 行末のショートカットバッジ（§3-2）。割当済みは常時淡色表示、未割当はホバー時のみ
    /// 記号を出す。クリックで記録パレットが開く（割当の入口）。
    @ViewBuilder
    private func shortcutBadge(label: String?, selected: Bool) -> some View {
        if let label {
            Button { vm.requestShortcut(item) } label: {
                Text(label)
                    .font(.system(size: 11))   // 旧 .caption（10pt）から +1pt（2026-10-22 ユーザー指定）
                    .foregroundColor(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.isMissing)   // 無いファイルはキーの変更もしない（右クリックで解除）
            .onHover { hoveringBadge = $0 }
        } else if hovering {
            Button { vm.requestShortcut(item) } label: {
                Image(systemName: "command")
                    .font(.caption2)
                    .foregroundColor(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .onHover { hoveringBadge = $0 }
        }
    }
}
