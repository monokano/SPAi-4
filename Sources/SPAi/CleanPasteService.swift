import AppKit

/// クリーンペースト（組み込みショートカット ⌥V／トリムは ⇧⌥V。2026-10-30）。旧版 SPAi 3 の「プレーンテキストでペースト」の後継で、
/// 処理は FILL Id の `PasteService` に倣う：
/// クリップボードの文字列 → 合成除外保護つき NFC（`TextNormalizer.nfcSafe`）→ 改行を CR に →（トリムなら前後の空白・改行を削る）
/// → 合成できない文字があれば警告 → Illustrator の選択テキストへ流し込み（⌘V は送らない）。
///
/// 流し込みは発火時に捕捉した Illustrator（pid 指定の `do javascript`）へ送る。書類が無い・テキストを編集中でない
/// （選択が TextRange でない）ときは何もしない（旧版と同じ）。
@MainActor
final class CleanPasteService {

    private let illustrator: IllustratorController
    private var checker: CharacterCheckerWindowController?
    /// 合成できない文字の警告を表示中か。表示中にもう一度押されても入れ子で開かない。
    private(set) var isPresentingAlert = false

    init(illustrator: IllustratorController) {
        self.illustrator = illustrator
    }

    /// ペーストを実行する。`target` は発火時に捕捉した Illustrator。`trim` で前後の空白・改行を除く。
    func run(target: IllustratorTarget, trim: Bool) {
        guard !isPresentingAlert, !illustrator.isBusy else { return }
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }

        var s = TextNormalizer.nfcSafe(raw)
        s = TextNormalizer.unifyToCR(s)
        if trim {
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty else { return }

        if BadCharacterScanner.hasBadCharacter(s) {
            // FILL Id と同じく、テキストを編集中のときだけ警告を出す（ペーストできない場面でダイアログを出さない）。
            illustrator.run(Self.canPasteScript, target: target, timeout: 10) { [weak self] reply in
                guard reply == "1", let self else { return }
                self.showBadCharacterAlert(s, target: target)
            }
        } else {
            setText(s, target: target)
        }
    }

    private func setText(_ text: String, target: IllustratorTarget) {
        illustrator.run(Self.setTextScript(text), target: target, timeout: 30)
    }

    private func showBadCharacterAlert(_ s: String, target: IllustratorTarget) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some characters cannot be composed.")
        alert.informativeText = String(localized: "It is better to avoid characters that cannot be composed.")
        alert.addButton(withTitle: String(localized: "Check"))   // 確認する
        alert.addButton(withTitle: String(localized: "Paste"))   // ペースト
        alert.addButton(withTitle: String(localized: "Cancel"))  // キャンセル

        // ホットキーは Illustrator 最前面で押されるので、アラートを前面に出すため SPAi を一時的にアクティブにする。
        NSApp.activate(ignoringOtherApps: true)
        isPresentingAlert = true
        let response = alert.runModalAboveOtherApps()
        isPresentingAlert = false
        switch response {
        case .alertFirstButtonReturn:   // 確認する：合成できない文字を1つずつ探せるウインドウ（SPAi が前面のまま）
            if checker == nil { checker = CharacterCheckerWindowController() }
            checker?.show(text: s)
        case .alertSecondButtonReturn:  // ペースト
            setText(s, target: target)
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        default:                        // キャンセル
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        }
    }

    // MARK: - Illustrator へ送る JavaScript

    /// テキストを編集中か（書類があり、選択が TextRange＝文字の選択か挿入点）。"1"／"0" を返す。
    private static let canPasteScript = """
        (function(){if(app.documents.length==0)return "0";var s=app.selection;\
        return (s&&s.typename=="TextRange")?"1":"0";})();
        """

    /// 選択テキストを置き換える（挿入点なら挿入）。テキストを編集中でなければ何もしない。
    /// 本体は旧版 SPAi 3 の `cScript_SetTextToAI`（`do javascript … with arguments {myText}`）の JavaScript をそのまま使う
    /// （2026-10-30 ユーザー指摘で移植し直し。当初は使われていない `cPasteTextScript` の手順を真似ていた）：
    /// - 挿入点（長さ 0）で2文字目以降：範囲を手前の文字に広げて `contents += s`（手前の文字の書式を引き継ぐ）
    /// - それ以外（文字を選択中・行頭）：`contents = s`
    /// - どちらも最後に長さ 0 にしてキャレットを挿入した文字列の末尾へ移し、`select()`
    /// 旧版は文字列を `with arguments` で渡していたが、SPAi 4 は文字列リテラルに埋め込む（`jsString`。FILL Id と同じ）。
    /// 先頭の書類・選択の確認は旧版の `cScript_IsSetCursorAI`（書類があり selection が text か）に当たる。
    private static func setTextScript(_ text: String) -> String {
        """
        (function(s){if(app.documents.length==0)return "";var textObj=app.selection;\
        if(!textObj||textObj.typename!="TextRange")return "";
        if(textObj.length==0 && textObj.characterOffset>1){
        textObj.characterOffset-=2;
        textObj.length++;
        textObj.contents+=s;
        textObj.length=0;
        textObj.characterOffset=textObj.characterOffset+s.length;
        } else {
        textObj.contents=s;
        textObj.length=0;
        textObj.characterOffset=textObj.characterOffset+s.length-1;
        }
        textObj.select();
        return "ok";})(\(jsString(text)));
        """
    }

    /// 文字列を JavaScript の文字列リテラル（前後のダブルクォート含む）へ。FILL Id の `InDesignController.jsString` と同じ。
    /// CR はそのまま `\r`（Illustrator の段落区切り）として埋め込む。
    nonisolated static func jsString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            // U+2028/U+2029 は JavaScript では文字列リテラル内でも行終端子（ES2019 より前＝ExtendScript）
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }
}
