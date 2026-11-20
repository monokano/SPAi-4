import SwiftUI

/// 検索パレットの中身（仕様書 §3B）。検索欄＋フラットな結果リスト＋ヒント行。
/// パレットは表示中キーボードを持つ道具：↑↓・Enter・Esc は SearchPaletteController の
/// ローカルモニタが担い、このビューは表示と（ダブル）クリックだけを扱う。
struct SearchPaletteView: View {
    @ObservedObject var vm: SearchPaletteViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if vm.rows.isEmpty {
                emptyPlaceholder
            } else {
                resultList
            }
            Divider()
            hintBar
        }
        .frame(minWidth: 320, minHeight: 240)
        .onAppear { searchFocused = true }
        .onChange(of: vm.focusRequest) { _ in searchFocused = true }
    }

    // MARK: - 検索欄

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search scripts (fuzzy match)", text: $vm.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 結果リスト

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: vm.selectedID) { sel in
                if let sel = sel { proxy.scrollTo(sel) }
            }
        }
    }

    private func rowView(_ row: PaletteRow) -> some View {
        let selected = vm.selectedID == row.id
        return HStack(spacing: 6) {
            ScriptIcon(isAlias: row.item.isAlias, kind: row.item.kind,
                       size: 10, selected: selected)   // 10pt＝従来の .caption
            VStack(alignment: .leading, spacing: 1) {
                row.item.nameText(selected: selected)
                    .lineLimit(1)
                if let sub = row.subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .foregroundColor(selected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        // シングルクリックで選択、ダブルクリックで実行（実行後はパレットが閉じる）。
        .simultaneousGesture(TapGesture(count: 1).onEnded { vm.selectedID = row.id })
        .simultaneousGesture(TapGesture(count: 2).onEnded { vm.run(row.item) })
    }

    private var emptyPlaceholder: some View {
        VStack {
            Spacer()
            Text(vm.query.isEmpty
                 ? String(localized: "No scripts")
                 : String(localized: "No matching scripts"))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - ヒント行

    private var hintBar: some View {
        HStack {
            Text("↑↓ Select   Enter Run   Esc Close")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(vm.query.isEmpty
                 ? String(localized: "\(vm.scriptCount) scripts")
                 : String(localized: "\(vm.rows.count) / \(vm.scriptCount) scripts"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
