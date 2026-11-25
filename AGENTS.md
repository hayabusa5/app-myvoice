# マイ音声入力(MyVoice) 作業ルール

Claude Code・Codexの共通ルール。自分専用の音声入力。iPhone・iPad向けのキーボード(`App/` `Keyboard/`)と、Mac向けのメニューバーアプリ(`Mac/`)がある。共通の処理は `Shared/`、共通の画面は `SharedUI/`。

## 仕組み
- キーボードの中で録音する。アプリの切り替えはしない。見えない WKWebView の `getUserMedia` でマイクを使う(`Keyboard/WebAudioCapture.swift`、stephancill/ios-keyboard-dictation より、MIT)
- 録音を止めたら、16kHzのWAVにして Groq `whisper-large-v3-turbo`(language=ja)へ送る → 決まり文句を捨てる → 辞書で置き換える → (整形モードなら)Groq `qwen/qwen3.8-27b`(`reasoning_effort: none`)で整える → `textDocumentProxy.insertText`
- 整形モードはキーボードの上の段で選ぶ。アプリで追加・編集できる。整形に失敗したら、文字起こしをそのまま入れる(話した言葉を失わない)
- キーボードを閉じるのはホスト側のアプリが決める。どのアプリでも閉じられるよう、キーボードに「閉じる」キーを置いている。自作アプリの中では、文字の欄の外をタップすると閉じる(`TapOutsideToDismiss`)
- 辞書のインポート: アプリの「AIのメモリから取り込む」で依頼文をコピー → ClaudeやChatGPTに貼る → 返事を貼ると `TermImport.parse` が語を取り出す(「→」「->」「:」などで区切る。前置き・見出し・「。」で終わる説明文は捨てる)。確認してから追加する。依頼文は固有名詞だけを頼む(一般的な言葉・個人名・地名・勤務先などは入れない。本人の指定)。Web検索で新しいAIツール名を集める依頼文もある。MCPで直接書き込む形は、CloudKitとMac版のあとで考える(本人の判断)
- 認識する言語は「自動/日本語/英語」(`SpeechLanguage`、既定は自動)。自動のときはGroqに `language` を渡さず、`prompt` も用語だけにする(日本語の文を入れると英語の発話もカタカナになりやすい)。iPhoneはキーボードの下の段のボタン、Macはメニューで切り替える。整形モードは、翻訳のモード以外では元の言語のまま整える
- マイクの選び方(iPhone): キーボードのマイクボタンの左で「自動/本体」を切り替える(`MicPreference`)。本体のときは、WebKitの `enumerateDevices` から名前に iPhone などを含むマイクを選んで録音し直す。選べなければ、つないでいるマイクのまま録音する。外を歩くとき用(本人)。キーボードの中で切り替えが効くかは実機で要確認
- 辞書は上の語ほど優先。Groqの `prompt`(224トークン)に入るのは上から180文字分だけで、アプリでは「ヒント」の印を付けて見せる(`TermStore.hintWords`)。並べ替えは「編集」から
- 辞書の同期: iCloudのキー値ストア(`NSUbiquitousKeyValueStore`、`SharedUI/DictionarySync.swift`)。iPhoneアプリとMac版に同じ `com.apple.developer.ubiquity-kvstore-identifier`(`$(TeamIdentifierPrefix)com.takasub5.MyVoice`)を付ける。新しいほう(`TermStore.updatedAt`)が勝ち、初回だけ両方の語を合わせる。キーボードは同期せず、共有Keychainを読むだけ
- キーボードの歯車は `myvoice://` でアプリを開く(レスポンダチェーンのUIApplicationに開かせる)
- Mac版はログイン時に自動で起動する(初回起動で `SMAppService.mainApp.register()`、メニューの「Macの起動時に開く」で切り替え)
- Mac版のマイク: メニューで選んだマイクを、録音のたびにシステムの入力にする(AirPodsをつなぐと入力が勝手に変わるため、`Mac/AudioInput.swift`)。HUDとキーボードにマイク名の札を出し、AirPodsならオレンジ
- APIキー・用語辞書・今月の使用量は**共有Keychain**(`$(AppIdentifierPrefix)com.takasub5.MyVoice.shared`)に置く。App Groupは使っていない(下記)

## ビルドとインストール
```bash
xcodegen generate
xcodebuild -project MyVoice.xcodeproj -scheme MyVoice -destination 'id=00008160-000A03A000214036' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008160-000A03A000214036 build/Build/Products/Debug-iphoneos/MyVoice.app
```
- 署名のチームは BLLFXPJGG7。2026-11-25の夜に本人がXcodeへサインインし、コマンドからも新しい権限(iCloudなど)のプロファイルを作れるようになった(それまでは「No Accounts」)ため、ワイルドカードのプロファイルで足りる権限だけにしている。App GroupやCloudKitを足すときは、Xcodeで一度ビルドしてプロファイルを作る
- TestFlightは、アーカイブを `open` して Organizer から上げる(`-exportArchive` は失敗する)

## Mac版(`Mac/`)
- Caps Lockを押している間だけ録音 → 離すと文字起こし・整形 → クリップボード経由で⌘Vを送ってカーソル位置に入れる(0.8秒後に元のクリップボードへ戻す)
- Caps LockはKarabiner-ElementsでF18(キーコード79)にしてある。F18は以前Codex(ChatGPT.app、`com.openai.codex`)の音声入力(`globalDictationHold`)に使っていたが、2026-11-25に本人の許可で `~/.codex/keybindings.json` の割り当てを外した(バックアップ `keybindings.json.bak-2026-11-25`)。マイ音声入力はCodexを含むすべてのアプリで動く。「Codexが前面のときは任せる」設定は既定でオフ。Codexは起動時にしか `keybindings.json` を読まないので、割り当てを変えたらCodexを再起動する(しないとCaps LockでCodexが動き続ける)
- 右Commandは本人がAキーに割り当てている。ショートカットに使わない
- 録音は `AVAudioRecorder` で16kHzのWAV。キーの監視は `NSEvent` のグローバルモニタ。マイクとアクセシビリティの許可が要る
- 署名はiCloudのためプロファイル付きの自動署名。このMac(Mac mini)は開発用に登録済み(初回は `-allowProvisioningDeviceRegistration` が要った)。サンドボックスなし。辞書・APIキーはこのMacのKeychain。辞書だけiCloudでiPhoneと同期する
- 入れ方:
```bash
xcodebuild -project MyVoice.xcodeproj -scheme MyVoiceMac -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build
ditto "build/Build/Products/Debug/マイ音声入力.app" "/Applications/マイ音声入力.app"
```

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
