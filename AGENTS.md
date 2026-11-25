# マイ音声入力(MyVoice) 作業ルール

Claude Code・Codexの共通ルール。自分専用のiPhone・iPad向け音声入力キーボード。

## 仕組み
- キーボードの中で録音する。アプリの切り替えはしない。見えない WKWebView の `getUserMedia` でマイクを使う(`Keyboard/WebAudioCapture.swift`、stephancill/ios-keyboard-dictation より、MIT)
- 録音を止めたら、16kHzのWAVにして Groq `whisper-large-v3-turbo`(language=ja)へ送る → 決まり文句を捨てる → 辞書で置き換える → (整形モードなら)Groq `qwen/qwen3.8-27b`(`reasoning_effort: none`)で整える → `textDocumentProxy.insertText`
- 整形モードはキーボードの上の段で選ぶ。アプリで追加・編集できる。整形に失敗したら、文字起こしをそのまま入れる(話した言葉を失わない)
- キーボードを閉じるのはホスト側のアプリが決める。どのアプリでも閉じられるよう、キーボードに「閉じる」キーを置いている。自作アプリの中では、文字の欄の外をタップすると閉じる(`TapOutsideToDismiss`)
- 辞書のインポート: アプリの「AIのメモリから取り込む」で依頼文をコピー → ClaudeやChatGPTに貼る → 返事を貼ると `TermImport.parse` が語を取り出す(「→」「->」「:」などで区切る。前置き・見出し・「。」で終わる説明文は捨てる)。確認してから追加する。依頼文は固有名詞だけを頼む(一般的な言葉・個人名・地名・勤務先などは入れない。本人の指定)。Web検索で新しいAIツール名を集める依頼文もある。MCPで直接書き込む形は、CloudKitとMac版のあとで考える(本人の判断)
- 辞書は上の語ほど優先。Groqの `prompt`(224トークン)に入るのは上から180文字分だけで、アプリでは「ヒント」の印を付けて見せる(`TermStore.hintWords`)。並べ替えは「編集」から
- APIキー・用語辞書・今月の使用量は**共有Keychain**(`$(AppIdentifierPrefix)com.takasub5.MyVoice.shared`)に置く。App Groupは使っていない(下記)

## ビルドとインストール
```bash
xcodegen generate
xcodebuild -project MyVoice.xcodeproj -scheme MyVoice -destination 'id=00008160-000A03A000214036' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008160-000A03A000214036 build/Build/Products/Debug-iphoneos/MyVoice.app
```
- 署名のチームは BLLFXPJGG7。コマンドからはXcodeのアカウントを使えない(「No Accounts」)ため、ワイルドカードのプロファイルで足りる権限だけにしている。App GroupやCloudKitを足すときは、Xcodeで一度ビルドしてプロファイルを作る
- TestFlightは、アーカイブを `open` して Organizer から上げる(`-exportArchive` は失敗する)

## 使う前の設定(iPhone側)
1. アプリを開いてマイクを許可し、Groq APIキーを保存する
2. 設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → マイ音声入力 → 「フルアクセスを許可」をオン

## 注意
- この録音方式は、将来のiOSで塞がれる可能性がある(KeyboardKitの指摘)
- キーボードを閉じると録音は止まる
- Groqは1回あたり最低10秒で課金される。使用量の画面はその前提で計算している

## アイコン
- iPhoneに入れるときは、試作でも簡単なアイコンを付ける(本人の指定)
- `App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`(1024×1024、アルファなし)。変えるときは差し替えるだけでよい

## GitHub
- 非公開リポジトリ: https://github.com/hayabusa5/app-myvoice (topic: app)。自動同期はないので、変えたら手動でcommit・pushする
- コミットの作成者は既存リポジトリと同じ `Claude <noreply@anthropic.com>`(`git -c user.name=Claude -c user.email=noreply@anthropic.com commit`)
- `MyVoice.xcodeproj` と `build/` は入れない(`xcodegen generate` で作り直せる)。APIキーはコードに書かない
