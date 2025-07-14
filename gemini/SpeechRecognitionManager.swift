import Foundation
import Speech
import AVFoundation
import SwiftUI

@MainActor
class SpeechRecognitionManager: ObservableObject {
    
    // MARK: - Properties
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    @Published var isListening: Bool = false
    @Published var recognizedText: String = ""
    @Published var isAuthorized: Bool = false
    
    // Delegate for keyword detection
    weak var delegate: SpeechRecognitionDelegate?
    
    // MARK: - Korean Keyword Patterns
    private let findKeywordPatterns = [
        "찾아줘", "찾아", "찾고 싶어", "찾을 수 있어",
        "어디에 있어", "어디 있어", "어디야",
        "보여줘", "가르쳐줘", "알려줘",
        "찾기", "발견", "찾고 있어"
    ]
    
    // Find request keyword patterns - common Korean expressions for finding objects
    private let findRequestPatterns = [
        "찾아줘", "찾아주세요", "찾고싶어", "찾고 싶어", "찾고 있어", "어디야", "어디에", "어디있어",
        "보여줘", "보여주세요", "알려줘", "알려주세요", "도와줘", "도와주세요",
        "가르쳐줘", "가르쳐주세요"
    ]
    
    // Common Korean objects
    private let commonObjects = [
        "의자", "책상", "침대", "소파", "테이블",
        "컴퓨터", "노트북", "핸드폰", "폰", "휴대폰",
        "가방", "책", "컵", "물병", "리모컨",
        "열쇠", "키", "신발", "옷", "화분",
        "냉장고", "세탁기", "전자레인지", "텔레비전", "TV",
        "램프", "전등", "창문", "문", "카펫",
        "베개", "이불", "쿠션", "거울", "시계",
        // DETR 감지 가능한 추가 객체들
        "병", "그릇", "마우스", "키보드", "가위",
        "꽃병", "담요", "사과", "오렌지", "바나나"
    ]
    
    init() {
        // Initialize with Korean locale
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
        
        Task {
            await requestAuthorization()
        }
    }
    
    // MARK: - Authorization
    func requestAuthorization() async {
        // Request speech recognition authorization
        let speechAuthStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
        
        guard speechAuthStatus == .authorized else {
            print("SpeechRecognitionManager: Speech recognition not authorized")
            return
        }
        
        // Request microphone authorization
        let micAuthStatus = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        
        await MainActor.run {
            self.isAuthorized = micAuthStatus && speechAuthStatus == .authorized
            print("SpeechRecognitionManager: Authorization complete - \(self.isAuthorized)")
        }
    }
    
    // MARK: - Recognition Control
    func startListening() {
        guard isAuthorized else {
            print("SpeechRecognitionManager: Not authorized to start listening")
            return
        }
        
        guard !isListening else {
            print("SpeechRecognitionManager: Already listening")
            return
        }
        
        do {
            try startRecognition()
            isListening = true
            print("SpeechRecognitionManager: Started listening for Korean speech")
        } catch {
            print("SpeechRecognitionManager: Failed to start recognition: \(error)")
        }
    }
    
    func stopListening() {
        guard isListening else { return }
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        // 오디오 엔진 정리
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            print("SpeechRecognitionManager: Stopped audio engine")
        }
        
        // AudioSessionCoordinator에 세션 반납
        AudioSessionCoordinator.shared.releaseAudioSession(for: .speechRecognition)
        
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        
        print("SpeechRecognitionManager: Stopped listening and released audio session")
    }
    
    private func startRecognition() throws {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // AudioSessionCoordinator를 통해 오디오 세션 획듍
        let coordinator = AudioSessionCoordinator.shared
        if !coordinator.requestAudioSession(for: .speechRecognition) {
            throw NSError(domain: "SpeechRecognitionManager", code: 3, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to acquire audio session"])
        }
        
        print("SpeechRecognitionManager: Audio session acquired from coordinator")
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "SpeechRecognitionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Create recognition task
        guard let speechRecognizer = speechRecognizer else {
            throw NSError(domain: "SpeechRecognitionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }
        
        // **수정: 오디오 엔진 입력 탭 설치 시 기존 탭 확인**
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // **주의: 기존 탭이 설치되어 있을 수 있으므로 안전하게 처리**
        do {
            // 기존 탭 제거 (에러 무시)
            try? inputNode.removeTap(onBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            
            audioEngine.prepare()
            
            // **수정: 오디오 엔진이 이미 실행 중이면 시작하지 않음**
            if !audioEngine.isRunning {
                try audioEngine.start()
                print("SpeechRecognitionManager: Audio engine started for STT")
            } else {
                print("SpeechRecognitionManager: Audio engine already running, reusing")
            }
        } catch {
            print("SpeechRecognitionManager: Failed to setup audio engine: \(error)")
            throw error
        }
    }
    
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            print("SpeechRecognitionManager: Recognition error: \(error)")
            stopListening()
            return
        }
        
        guard let result = result else { return }
        
        let transcription = result.bestTranscription.formattedString
        recognizedText = transcription
        
        // Check for find patterns in Korean
        checkForFindPattern(in: transcription)
        
        if result.isFinal {
            print("SpeechRecognitionManager: Final result: \(transcription)")
            
            // Restart listening after a brief pause for continuous monitoring
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.isListening {
                    self.stopListening()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startListening()
                    }
                }
            }
        }
    }
    
    // MARK: - Korean Pattern Detection
    private func checkForFindPattern(in text: String) {
        let lowercasedText = text.lowercased()
        
        // Check if any find keywords are present
        let hasKeyword = findKeywordPatterns.contains { keyword in
            lowercasedText.contains(keyword.lowercased())
        }
        
        guard hasKeyword else { return }
        
        // Extract object name
        if let objectName = extractObjectName(from: lowercasedText) {
            print("SpeechRecognitionManager: Detected find request for: '\(objectName)'")
            delegate?.didDetectFindRequest(for: objectName, in: text)
        }
    }
    
    private func extractObjectName(from text: String) -> String? {
        // Find the first mentioned object
        for object in commonObjects {
            if text.contains(object.lowercased()) {
                return object
            }
        }
        
        // If no common object found, try to extract using patterns
        return extractObjectFromPattern(text)
    }
    
    private func extractObjectFromPattern(_ text: String) -> String? {
        // Pattern: "X 찾아줘" -> extract X
        for keyword in findRequestPatterns {
            if let range = text.range(of: keyword.lowercased()) {
                let beforeKeyword = String(text[..<range.lowerBound])
                let words = beforeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                if let lastWord = words.last, lastWord.count > 1 {
                    return lastWord
                }
            }
        }
        
        // Pattern: "X 어디에 있어" -> extract X
        for pattern in ["어디에 있어", "어디 있어", "어디야"] {
            if let range = text.range(of: pattern) {
                let beforePattern = String(text[..<range.lowerBound])
                let words = beforePattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                if let lastWord = words.last, lastWord.count > 1 {
                    return lastWord
                }
            }
        }
        
        return nil
    }
    
    deinit {
        Task { @MainActor in
            stopListening()
        }
        print("SpeechRecognitionManager: Deinitialized")
    }
}

// MARK: - Delegate Protocol
protocol SpeechRecognitionDelegate: AnyObject {
    func didDetectFindRequest(for objectName: String, in fullText: String)
} 