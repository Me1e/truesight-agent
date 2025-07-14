import Foundation
import AVFoundation

@MainActor
class AudioSessionCoordinator: ObservableObject {
    static let shared = AudioSessionCoordinator()
    
    @Published var isAudioSessionActive = false
    @Published var currentAudioMode: AudioMode = .idle
    
    enum AudioMode {
        case idle
        case speechRecognition  // STT
        case geminiLiveAudio    // Gemini Live API
        case audioPlayback      // AudioManager
    }
    
    private let audioSession = AVAudioSession.sharedInstance()
    private var isConfigured = false
    
    private init() {
        configureAudioSession()
        observeAudioSessionChanges()
    }
    
    private func configureAudioSession() {
        do {
            // 기본 설정: 녹음과 재생 모두 지원
            try audioSession.setCategory(.playAndRecord,
                                        mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            
            // 샘플레이트 설정 (Gemini API 요구사항)
            try audioSession.setPreferredSampleRate(24000.0)
            try audioSession.setPreferredIOBufferDuration(0.02)
            
            isConfigured = true
            print("✅ AudioSessionCoordinator: Initial configuration completed")
        } catch {
            print("❌ AudioSessionCoordinator: Configuration failed: \(error)")
        }
    }
    
    func requestAudioSession(for mode: AudioMode) -> Bool {
        guard isConfigured else {
            print("❌ AudioSessionCoordinator: Not configured")
            return false
        }
        
        // 현재 모드와 요청 모드가 충돌하는지 확인
        if currentAudioMode != .idle && currentAudioMode != mode {
            print("⚠️ AudioSessionCoordinator: Mode transition - current: \(currentAudioMode), requested: \(mode)")
            
            // 모든 전환을 허용하되 적절히 처리
            switch (currentAudioMode, mode) {
            case (.speechRecognition, .geminiLiveAudio):
                // STT → Gemini 전환 (Stage 1→2)
                print("🔀 Transitioning from STT to Gemini")
                // 세션 비활성화 없이 바로 전환
            case (.geminiLiveAudio, .audioPlayback),
                 (.audioPlayback, .geminiLiveAudio):
                // Gemini와 AudioManager는 공존
                print("🤝 Allowing coexistence of Gemini and AudioManager")
            case (.geminiLiveAudio, .speechRecognition):
                // Gemini → STT는 비활성화 필요
                deactivateCurrentMode()
            default:
                // 기타 전환도 허용하되 경고 표시
                print("⚠️ Allowing mode transition with caution")
            }
        }
        
        // 요청된 모드에 맞게 세션 구성
        do {
            switch mode {
            case .speechRecognition:
                // STT용 설정
                try audioSession.setCategory(.record, mode: .measurement)
                try audioSession.setActive(true)
                
            case .geminiLiveAudio:
                // Gemini Live API용 설정
                try audioSession.setCategory(.playAndRecord,
                                            mode: .voiceChat,
                                            options: [.defaultToSpeaker, .allowBluetooth])
                try audioSession.setActive(true)
                
            case .audioPlayback:
                // AudioManager용 설정 - playAndRecord로 변경하여 호환성 개선
                try audioSession.setCategory(.playAndRecord,
                                            mode: .default,
                                            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
                try audioSession.setActive(true)
                
            case .idle:
                // 비활성화
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
            
            currentAudioMode = mode
            isAudioSessionActive = (mode != .idle)
            
            print("✅ AudioSessionCoordinator: Mode changed to \(mode)")
            return true
            
        } catch {
            print("❌ AudioSessionCoordinator: Failed to set mode \(mode): \(error)")
            return false
        }
    }
    
    func releaseAudioSession(for mode: AudioMode) {
        // 모드 불일치 경고만 표시하고 해제는 허용
        if currentAudioMode != mode {
            print("⚠️ AudioSessionCoordinator: Mode mismatch warning - current: \(currentAudioMode), releasing: \(mode)")
        }
        
        // AudioManager와 Gemini가 공존하는 경우 처리
        if mode == .audioPlayback && currentAudioMode == .geminiLiveAudio {
            // AudioManager 해제 시 Gemini 모드 유지
            print("🔄 AudioSessionCoordinator: Keeping Gemini mode active after AudioManager release")
            return
        }
        
        // 현재 모드가 idle이 아닌 경우에만 비활성화
        if currentAudioMode != .idle {
            deactivateCurrentMode()
        }
    }
    
    private func deactivateCurrentMode() {
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            currentAudioMode = .idle
            isAudioSessionActive = false
            print("✅ AudioSessionCoordinator: Audio session deactivated")
        } catch {
            print("❌ AudioSessionCoordinator: Deactivation failed: \(error)")
        }
    }
    
    private func observeAudioSessionChanges() {
        // 오디오 세션 인터럽션 감지
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        
        // 라우트 변경 감지
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("⚠️ AudioSessionCoordinator: Audio session interrupted")
            // 필요시 현재 작업 일시중지
            
        case .ended:
            print("✅ AudioSessionCoordinator: Audio session interruption ended")
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // 오디오 세션 재활성화
                    _ = requestAudioSession(for: currentAudioMode)
                }
            }
            
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            print("📱 AudioSessionCoordinator: New audio device available")
        case .oldDeviceUnavailable:
            print("📱 AudioSessionCoordinator: Audio device unavailable")
        case .categoryChange:
            print("📱 AudioSessionCoordinator: Audio category changed")
        default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}