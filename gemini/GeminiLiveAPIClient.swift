import Foundation
import Combine
import AVFoundation
import UIKit

private let TEMP_API_KEY = "" // 사용자 제공 키 유지

@MainActor
class GeminiLiveAPIClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private let apiKey: String
    private var session: URLSession!

    @Published var isConnected: Bool = false
    @Published var isRecording: Bool = false
    @Published var isVideoEnabled: Bool = false
    @Published var chatMessages: [ChatMessage] = []
    @Published var currentTextInput: String = "" // 텍스트 입력용
    @Published var currentModelResponse: String = "" // 추가됨 (스트리밍 응답 처리용)
    
    // MARK: - Network Resilience Properties
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectDelay: TimeInterval = 1.0 // Exponential backoff
    private let maxReconnectDelay: TimeInterval = 32.0
    private var shouldAutoReconnect = true
    private var lastConnectedTime: Date?
    
    // MARK: - AI Speaking State Management
    @Published var isAISpeaking = false
    @Published var hasPendingGuidanceRequest = false
    private var lastAIResponseTime = Date()
    
    // ✅ 단순화: 불필요한 상태 관리 제거
    
    // MARK: - Audio Engine Properties
    private var audioEngine: AVAudioEngine!
    private var audioPlayerNode: AVAudioPlayerNode!
    private var audioInputFormatForEngine: AVAudioFormat! // 입력용 포맷 (하드웨어 또는 세션 기본값 따름)
    private var audioOutputFormatForPCM: AVAudioFormat! // 우리 PCM 데이터의 실제 포맷 (24kHz, 16bit, mono)
    private let audioSampleRate: Double = 24000.0
    private var isAudioEngineSetup = false
    
    // ✅ 단순화: 버퍼 큐 제거, 받은 오디오 즉시 재생
    
    // MARK: - Audio Input Properties
    private var inputTapInstalled = false
    private let audioQueue = DispatchQueue(label: "audioInput.queue", qos: .userInitiated)
    private var recordingTimer: Timer?
    private let recordingChunkDuration: TimeInterval = 0.1 // 100ms chunks for real-time
    private var accumulatedAudioData = Data()
    
    // **추가: ARViewModel 참조**
    weak var arViewModel: ARViewModel?
    
    // ✅ 추가: AppState 참조 (Stage 체크용)
    weak var appState: AppState?
    
    // ✅ Stage 3 지연 활성화 플래그
    private var pendingStage3Activation = false
    
    // MARK: - Video Processing Properties
    @Published var debugProcessedImage: UIImage? = nil
    private let videoFrameInterval: TimeInterval = 0.5
    private let ciContext = CIContext()
    
    // ✅ 효율적인 이미지 처리를 위한 재사용 가능한 CIContext
    let reusableCIContext = CIContext(options: [.useSoftwareRenderer: false])

    init(apiKey: String = TEMP_API_KEY) {
        self.apiKey = apiKey
        super.init()
        
        // 네트워크 구성 최적화
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        // 오디오 세션과 엔진은 연결 시에만 초기화
        // setupAudioSession()
        // setupAudioEngine()
    }

    // MARK: - Audio Session and Engine Setup
    private func setupAudioSession() {
        // AudioSessionCoordinator를 사용하여 중앙화된 관리
        let coordinator = AudioSessionCoordinator.shared
        
        // 이미 적절한 모드가 활성화되어 있으면 그대로 사용
        if coordinator.currentAudioMode != .idle {
            print("🎵 GeminiClient: Using existing audio session mode: \(coordinator.currentAudioMode)")
            return
        }
        
        if coordinator.requestAudioSession(for: .geminiLiveAudio) {
            // Audio session acquired
        } else {
            // Fallback: 직접 설정 시도
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, 
                                            mode: .default, 
                                            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                
                try audioSession.setPreferredSampleRate(audioSampleRate)
                try audioSession.setPreferredIOBufferDuration(0.02)
                
                try audioSession.setActive(true)
                
                // ✅ 스피커로 출력 강제
                try audioSession.overrideOutputAudioPort(.speaker)
                
                // Direct audio session setup complete
            } catch {
                // Continue even if audio session setup fails
            }
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        
        // Enable voice processing for echo cancellation
        // This MUST be done before engine is prepared or started
        let inputNode = audioEngine.inputNode
        
        // Enable voice processing on input node (automatically enables on output too)
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Continue even if voice processing fails
        }

        audioOutputFormatForPCM = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                              sampleRate: audioSampleRate, 
                                              channels: 1, 
                                              interleaved: true)
        
        if audioOutputFormatForPCM == nil {
            print("❌ GeminiClient: Could not create audioOutputFormatForPCM.")
            isAudioEngineSetup = false
            return
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioInputFormatForEngine = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: audioSampleRate,
                                                channels: 1,
                                                interleaved: true)
        
        if audioInputFormatForEngine == nil {
            print("Error: Could not create audioInputFormatForEngine.")
            isAudioEngineSetup = false
            return
        }
        
        // 플레이어 노드 연결
        audioEngine.attach(audioPlayerNode)
        let mainMixer = audioEngine.mainMixerNode
        audioEngine.connect(audioPlayerNode, to: mainMixer, format: nil)

        // 엔진 준비만 하고 실제 시작은 필요할 때
        audioEngine.prepare()
        
        // ✅ 오디오 재생을 위해 엔진 시작
        do {
            try audioEngine.start()
        } catch {
            isAudioEngineSetup = false
            return
        }
        
        isAudioEngineSetup = true
    }
    
    private var setupParameters: (modelName: String, systemPrompt: String, voiceName: String, languageCode: String, includeGoogleSearch: Bool)?

    func connect(
        // modelName: String = "models/gemini-2.0-flash-live-001",
        modelName: String = "models/gemini-live-2.5-flash-preview",
        // modelName: String = "models/gemini-2.5-flash-preview-native-audio-dialog",
        systemPrompt: String = """
        당신은 시각장애인 안전 도우미입니다.
        사용자는 성인 기준 약 50cm의 어깨 너비를 가지고 있습니다.
        화면 중앙뿐만 아니라 좌우 가장자리의 장애물도 충돌 위험이 있습니다.
        안전한 통행을 위해 좌우 50cm 여유 공간이 필요합니다.
        장애물은 구체적 이름과 위치를 명확히 설명하세요.
        한국어로 간결하고 신속하게 답변하세요.
        시각장애인이 요청한 것이 아니면 구글서치를 하지 마세요.
        """,
        voiceName: String = "Leda",
        languageCode: String = "ko-KR",
        includeGoogleSearch: Bool = true,  // ✅ Stage별 Google Search 제어
        enableStage3OnConnect: Bool = false
    ) {
        guard !apiKey.isEmpty, apiKey != "YOUR_API_KEY_HERE" else {
            let errorMessage = "Error: API Key is not set"
            print(errorMessage)
            self.chatMessages.append(ChatMessage(text: errorMessage, sender: .system))
            return
        }
        
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(self.apiKey)") else {
            print("Error: Invalid URL")
            self.chatMessages.append(ChatMessage(text: "Error: Invalid API URL", sender: .system))
            return
        }

        disconnect()
        
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessagesLoop()
        
        // 연결 성공 후 setup 메시지 전송을 위해 저장
        setupParameters = (modelName, systemPrompt, voiceName, languageCode, includeGoogleSearch)
        
        // Stage 3 지연 활성화 플래그 설정
        self.pendingStage3Activation = enableStage3OnConnect
    }
    
    func disconnect() {
        // 자동 재연결 비활성화
        shouldAutoReconnect = false
        cancelReconnectTimer()
        
        // 녹음 중이면 중지
        if isRecording {
            stopRecording()
        }
        
        // ✅ 강화: 모든 오디오 활동 중단
        stopAudioPlayback()
        resetAISpeakingState()
        
        // 오디오 세션 해제
        AudioSessionCoordinator.shared.releaseAudioSession(for: .geminiLiveAudio)
        
        // ✅ 캐시 제거: 비디오 관련 상태 리셋 코드 간소화
        DispatchQueue.main.async {
            self.isVideoEnabled = false
            self.debugProcessedImage = nil
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func sendSetupMessage(
        modelName: String,
        systemPrompt: String,
        voiceName: String,
        languageCode: String,
        includeGoogleSearch: Bool = true
    ) {
        var currentModelName = modelName

        // 공식 문서에 따른 올바른 언어 코드 및 음성 설정
        let prebuiltVoiceConfig = PrebuiltVoiceConfig(voiceName: voiceName)
        let voiceConfig = VoiceConfig(prebuiltVoiceConfig: prebuiltVoiceConfig)
        let speechConfig = SpeechConfig(
            languageCode: languageCode,
            voiceConfig: voiceConfig
        )
        let generationConfig = GenerationConfig(
            responseModalities: ["AUDIO"],
            speechConfig: speechConfig
        )
        
        // 시스템 프롬프트 설정
        let systemInstruction = SystemInstruction(text: systemPrompt)        

        // Google Search Tool 조건부 추가
        var tools: [Tool] = []
        if includeGoogleSearch {
            let googleSearchTool = GoogleSearchTool()
            let tool = Tool(googleSearch: googleSearchTool)
            tools.append(tool)
        }

        let config = GeminiLiveConfig(
            model: currentModelName,
            generationConfig: generationConfig,
            systemInstruction: systemInstruction,
            tools: tools
        )
        let setupMessage = SetupMessage(setup: config)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(setupMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
            } else {
                print("Error: Could not convert SetupMessage to JSON string post-connection")
            }
        } catch {
            print("Error encoding SetupMessage post-connection: \(error)")
        }
    }

    func sendUserText(_ text: String) {
        guard isConnected, !text.isEmpty else { 
            print("Cannot send text: Not connected or text is empty.")
            return
        }
        
        var parts: [ClientTextPart] = [ClientTextPart(text: text)]
        
        // 비디오가 활성화되어 있다면 현재 프레임을 함께 전송
        if isVideoEnabled, let currentVideoFrame = getCurrentVideoFrame() {
            parts.append(ClientTextPart(inlineData: InlineData(mimeType: "image/jpeg", data: currentVideoFrame)))
        }
        
        let turn = ClientTurn(role: "user", parts: parts)
        let clientTextPayload = ClientTextPayload(turns: [turn], turnComplete: true)
        let messageToSend = UserTextMessage(clientContent: clientTextPayload)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(messageToSend)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
            }
        } catch {
            print("Error encoding message: \(error)")
        }
    }

    // 현재 비디오 프레임을 캡처하는 메서드 수정
    func getCurrentVideoFrame() -> String? {
        // ✅ 항상 ARViewModel에서 실시간 최신 프레임 요청
        guard let arViewModel = arViewModel else {
            return nil
        }
        
        if let frame = arViewModel.getCurrentVideoFrameForGemini() {
            return frame
        } else {
            return nil
        }
    }

    private func sendString(_ string: String) {
        guard let task = webSocketTask else { 
            print("WebSocket task not available for sending string.")
            return
        }
        task.send(.string(string)) { error in
            if let error = error {
                print("Error sending string: \(error)")
            }
        }
    }
    
    private func sendData(_ data: Data) {
        guard let task = webSocketTask else { 
            print("WebSocket task not available for sending data.")
            return
        }
        task.send(.data(data)) { error in
            if let error = error {
                print("Error sending data: \(error)")
            }
        }
    }

    private func receiveMessagesLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("Error in receiving message: \(error)")
                // isConnected는 didCloseWith에서 처리
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(text: "Error receiving message: \(error.localizedDescription)", sender: .system))
                }
            case .success(let message):
                switch message {
                case .string(let text):
                    // Audio/text response received - logging removed for clarity
                    Task { @MainActor in
                        self.parseServerMessage(text)
                    }
                    
                case .data(let data):
                    // Audio data logging removed for clarity
                    if let text = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            self.parseServerMessage(text)
                        }
                    } else {
                        print("❌ Could not convert data to string")
                    }
                @unknown default:
                    print("❌ Unknown message type")
                }
                // 연결이 활성 상태일 때만 다음 메시지를 계속 수신
                Task { @MainActor in
                    if self.webSocketTask?.closeCode == .invalid { // closeCode가 invalid면 아직 활성 상태로 간주
                        self.receiveMessagesLoop()
                    }
                }
            }
        }
    }
    
    private func parseServerMessage(_ jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("❌ Error: Could not convert JSON string to Data")
            return
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let wrapper = try decoder.decode(ServerResponseWrapper.self, from: jsonData)
            // ✅ 간소화된 로깅 - 데이터 내용 제외

            var systemMessagesToAppend: [ChatMessage] = []
            var modelResponseText: String? = nil

            // 1. SetupComplete 처리
            if wrapper.setupComplete != nil {
                systemMessagesToAppend.append(ChatMessage(text: "System: Setup Complete! Ready to chat.", sender: .system))
                
                // ✅ Stage별로 다른 설정
                if let appState = self.appState {
                    if appState.currentStage == .liveGuidanceMode {
                        // Stage 2: 비디오만 활성화, 녹음은 시작하지 않음
                        if !self.isVideoEnabled {
                            self.isVideoEnabled = true
                        }
                    } else if appState.currentStage == .pureConversationMode {
                        // Stage 3: 비디오와 녹음 모두 시작
                        if !self.isVideoEnabled {
                            self.isVideoEnabled = true
                        }
                        
                        if !self.isRecording {
                            self.startRecording()
                        }
                    }
                }
            }

            // 2. ServerContentData 처리 (모델 텍스트/오디오, 턴 상태 등)
            if let serverContent = wrapper.serverContent {
                
                // interrupted 상태 처리 - AI 응답 중단
                if let interrupted = serverContent.interrupted, interrupted {
                    // ✅ 단순화: 즉시 오디오 중지 및 상태 리셋
                    stopAudioPlayback()
                    handleAIResponseComplete(reason: "interrupted")
                }
                
                if let modelTurn = serverContent.modelTurn {
                    for part in modelTurn.parts {
                        if let text = part.text {
                            modelResponseText = (modelResponseText ?? "") + text
                        }
                        if let inlineData = part.inlineData {
                            // 오디오 데이터 처리 호출
                            handleReceivedAudioData(base64String: inlineData.data, mimeType: inlineData.mimeType)
                            // ✅ 오디오 수신 시에만 AI speaking 상태 시작 (텍스트 수신 시에는 호출하지 않음)
                            handleAIResponseStart()
                        }
                        // ExecutableCode 처리
                        if let execCode = part.executableCode {
                            let lang = execCode.language ?? "Unknown language"
                            let code = execCode.code ?? "No code"
                            let execMessage = "Tool Execution Request:\nLanguage: \(lang)\nCode:\n\(code)"
                            systemMessagesToAppend.append(ChatMessage(text: execMessage, sender: .system, isToolResponse: true))
                        }
                    }
                }
                
                if let endOfTurn = serverContent.endOfTurn, endOfTurn {
                    handleAIResponseComplete(reason: "endOfTurn")
                }
                
                if let turnComplete = serverContent.turnComplete, turnComplete {
                    handleAIResponseComplete(reason: "turnComplete")
                }
                
                if let generationComplete = serverContent.generationComplete, generationComplete {
                    handleAIResponseComplete(reason: "generationComplete")
                }
            }

            // 3. ToolCall 처리 (FunctionCall from server)
            if let toolCall = wrapper.toolCall, let functionCalls = toolCall.functionCalls {
                for functionCall in functionCalls {
                    var toolMessageText = ""
                    if functionCall.name == "googleSearch" {
                        if let args = functionCall.args {
                            let resultText = args.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                            toolMessageText = "Google Search Result:\n---\n\(resultText)\n---"
                        } else {
                            toolMessageText = "Google Search called, but no arguments received."
                        }
                        systemMessagesToAppend.append(ChatMessage(text: toolMessageText, sender: .system, isToolResponse: true))
                        
                        if let callId = functionCall.id {
                            sendToolResponseMessage(id: callId, result: [:]) 
                        }
                    } else {
                        toolMessageText = "Received unhandled tool call: \(functionCall.name ?? "unknown")"
                        systemMessagesToAppend.append(ChatMessage(text: toolMessageText, sender: .system, isToolResponse: true))
                    }
                }
            }

            // 4. UsageMetadata 처리
            if let usage = wrapper.usageMetadata {
                var usageText = "Usage - Total Tokens: \(usage.totalTokenCount ?? 0)"
                if let promptTokens = usage.promptTokenCount, let responseTokens = usage.responseTokenCount {
                    usageText += " (Prompt: \(promptTokens), Response: \(responseTokens))"
                }
                systemMessagesToAppend.append(ChatMessage(text: "System: " + usageText, sender: .system))
            }

            // UI 업데이트 (메인 스레드에서)
            DispatchQueue.main.async {
                if let text = modelResponseText, !text.isEmpty {
                    self.chatMessages.append(ChatMessage(text: text, sender: .model))
                }
                self.chatMessages.append(contentsOf: systemMessagesToAppend)
            }

        } catch {
            print("❌ Error decoding server message: \(error)")
        }
    }

    // MARK: - Tool Response Sender (NEW)
    func sendToolResponseMessage(id: String, result: [String: AnyCodableValue]) { // AnyCodableValue는 모델 파일에 정의 필요
        guard isConnected else {
            print("Cannot send tool response: Not connected.")
            return
        }
        
        let functionResponse = FunctionResponse(id: id, response: result)
        let toolResponsePayload = ToolResponsePayload(functionResponses: [functionResponse])
        let messageToSend = ToolResponseMessage(toolResponse: toolResponsePayload)
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let jsonData = try encoder.encode(messageToSend)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
                print("Sent ToolResponseMessage: \(jsonString)")
            }
        } catch {
            print("Error encoding ToolResponseMessage: \(error)")
        }
    }

    // MARK: - Audio Handling Methods
    private func handleReceivedAudioData(base64String: String, mimeType: String) {
        // Stage 3에서는 주기적 가이던스만 차단하고, 사용자 질문 응답은 허용
        
        if !isAudioEngineSetup {
            setupAudioSession()
            setupAudioEngine()
            
            // 재검증
            guard isAudioEngineSetup else {
                print("❌ GeminiClient: Failed to setup audio engine. Cannot play audio.")
                return
            }
        }
        
        // ✅ 오디오 엔진 상태 확인
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                return
            }
        }
        
        guard let audioData = Data(base64Encoded: base64String) else {
            print("❌ GeminiClient: Could not decode base64 audio data.")
            return
        }
        
        // ✅ 단순화: 과도한 로깅 제거
        
        // 디코드 완료
        
        // 1. PCM 데이터 포맷 정의
        guard let sourceFormat = audioOutputFormatForPCM else {
            print("❌ GeminiClient: audioOutputFormatForPCM (sourceFormat) is nil.")
            return
        }
        
        // 소스 포맷 확인

        // 2. PCM 버퍼 생성
        let monoBytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        if monoBytesPerFrame == 0 {
            print("Error: monoBytesPerFrame is zero.")
            return
        }
        let monoFrameCount = AVAudioFrameCount(audioData.count / monoBytesPerFrame)
        if monoFrameCount == 0 {
            print("Error: Calculated monoFrameCount is zero.")
            DispatchQueue.main.async {
                 self.chatMessages.append(ChatMessage(text: "System: Received audio data too small or invalid.", sender: .system))
            }
            return
        }
        
        guard let monoPCMBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: monoFrameCount) else {
            print("Error: Could not create monoPCMBuffer.")
            return
        }
        monoPCMBuffer.frameLength = monoFrameCount
        
        var dataCopiedSuccessfully = false
        audioData.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            if let int16ChannelData = monoPCMBuffer.int16ChannelData, let sourceAddress = rawBufferPointer.baseAddress {
                let destinationPointer = UnsafeMutableRawBufferPointer(start: int16ChannelData[0], count: audioData.count)
                memcpy(destinationPointer.baseAddress!, sourceAddress, audioData.count)
                dataCopiedSuccessfully = true
            } else {
                print("Error: monoPCMBuffer.int16ChannelData is nil or rawBufferPointer.baseAddress is nil.")
            }
        }
        
        guard dataCopiedSuccessfully else {
            print("❌ GeminiClient: Failed to copy audio data to monoPCMBuffer.")
            return
        }
        
        // 버퍼로 데이터 복사 완료

        // 3. 타겟 포맷 가져오기
        let targetFormat = audioPlayerNode.outputFormat(forBus: 0)
        // 타겟 포맷 확인

        // 4. 포맷 변환 및 재생
        if sourceFormat.isEqual(targetFormat) {
            // ✅ 단순화: 포맷이 동일하면 즉시 재생
            audioPlayerNode.scheduleBuffer(monoPCMBuffer)
        } else {
            // 포맷이 다르면 변환 필요
            // 포맷 불일치 - 변환 필요
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("❌ GeminiClient: Could not create AVAudioConverter from \(sourceFormat) to \(targetFormat)")
                return
            }

            let outputFrameCapacity = AVAudioFrameCount(ceil(Double(monoPCMBuffer.frameLength) * (targetFormat.sampleRate / sourceFormat.sampleRate)))
            guard outputFrameCapacity > 0 else {
                print("Error: outputFrameCapacity is zero or negative (\(outputFrameCapacity)). Input frames: \(monoPCMBuffer.frameLength), SR Ratio: \(targetFormat.sampleRate / sourceFormat.sampleRate)")
                return
            }

            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                print("Error: Could not create convertedBuffer for targetFormat. Capacity: \(outputFrameCapacity)")
                return
            }

            var error: NSError?
            var inputBufferProvidedForThisConversion = false 

            // 입력 블록: 변환기에 원본 데이터를 제공
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if inputBufferProvidedForThisConversion {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                inputBufferProvidedForThisConversion = true
                return monoPCMBuffer
            }
            
            // 변환 실행
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if status == .error {
                print("Error during audio conversion: \(error?.localizedDescription ?? "Unknown error")")
                if let nsError = error {
                     DispatchQueue.main.async {
                         self.chatMessages.append(ChatMessage(text: "System: Audio conversion error - \(nsError.code)", sender: .system))
                    }
                }
                return
            }
            
            // 변환된 데이터가 있으면 즉시 재생
            if convertedBuffer.frameLength > 0 {
                // ✅ 단순화: 버퍼 큐 없이 즉시 재생
                audioPlayerNode.scheduleBuffer(convertedBuffer)
            }
        }
        
        // ✅ 단순화: 플레이어 시작 (필요한 경우)
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
    }
    
    // MARK: - Audio Playback Control
    
    private func stopAudioPlayback() {
        guard isAudioEngineSetup else { return }
        
        // ✅ 단순화: 오디오 중단만 하고 엔진 재시작 제거
        audioPlayerNode.stop()
        audioPlayerNode.reset()
    }
    
    // MARK: - AI Speaking State Management
    // ✅ 단순화: 서버 신호 기반으로만 상태 관리
    
    private func handleAIResponseStart() {
        DispatchQueue.main.async {
            if !self.isAISpeaking {
                self.isAISpeaking = true
                self.lastAIResponseTime = Date()
            }
        }
    }
    
    private func handleAIResponseComplete(reason: String) {
        DispatchQueue.main.async {
            self.isAISpeaking = false
            self.hasPendingGuidanceRequest = false
            self.lastAIResponseTime = Date()
            
            // ✅ 단순화: 버퍼 큐 제거로 추가 처리 불필요
        }
    }
    
    // checkIfAllAudioFinished 제거 - 단순화
    
    func canSendGuidanceRequest() -> Bool {
        return !isAISpeaking && !hasPendingGuidanceRequest
    }
    
    // MARK: - Audio Recording Methods
    
    // OLD version - to be replaced
    // func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    //     AVAudioSession.sharedInstance().requestRecordPermission { granted in
    //         DispatchQueue.main.async {
    //             completion(granted)
    //         }
    //     }
    // }

    // NEW async version
    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // Made public so AppState can control audio recording during STT
    func startRecording() { 
        guard isConnected else {
            DispatchQueue.main.async {
                self.chatMessages.append(ChatMessage(text: "System: Cannot start recording - not connected", sender: .system))
            }
            return
        }
        
        guard isAudioEngineSetup else {
            return
        }
        
        
        // **수정: 실제 녹음 시작 로직 복원**
        Task {
            // Microphone permission and start
            if await requestMicrophonePermission() { 
                await MainActor.run { 
                    self.startRecordingInternal()
                }
            } else {
                await MainActor.run {
                    self.chatMessages.append(ChatMessage(text: "System: Microphone permission denied for manual start.", sender: .system))
                }
                print("GeminiLiveAPIClient: Microphone permission denied during manual start.")
            }
        }
    }
    
    private func startRecordingInternal() {
        guard !isRecording else { 
            return 
        }
        
        // 오디오 엔진이 초기화되지 않았으면 초기화
        if !isAudioEngineSetup {
            setupAudioSession()
            setupAudioEngine()
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 입력 탭 설치
            if self.installInputTap() {
                self.startRecordingTimer()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.chatMessages.append(ChatMessage(text: "System: Recording started", sender: .system))
                }
            } else {
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(text: "System: Failed to start recording", sender: .system))
                }
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { 
            return 
        }
        
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 타이머 정지
            DispatchQueue.main.async {
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
            }
            
            // 입력 탭 제거
            if self.inputTapInstalled {
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.inputTapInstalled = false
            }
            
            // 마지막 누적된 오디오 데이터 전송
            if !self.accumulatedAudioData.isEmpty {
                self.sendAccumulatedAudioData()
            }
            
            DispatchQueue.main.async {
                self.isRecording = false
                self.chatMessages.append(ChatMessage(text: "System: Recording stopped", sender: .system))
            }
        }
    }
    
    private func installInputTap() -> Bool {
        guard !inputTapInstalled else { return true }
        
        let inputNode = audioEngine.inputNode
        
        // 오디오 엔진이 실행 중인지 확인
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                return false
            }
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Reduced logging - removed verbose format details
        
        do {
            // 실시간 오디오 처리를 위한 탭 설치
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
                self?.processAudioBuffer(buffer)
            }
            
            inputTapInstalled = true
            return true
        } catch {
            print("❌ GeminiClient: Failed to install input tap: \(error)")
            return false
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let targetFormat = audioInputFormatForEngine else { return }
        
        // 포맷 변환이 필요한지 확인
        let sourceFormat = buffer.format
        
        if sourceFormat.isEqual(targetFormat) {
            // 포맷이 동일하면 직접 사용
            saveAudioDataFromBuffer(buffer)
        } else {
            // 포맷 변환 필요
            convertAndSaveAudioBuffer(buffer, to: targetFormat)
        }
    }
    
    private func convertAndSaveAudioBuffer(_ sourceBuffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            print("Error: Could not create audio converter for recording")
            return
        }
        
        // 변환된 버퍼 크기 계산
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * 
                                                        (targetFormat.sampleRate / sourceBuffer.format.sampleRate)))
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            print("Error: Could not create converted buffer for recording")
            return
        }
        
        var error: NSError?
        var inputBufferProvided = false
        
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if inputBufferProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            inputBufferProvided = true
            return sourceBuffer
        }
        
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error {
            print("Error during audio conversion for recording: \(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        if convertedBuffer.frameLength > 0 {
            saveAudioDataFromBuffer(convertedBuffer)
        }
    }
    
    private func saveAudioDataFromBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        guard frameLength > 0 else {
            return
        }
        
        var audioData: Data?
        
        if buffer.format.commonFormat == .pcmFormatInt16 {
            guard let int16ChannelData = buffer.int16ChannelData else { 
                return 
            }
            let dataSize = frameLength * channelCount * MemoryLayout<Int16>.size
            audioData = Data(bytes: int16ChannelData[0], count: dataSize)
            
        } else if buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let floatChannelData = buffer.floatChannelData else { 
                return 
            }
            
            // Float32를 Int16으로 변환
            var int16Array = Array<Int16>(repeating: 0, count: frameLength * channelCount)
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    let floatValue = floatChannelData[channel][frame]
                    let clampedValue = max(-1.0, min(1.0, floatValue))
                    int16Array[frame * channelCount + channel] = Int16(clampedValue * 32767.0)
                }
            }
            
            audioData = Data(bytes: int16Array, count: int16Array.count * MemoryLayout<Int16>.size)
            
        } else {
            return
        }
        
        guard let validAudioData = audioData else {
            return
        }
        
        // 누적 데이터에 추가
        accumulatedAudioData.append(validAudioData)
    }
    
    private func startRecordingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: self.recordingChunkDuration, repeats: true) { _ in
                self.audioQueue.async {
                    Task { @MainActor in
                        self.sendAccumulatedAudioData()
                    }
                }
            }
        }
    }
    
    private func sendAccumulatedAudioData() {
        guard !accumulatedAudioData.isEmpty else { 
            return 
        }
        
        let dataSize = accumulatedAudioData.count
        
        // Base64로 인코딩
        let base64Data = accumulatedAudioData.base64EncodedString()
        
        // 실시간 입력 메시지 생성 및 전송
        sendRealtimeAudioInput(base64Data: base64Data)
        
        // 데이터 초기화
        accumulatedAudioData = Data()
    }
    
    private func sendRealtimeAudioInput(base64Data: String) {
        // ✅ 단순화: 과도한 로깅 제거
        
        let mediaChunk = RealtimeMediaChunk(mimeType: "audio/pcm;rate=24000", data: base64Data)
        let realtimeInput = RealtimeInputPayload(mediaChunks: [mediaChunk])
        let message = RealtimeInputMessage(realtimeInput: realtimeInput)
        
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(message)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
            }
        } catch {
            print("❌ GeminiLiveAPIClient: Audio encoding error: \(error)")
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.lastConnectedTime = Date()
            self.chatMessages.append(ChatMessage(text: "System: WebSocket Connected!", sender: .system))
            
            // 재연결 성공 시 카운터 리셋
            if self.reconnectAttempts > 0 {
                self.chatMessages.append(ChatMessage(
                    text: "System: Reconnection successful",
                    sender: .system
                ))
            }
            
            // 재연결 관련 상태 리셋
            cancelReconnectTimer()
            shouldAutoReconnect = true
            
            // ✅ 오디오 세션과 엔진 초기화 (아직 설정되지 않았다면)
            if !self.isAudioEngineSetup {
                self.setupAudioSession()
                self.setupAudioEngine()
            }
            
            // Send setup message with stored parameters
            if let params = setupParameters {
                sendSetupMessage(
                    modelName: params.modelName,
                    systemPrompt: params.systemPrompt,
                    voiceName: params.voiceName,
                    languageCode: params.languageCode,
                    includeGoogleSearch: params.includeGoogleSearch
                )
            }
            
            // ✅ 단순화: Stage 3 대기 중이라면 즉시 활성화
            if pendingStage3Activation {
                pendingStage3Activation = false
                enablePureConversationMode()
            }
            
            // Start audio recording
            if await requestMicrophonePermission() {
                self.startRecordingInternal()
            } else {
                self.chatMessages.append(ChatMessage(text: "System: Microphone permission denied for auto-start.", sender: .system))
                print("Microphone permission denied during auto-start for GeminiLiveAPIClient.")
            }
            
            // Start receiving messages
            self.receiveMessagesLoop()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            if self.isConnected {
                var reasonString = "Unknown reason"
                if let reasonData = reason, let str = String(data: reasonData, encoding: .utf8), !str.isEmpty {
                    reasonString = str
                }
                self.chatMessages.append(ChatMessage(text: "System: WebSocket Disconnected. Code: \(closeCode.rawValue), Reason: \(reasonString)", sender: .system))
            }
            self.isConnected = false
            
            var reasonStringLog = ""
            if let reason = reason, let str = String(data: reason, encoding: .utf8) {
                reasonStringLog = str
            }
            print("WebSocket connection closed: code \(closeCode.rawValue), reason: \(reasonStringLog)")
            self.webSocketTask = nil
            
            // 자동 재연결 처리
            handleConnectionClosed(closeCode: closeCode)
        }
    }
    
    // MARK: - Cleanup
    deinit {
        shouldAutoReconnect = false
        
        // MainActor 컨텍스트에서 실행
        Task { @MainActor in
            cancelReconnectTimer()
            // 오디오 세션 해제
            AudioSessionCoordinator.shared.releaseAudioSession(for: .geminiLiveAudio)
        }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // ✅ 단순화: 타이머 관련 코드 제거됨
        
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Video Frame Processing
    
    // ✅ 새로운 즉시 동기적 프레임 전송 메서드 (딜레이 최소화)
    func sendVideoFrameImmediately(pixelBuffer: CVPixelBuffer) {
        guard isConnected else {
            return
        }
        
        // ✅ 비디오 활성화 (동기적으로 처리)
        if !isVideoEnabled {
            isVideoEnabled = true
        }
        
        // ✅ CVPixelBuffer를 CIImage로 변환 (재사용 가능한 컨텍스트 사용)
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // ✅ iOS 카메라는 기본적으로 가로 방향이므로 세로로 회전
        ciImage = ciImage.oriented(.right)
        
        // ✅ 0.5배 스케일링으로 데이터 크기 줄임
        let targetScale: CGFloat = 0.5
        let scaleTransform = CGAffineTransform(scaleX: targetScale, y: targetScale)
        ciImage = ciImage.transformed(by: scaleTransform)
        
        // ✅ JPEG 데이터 생성 (재사용 가능한 컨텍스트로 성능 향상)
        guard let jpegData = reusableCIContext.jpegRepresentation(
            of: ciImage,
            colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) else {
            print("❌ GeminiLiveAPIClient: Failed to create JPEG data")
            return
        }
        
        // ✅ Base64 인코딩
        let base64ImageData = jpegData.base64EncodedString()
        
        // ✅ 디버그 이미지 업데이트 (동기적으로 처리)
        debugProcessedImage = UIImage(data: jpegData)
        
        // ✅ Gemini에 즉시 전송
        sendRealtimeVideoFrame(base64Data: base64ImageData)
        
        // 로깅 제거 (성능 향상)
    }
    
    // ✅ 실시간 비디오 프레임 전송 메서드 (로깅 간소화)
    private func sendRealtimeVideoFrame(base64Data: String) {
        let mediaChunk = RealtimeMediaChunk(mimeType: "image/jpeg", data: base64Data)
        let realtimeInput = RealtimeInputPayload(mediaChunks: [mediaChunk])
        let message = RealtimeInputMessage(realtimeInput: realtimeInput)
        
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(message)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendString(jsonString)
                // 로깅 제거 (성능 향상)
            }
        } catch {
            print("❌ GeminiLiveAPIClient: Video frame encoding error: \(error)")
        }
    }
    
    // ✅ 기존 메서드는 레거시용으로 유지하되 개선
    func processAndSendVideoFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, timestamp: TimeInterval) {
        // ✅ 새로운 즉시 전송 메서드로 리다이렉트
        sendVideoFrameImmediately(pixelBuffer: pixelBuffer)
    }

    // MARK: - Object Matching via Gemini API
    
    func findSimilarObject(koreanObjectName: String, availableObjects: [String], completion: @escaping (String?) -> Void) {
        
        // Clear English prompt for better matching
        let prompt = """
        You are helping with object detection matching. 
        
        User requested object in Korean: "\(koreanObjectName)"
        Available detected objects in English: \(availableObjects.joined(separator: ", "))
        
        Find the most similar English object name from the available list that matches the Korean object name.
        Reply with ONLY the exact English object name from the list, or "NOT_FOUND" if no reasonable match exists.
        
        Examples:
        - Korean "의자" should match English "chair"
        - Korean "책상" should match English "table" or "dining table"  
        - Korean "침대" should match English "bed"
        - Korean "소파" should match English "couch"
        - Korean "컴퓨터" should match English "laptop"
        - Korean "노트북" should match English "laptop"
        - Korean "핸드폰" should match English "cell phone"
        
        Reply with only the object name or NOT_FOUND.
        """
        
        // Use REST API for quick object matching
        sendRESTRequest(prompt: prompt) { [weak self] response in
            DispatchQueue.main.async {
                // Trim and process
                let trimmed = response?.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Simply check if the result is in available objects
                let matchedObject: String?
                if let result = trimmed, result != "NOT_FOUND", !result.isEmpty {
                    // Convert both to lowercase for comparison
                    let resultLower = result.lowercased()
                    
                    // Try exact match first
                    matchedObject = availableObjects.first { availableObject in
                        return availableObject.lowercased() == resultLower
                    }
                    
                } else {
                    matchedObject = nil
                    // Result is nil, empty, or NOT_FOUND
                }
                
                
                completion(matchedObject)
            }
        }
    }
    
    private func sendRESTRequest(prompt: String, completion: @escaping (String?) -> Void) {
        // Simple REST API call to Gemini for object matching
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)") else {
            completion(nil)
            return
        }
        
        // Send REST request
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            // Request prepared
        } catch {
            completion(nil)
            return
        }
        
        let startTime = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            
            // Check HTTP response
            
            if let error = error {
                completion(nil)
                return
            }
            
            guard let data = data else {
                completion(nil)
                return
            }
            
            // Process response
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check for error response
                    if let error = json["error"] as? [String: Any] {
                        completion(nil)
                        return
                    }
                    
                    // Extract text from response
                    if let candidates = json["candidates"] as? [[String: Any]],
                       let firstCandidate = candidates.first,
                       let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let firstPart = parts.first,
                       let text = firstPart["text"] as? String {
                        completion(text)
                    } else {
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }

    
    // ✅ 새로운 메서드: AI 상태 플래그 리셋
    func resetAISpeakingState() {
        DispatchQueue.main.async {
            self.isAISpeaking = false
            self.hasPendingGuidanceRequest = false
            self.lastAIResponseTime = Date()
        }
    }
    
    // ✅ Stage 3 자유 대화 모드 활성화
    func enablePureConversationMode() {
        guard isConnected else {
            return
        }
        
        // Stage 3 시작 프롬프트 전송
        let prompt = """
        당신은 시각장애인을 위한 AI 가이드입니다. 
        사용자가 목적지 근처에 도착했습니다.
        
        지금 즉시 다음과 같이 인사하고 도움을 제안하세요:
        "안녕하세요! 목적지 근처에 도착하셨네요. 주변 환경이나 물건 위치에 대해 궁금하신 점이 있으시면 편하게 물어봐 주세요. 제가 도와드리겠습니다."
        
        이후 사용자의 질문에 친절하고 상세하게 답변해주세요.
        """
        sendUserText(prompt)
        
        // 녹음이 활성화되어 있는지 확인
        if !isRecording {
            startRecording()
        }
    }

    // **추가: GeminiClient용 최신 프레임 제공 메서드**
    func getCurrentVideoFrameForGemini() -> String? {
        // ✅ ARViewModel에서 프레임을 가져와야 함 (URLSession이 아닌 ARSession 필요)
        guard let arViewModel = arViewModel else {
            print("❌ GeminiLiveAPIClient: ARViewModel not available")
            return nil
        }
        
        // ✅ ARSession의 currentFrame 사용
        guard let currentFrame = arViewModel.session.currentFrame else {
            print("❌ GeminiLiveAPIClient: No current frame from ARSession")
            return nil
        }
        
        // ✅ 즉시 필요한 데이터만 복사하고 ARFrame 참조 해제
        let pixelBuffer = currentFrame.capturedImage
        
        // ✅ autoreleasepool로 메모리 즉시 해제 + 자신의 재사용 가능한 CIContext 사용
        return autoreleasepool {
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            ciImage = ciImage.oriented(.right)
            
            let targetScale: CGFloat = 0.5
            let scaleTransform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            ciImage = ciImage.transformed(by: scaleTransform)
            
            // ✅ 자신의 재사용 가능한 CIContext 사용 (self 사용)
            guard let jpegData = self.reusableCIContext.jpegRepresentation(
                of: ciImage,
                colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
            ) else {
                print("❌ GeminiLiveAPIClient: Failed to create JPEG from current frame")
                return nil
            }
            
            return jpegData.base64EncodedString()
        }
    }
    
    // MARK: - Network Resilience Methods
    
    private func handleConnectionClosed(closeCode: URLSessionWebSocketTask.CloseCode) {
        // 정상 종료나 사용자가 의도한 종료인 경우 재연결하지 않음
        guard shouldAutoReconnect,
              closeCode != .normalClosure,
              closeCode != .goingAway else {
            print("✅ GeminiClient: Normal disconnection, not attempting reconnect")
            return
        }
        
        // 재연결 시도
        attemptReconnect()
    }
    
    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ GeminiClient: Max reconnection attempts reached")
            DispatchQueue.main.async {
                self.chatMessages.append(ChatMessage(
                    text: "System: Failed to reconnect after \(self.maxReconnectAttempts) attempts",
                    sender: .system
                ))
            }
            return
        }
        
        reconnectAttempts += 1
        
        print("🔄 GeminiClient: Attempting reconnection \(reconnectAttempts)/\(maxReconnectAttempts) in \(reconnectDelay)s")
        
        DispatchQueue.main.async {
            self.chatMessages.append(ChatMessage(
                text: "System: Reconnecting... (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))",
                sender: .system
            ))
        }
        
        // Exponential backoff으로 재연결 스케줄
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            if let params = self.setupParameters {
                self.connect(
                    modelName: params.modelName,
                    systemPrompt: params.systemPrompt,
                    voiceName: params.voiceName,
                    languageCode: params.languageCode,
                    includeGoogleSearch: params.includeGoogleSearch
                )
            } else {
                self.connect() // 기본 파라미터로 연결
            }
        }
        
        // 다음 시도를 위해 딜레이 증가 (exponential backoff)
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    }
    
    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
        reconnectDelay = 1.0
    }
    
    func resetConnection() {
        // 연결 상태 초기화 및 재연결
        disconnect()
        shouldAutoReconnect = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if let params = self.setupParameters {
                self.connect(
                    modelName: params.modelName,
                    systemPrompt: params.systemPrompt,
                    voiceName: params.voiceName,
                    languageCode: params.languageCode,
                    includeGoogleSearch: params.includeGoogleSearch
                )
            }
        }
    }
    
    // 연결 상태 모니터링
    func checkConnectionHealth() -> Bool {
        guard isConnected,
              let lastConnected = lastConnectedTime else {
            return false
        }
        
        // 30초 이상 응답이 없으면 연결 상태 의심
        let timeSinceLastResponse = Date().timeIntervalSince(lastAIResponseTime)
        if timeSinceLastResponse > 30 {
            print("⚠️ GeminiClient: No response for \(Int(timeSinceLastResponse))s, connection may be stale")
            return false
        }
        
        return true
    }
} 
