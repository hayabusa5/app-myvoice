import Foundation

/// ClaudeやChatGPTの返事(メモリから書き出した用語の一覧)を、辞書の語に変える。
enum TermImport {
    /// AIに貼ってもらう依頼文
    static let prompt = """
    音声入力の辞書を作ります。あなたが覚えている私の情報(メモリやこれまでの会話)から、私がよく使う「固有名詞」だけを書き出してください。

    入れるもの:
    ・アプリ、サービス、AIツール、ソフト、製品、ブランドの名前(例: Claude Code、Obsidian、TestFlight)
    ・私が作っている、関わっているアプリ・作品・キャラクター・プロジェクトの名前
    ・よく話題にする技術用語、ライブラリ、英語の略語
    ・企業、著名人、作品など、公開されている名前

    入れないもの(大事):
    ・普通に変換できる一般的な言葉(「音声入力」「アプリ」「仕事」「辞書」など)
    ・家族・友人・同僚など、個人の名前
    ・住所、地名、勤務先、学校、病名、お金、パスワードなどのプライベートな情報

    形式は1行に1語で、「音声入力で間違えて文字にされそうな表記 → 正しい表記」にします。
    ・英語の名前は、カタカナ読みを左に書く(例: クロードコード → Claude Code)
    ・日本語の名前は、同じ読みで間違えやすい表記を左に書く(例: 手首ぶざー → 手首ブザー)
    ・間違えられそうな表記が思いつかないときは、正しい表記だけを書く

    できるだけ多く(30〜100語)出してください。前置き・説明・見出し・番号は付けず、一覧だけを出してください。
    """

    /// Web検索できるAIに、新しい製品・サービス・ツール名を集めてもらう依頼文
    static let latestPrompt = """
    音声入力の辞書を作ります。Webを検索して、AI関連の新しい製品・サービス・ツール・モデルの名前を集めてください。最近半年に出たもの・話題になったものを優先します。

    入れるもの: AIアシスタント、AIモデル名、AIコーディングツール、画像・動画・音声・音楽の生成AI、音声入力アプリ、AI向けの開発ツールや規格(例: Claude Code、Gemini、ElevenLabs、MCP)
    入れないもの: 普通に変換できる一般的な言葉(「生成AI」「チャット」など)

    形式は1行に1語で、「音声入力で間違えて文字にされそうなカタカナ読み → 正しい表記」にします(例: イレブンラボ → ElevenLabs)。正しいつづりは公式サイトの表記に合わせます。

    50〜100語出してください。前置き・説明・見出し・番号は付けず、一覧だけを出してください。
    """

    private static let arrows = ["→", "->", "=>", "⇒", "＝", "=", "：", ":", "\t"]
    private static let bullets: Set<Character> = ["-", "・", "*", "•", "●", "○", "▪", "+"]

    static func parse(_ text: String) -> [Term] {
        var seen = Set<String>()
        var terms: [Term] = []
        for rawLine in text.components(separatedBy: .newlines) {
            guard let term = parseLine(rawLine) else { continue }
            let key = (term.wrong + "|" + term.right).lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            terms.append(term)
        }
        return terms
    }

    static func parseLine(_ rawLine: String) -> Term? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```") else { return nil }
        // 箇条書きの記号や番号を外す
        while let first = line.first, bullets.contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let range = line.range(of: #"^\d+[\.\)．、]\s*"#, options: .regularExpression) { line.removeSubrange(range) }

        var wrong = ""
        var right = line
        for arrow in arrows {
            if let range = line.range(of: arrow) {
                wrong = String(line[..<range.lowerBound])
                right = String(line[range.upperBound...])
                break
            }
        }
        wrong = clean(wrong)
        right = clean(right)
        if wrong == right { wrong = "" }
        // 説明文や見出しのような長い行は語ではないので捨てる
        guard !right.isEmpty, right.count <= 30, wrong.count <= 30,
              !right.hasSuffix("。")
        else { return nil }
        return Term(wrong: wrong, right: right)
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`*「」『』\"'“”"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// すでに辞書にある語を除く
    static func newTerms(_ imported: [Term], existing: [Term]) -> [Term] {
        let keys = Set(existing.map { ($0.wrong + "|" + $0.right).lowercased() })
        return imported.filter { !keys.contains(($0.wrong + "|" + $0.right).lowercased()) }
    }
}
