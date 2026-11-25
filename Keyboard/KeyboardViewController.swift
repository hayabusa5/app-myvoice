import AVFoundation
import UIKit

/// マイクボタンで話す → Groqで文字起こし → 辞書で直す → カーソル位置に入力する キーボード。
final class KeyboardViewController: UIInputViewController {
    private let capture = WebAudioCapture()
    private var pcm = Data()
    /// 送信に失敗した録音(「再送」で使う)
    private var failedPCM: Data?
    private var isTranscribing = false
    private var modes = ModeStore.load()
    private var selectedMode: FormatMode = ModeStore.selected(in: ModeStore.load())
    private let modeRow = UIStackView()

    /// 状態の知らせ(録音中・エラーなど)。案内用の1行は置かず、「話す」ボタンの下の小さな字に出す
    private var statusText: String?
    private var statusClearTask: Task<Void, Never>?
    private let micButton = UIButton(type: .system)
    /// 録音中だけ「話す」ボタンの上に出す: 停止の印・波形・秒数
    private let recordingOverlay = UIStackView()
    private let waveform = WaveformView()
    private let timeLabel = UILabel()
    /// 録音に使っているマイクの名前(目立つように白い札にする。AirPodsならオレンジ)
    private let micBadge = PaddedLabel()
    private var deviceLabel: String?
    private let retryButton = UIButton(type: .system)
    private let micSourceButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private lazy var languageButton = keyButton(title: SpeechLanguage.current.shortLabel)
    private var deleteTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        reloadModes()
        capture.onReady = { [weak self] in self?.render() }
        capture.onStarted = { [weak self] in
            self?.statusText = nil
            self?.render()
        }
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
        capture.onDevice = { [weak self] label in
            guard let self, !label.isEmpty else { return }
            self.deviceLabel = label
            self.updateMicBadge()
        }
        capture.attach(to: view)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadModes()
        // フルアクセスがあるときだけ共有Keychainに書ける。アプリの「準備」の印に使う
        if hasFullAccess, !KeyboardStatus.hasFullAccess { KeyboardStatus.hasFullAccess = true }
        languageButton.configuration?.title = SpeechLanguage.current.shortLabel
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if capture.isCapturing { capture.stop() }
    }

    deinit {
        MainActor.assumeIsolated { capture.tearDown() }
    }

    // MARK: - 録音

    @objc private func micTapped() {
        if capture.isCapturing { capture.stop(); return }
        guard !isTranscribing else { return }
        guard hasFullAccess else {
            return setStatus("設定でこのキーボードの「フルアクセスを許可」をオンにしてください")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return setStatus("マイ音声入力アプリを開いて、マイクを許可してください")
        }
        guard APIKeyStore.load() != nil else {
            return setStatus(GroqError.noAPIKey.errorDescription ?? "")
        }
        pcm = Data()
        failedPCM = nil
        deviceLabel = nil
        updateMicBadge()
        waveform.reset()
        updateTimeLabel(seconds: 0)
        capture.start(preferBuiltInMic: MicPreference.preferBuiltIn)
        setStatus("マイクを準備中…")
        render()
    }

    private func append(_ data: Data, rms: Float) {
        pcm.append(data)
        let seconds = Double(pcm.count / 2) / WebAudioCapture.sampleRate
        waveform.push(rms: rms)
        updateTimeLabel(seconds: seconds)
    }

    private func updateTimeLabel(seconds: Double) {
        timeLabel.text = String(format: "%.1f秒", seconds)
    }

    private func updateMicBadge() {
        guard let name = deviceLabel, !name.isEmpty else { micBadge.isHidden = true; return }
        let isAirPods = name.localizedCaseInsensitiveContains("airpods")
        micBadge.isHidden = false
        micBadge.text = (isAirPods ? "🎧 " : "🎙 ") + name
        micBadge.textColor = isAirPods ? .black : .systemRed
        micBadge.backgroundColor = isAirPods ? .systemOrange : .white
    }

    private func captureEnded(_ reason: String) {
        render()
        let audio = pcm
        pcm = Data()
        if reason != "stopped" && audio.isEmpty {
            return setStatus("録音できませんでした: \(reason)")
        }
        transcribe(audio)
    }

    private func transcribe(_ audio: Data) {
        let seconds = Double(audio.count / 2) / WebAudioCapture.sampleRate
        guard seconds >= 0.5 else { return setStatus("短すぎました。もう一度どうぞ") }
        guard let apiKey = APIKeyStore.load() else { return setStatus(GroqError.noAPIKey.errorDescription ?? "") }

        isTranscribing = true
        render()
        setStatus("文字にしています…")
        let terms = TermStore.load()
        let language = SpeechLanguage.current
        let mode = selectedMode
        Task { @MainActor in
            defer { isTranscribing = false; render() }
            do {
                let raw = try await GroqClient.transcribe(
                    wav: WAV.make(pcm: audio), apiKey: apiKey, prompt: TermStore.prompt(for: terms, language: language), language: language
                )
                UsageStore.add(seconds: seconds)
                let text = TermStore.apply(terms, to: GroqClient.clean(raw))
                guard !text.isEmpty else { return setStatus("声が聞き取れませんでした") }
                guard mode.usesAI else {
                    textDocumentProxy.insertText(text)
                    return setStatus("入力しました(\(String(format: "%.1f", seconds))秒)")
                }
                setStatus("「\(mode.name)」で整えています…")
                do {
                    let formatted = try await TextFormatter.format(text, mode: mode, terms: terms, apiKey: apiKey)
                    textDocumentProxy.insertText(formatted.isEmpty ? text : TermStore.apply(terms, to: formatted))
                    setStatus("「\(mode.name)」で入力しました")
                } catch {
                    // 整形に失敗しても、話した言葉は失わない
                    textDocumentProxy.insertText(text)
                    setStatus("整形できなかったので、そのまま入れました")
                }
            } catch {
                failedPCM = audio
                setStatus((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    @objc private func retryTapped() {
        guard let audio = failedPCM else { return }
        failedPCM = nil
        transcribe(audio)
    }

    // MARK: - モード

    private func reloadModes() {
        modes = ModeStore.load()
        selectedMode = ModeStore.selected(in: modes)
        modeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, mode) in modes.enumerated() {
            var config = mode.id == selectedMode.id ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = mode.name
            config.cornerStyle = .capsule
            config.buttonSize = .medium
            if mode.id != selectedMode.id { config.baseForegroundColor = .label }
            let button = UIButton(configuration: config)
            button.tag = index
            button.addTarget(self, action: #selector(modeTapped(_:)), for: .touchUpInside)
            modeRow.addArrangedSubview(button)
        }
    }

    @objc private func modeTapped(_ sender: UIButton) {
        guard modes.indices.contains(sender.tag) else { return }
        ModeStore.select(modes[sender.tag])
        reloadModes()
        setStatus(selectedMode.usesAI ? "「\(selectedMode.name)」: 話したあとAIで整えます" : "そのまま入力します")
    }

    // MARK: - キー

    @objc private func insert(_ sender: UIButton) {
        guard let text = sender.accessibilityValue else { return }
        textDocumentProxy.insertText(text)
    }

    @objc private func deleteDown() {
        textDocumentProxy.deleteBackward()
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
            }
        }
    }

    @objc private func micSourceTapped() {
        guard !capture.isCapturing else { return }
        MicPreference.preferBuiltIn.toggle()
        updateMicSourceButton()
        setStatus(MicPreference.preferBuiltIn
                  ? "マイク: iPhone本体(イヤホンをつないでいても本体で録音)"
                  : "マイク: つないでいるもの(AirPodsなど)")
    }

    private func updateMicSourceButton() {
        var config = UIButton.Configuration.gray()
        config.image = UIImage(systemName: MicPreference.preferBuiltIn ? "iphone" : "airpods")
        config.title = MicPreference.preferBuiltIn ? "本体" : "自動"
        config.imagePlacement = .top
        config.imagePadding = 2
        config.baseForegroundColor = .label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 11, weight: .medium)
            return attributes
        }
        micSourceButton.configuration = config
        micSourceButton.accessibilityLabel = MicPreference.preferBuiltIn ? "マイク: iPhone本体" : "マイク: 自動"
    }

    @objc private func languageTapped() {
        let language = SpeechLanguage.current.next
        SpeechLanguage.current = language
        languageButton.configuration?.title = language.shortLabel
        switch language {
        case .auto: setStatus("言語: 自動(日本語と英語を聞き分けます)")
        case .japanese: setStatus("言語: 日本語")
        case .english: setStatus("言語: 英語(English)")
        }
    }

    @objc private func dismissTapped() {
        if capture.isCapturing { capture.stop() }
        dismissKeyboard()
    }

    @objc private func deleteUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    // MARK: - 画面

    private func configureView() {
        let height = view.heightAnchor.constraint(equalToConstant: 208)
        height.priority = .defaultHigh
        height.isActive = true

        var micConfig = UIButton.Configuration.filled()
        micConfig.cornerStyle = .capsule
        micConfig.image = UIImage(systemName: "mic.fill")
        micConfig.imagePadding = 8
        micConfig.titleAlignment = .center
        micConfig.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .preferredFont(forTextStyle: .caption2)
            return attrs
        }
        micButton.configuration = micConfig
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        let stopIcon = UIImageView(image: UIImage(systemName: "stop.fill"))
        stopIcon.tintColor = .white
        stopIcon.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.adjustsFontSizeToFitWidth = true
        timeLabel.minimumScaleFactor = 0.7
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        waveform.setContentHuggingPriority(.defaultLow, for: .horizontal)
        micBadge.font = .systemFont(ofSize: 13, weight: .bold)
        micBadge.layer.cornerRadius = 10
        micBadge.layer.masksToBounds = true
        micBadge.lineBreakMode = .byTruncatingMiddle
        micBadge.isHidden = true
        micBadge.setContentHuggingPriority(.required, for: .horizontal)
        micBadge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        [stopIcon, micBadge, waveform, timeLabel].forEach(recordingOverlay.addArrangedSubview)
        recordingOverlay.spacing = 10
        recordingOverlay.alignment = .center
        recordingOverlay.isUserInteractionEnabled = false
        recordingOverlay.isHidden = true
        recordingOverlay.translatesAutoresizingMaskIntoConstraints = false
        micButton.addSubview(recordingOverlay)
        NSLayoutConstraint.activate([
            recordingOverlay.leadingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: 20),
            recordingOverlay.trailingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: -20),
            recordingOverlay.topAnchor.constraint(equalTo: micButton.topAnchor, constant: 8),
            recordingOverlay.bottomAnchor.constraint(equalTo: micButton.bottomAnchor, constant: -8),
            waveform.heightAnchor.constraint(equalTo: recordingOverlay.heightAnchor),
        ])

        var retryConfig = UIButton.Configuration.tinted()
        retryConfig.title = "再送"
        retryConfig.image = UIImage(systemName: "arrow.clockwise")
        retryButton.configuration = retryConfig
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let deleteButton = keyButton(image: "delete.left")
        deleteButton.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let dismissButton = keyButton(image: "keyboard.chevron.compact.down")
        dismissButton.accessibilityLabel = "キーボードを閉じる"
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        languageButton.accessibilityLabel = "認識する言語"
        languageButton.addTarget(self, action: #selector(languageTapped), for: .touchUpInside)

        let bottomRow = UIStackView(arrangedSubviews: [
            globeButton,
            languageButton,
            textKey("、"), textKey("。"), textKey("？"),
            textKey("空白", insert: " "),
            deleteButton,
            textKey("改行", insert: "\n"),
            dismissButton,
        ])
        bottomRow.spacing = 6
        bottomRow.distribution = .fillProportionally

        micSourceButton.addTarget(self, action: #selector(micSourceTapped), for: .touchUpInside)
        micSourceButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        updateMicSourceButton()

        let micRow = UIStackView(arrangedSubviews: [micSourceButton, micButton, retryButton])
        micRow.spacing = 8

        modeRow.spacing = 6
        modeRow.translatesAutoresizingMaskIntoConstraints = false
        let modeScroll = ButtonScrollView()
        modeScroll.showsHorizontalScrollIndicator = false
        modeScroll.delaysContentTouches = false
        if #available(iOS 26.0, *) {
            // 低い横スクロールだとiOS 26の端のぼかしが全体にかかり、ボタンが見えなくなる
            modeScroll.topEdgeEffect.isHidden = true
            modeScroll.bottomEdgeEffect.isHidden = true
            modeScroll.leftEdgeEffect.isHidden = true
            modeScroll.rightEdgeEffect.isHidden = true
        }
        modeScroll.addSubview(modeRow)
        NSLayoutConstraint.activate([
            modeRow.topAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.topAnchor),
            modeRow.bottomAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.bottomAnchor),
            modeRow.leadingAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.leadingAnchor),
            modeRow.trailingAnchor.constraint(equalTo: modeScroll.contentLayoutGuide.trailingAnchor),
            modeRow.heightAnchor.constraint(equalTo: modeScroll.frameLayoutGuide.heightAnchor),
            modeScroll.heightAnchor.constraint(equalToConstant: 36),
        ])

        // 歯車: マイ音声入力アプリ(辞書・モード・APIキーの設定)を開く
        let settingsButton = keyButton(image: "gearshape")
        settingsButton.accessibilityLabel = "マイ音声入力の設定を開く"
        settingsButton.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)
        settingsButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let topRow = UIStackView(arrangedSubviews: [settingsButton, modeScroll])
        topRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [topRow, micRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: margins.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            // 下に詰めて、親指の届く位置にキーを置く
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            micButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            bottomRow.heightAnchor.constraint(equalToConstant: 46),
            globeButton.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    /// キーボードから直接はURLを開けないので、レスポンダチェーンをたどってUIApplicationに開かせる
    @objc private func openSettingsTapped() {
        guard let url = URL(string: "myvoice://settings") else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
        setStatus("アプリを開けませんでした。ホーム画面から開いてください")
    }

    private func textKey(_ title: String, insert: String? = nil) -> UIButton {
        let button = keyButton(title: title)
        button.accessibilityValue = insert ?? title
        button.addTarget(self, action: #selector(insert(_:)), for: .touchUpInside)
        return button
    }

    private func keyButton(title: String? = nil, image: String? = nil) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = image.flatMap { UIImage(systemName: $0) }
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        if let title { button.accessibilityLabel = title }
        return button
    }

    private func render() {
        globeButton.isHidden = !needsInputModeSwitchKey
        retryButton.isHidden = failedPCM == nil || capture.isCapturing || isTranscribing

        var config = micButton.configuration ?? .filled()
        recordingOverlay.isHidden = !capture.isCapturing
        micButton.accessibilityLabel = capture.isCapturing ? "録音を終える" : nil
        if capture.isCapturing {
            // 文字と印は重ねて出す波形のほうに任せる
            config.title = nil
            config.image = nil
            config.baseBackgroundColor = .systemRed
            micButton.isEnabled = true
        } else if isTranscribing {
            micButton.alpha = 1
            config.title = "処理中"
            config.image = UIImage(systemName: "ellipsis")
            config.baseBackgroundColor = .systemGray
            micButton.isEnabled = false
        } else {
            micButton.alpha = 1
            config.title = capture.isReady ? "話す" : "準備中…"
            config.image = UIImage(systemName: "mic.fill")
            config.baseBackgroundColor = capture.isReady ? .systemBlue : .systemGray
            micButton.isEnabled = capture.isReady
        }
        config.subtitle = capture.isCapturing ? nil : statusText
        micButton.configuration = config
    }

    private func setStatus(_ text: String) {
        statusText = text.isEmpty ? nil : text
        render()
        // 録音中・処理中でなければ、少したったら消す
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, !self.capture.isCapturing, !self.isTranscribing else { return }
            self.statusText = nil
            self.render()
        }
    }
}

/// 内側に余白のあるラベル(マイク名の札)
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// ボタンの上から指を動かしても横スクロールできるスクロールビュー。
/// (標準では、ボタンの上で始まったドラッグはスクロールにならない)
final class ButtonScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl ? true : super.touchesShouldCancel(in: view)
    }
}
