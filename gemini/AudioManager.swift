import Foundation
import AVFoundation
import SwiftUI

@MainActor
class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    // MARK: - Published Properties
    @Published var isPlayingAudio: Bool = false
    @Published var currentAudioFile: String = ""
    @Published var audioProgress: Float = 0.0
    
    // MARK: - Private Properties
    private var audioPlayer: AVAudioPlayer?
    private var onCompletionCallback: (() -> Void)?
    private var progressTimer: Timer?
    
    // MARK: - Audio Session Setup
    override init() {
        super.init()
        // 초기화 시에는 오디오 세션을 설정하지 않음
        // 실제 재생 시에만 설정
        checkAvailableAudioFiles()
    }
    
    // ✅ 유연한 오디오 세션 설정
    private func setupAudioSessionIfNeeded() -> Bool {
        let coordinator = AudioSessionCoordinator.shared
        
        // 이미 적절한 모드가 활성화되어 있으면 그대로 사용
        if coordinator.currentAudioMode == .geminiLiveAudio || 
           coordinator.currentAudioMode == .audioPlayback {
            print("🎵 AudioManager: Using existing audio session mode: \(coordinator.currentAudioMode)")
            return true
        }
        
        // 필요한 경우에만 오디오 세션 요청
        if coordinator.requestAudioSession(for: .audioPlayback) {
            print("✅ AudioManager: Audio session acquired")
            return true
        } else {
            // 실패 시 직접 설정 시도
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord,
                                            mode: .default,
                                            options: [.defaultToSpeaker, .mixWithOthers])
                try audioSession.setActive(true)
                print("🔄 AudioManager: Direct audio session setup successful")
                return true
            } catch {
                print("❌ AudioManager: Audio session setup failed: \(error)")
                // 에러가 발생해도 계속 진행
                return false
            }
        }
    }
    
    // MARK: - Main Audio Playback Methods
    
    /// 기본 오디오 파일 재생
    func playAudioFile(_ filename: String, onComplete: (() -> Void)? = nil) {
        print("AudioManager: Playing audio file: \(filename)")
        
        guard let url = Bundle.main.url(forResource: filename.replacingOccurrences(of: ".wav", with: ""), withExtension: "wav") else {
            print("AudioManager: ❌ Audio file not found: \(filename)")
            print("AudioManager: ❌ CRITICAL ERROR - Audio file missing. Please add to Xcode project.")
            
            // ❌ TTS 제거 - 오디오 파일이 없으면 에러 처리만
            onComplete?()
            return
        }
        
        stopAudio() // 기존 오디오 중지
        
        // 필요한 경우에만 오디오 세션 설정
        if !setupAudioSessionIfNeeded() {
            print("AudioManager: ⚠️ Audio session not available, attempting playback anyway")
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            // 추가 볼륨 부스트 설정
            audioPlayer?.enableRate = true
            audioPlayer?.volume = 1.0  // 최대 볼륨 (공식 범위: 0.0~1.0)
            
            // 시스템 볼륨을 최대로 설정 시도
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            } catch {
                print("AudioManager: ⚠️ Failed to override audio port: \(error)")
            }
            
            isPlayingAudio = true
            currentAudioFile = filename
            onCompletionCallback = onComplete
            
            startProgressTimer()
            audioPlayer?.play()
            
            print("AudioManager: 📢 Volume set to \(audioPlayer?.volume ?? 0.0) (Max: 1.0)")
            print("AudioManager: 🔊 Audio output forced to speaker")
            
            print("AudioManager: ✅ Started playing \(filename)")
            
        } catch {
            print("AudioManager: ❌ Failed to play audio: \(error)")
            isPlayingAudio = false
            onComplete?()
        }
    }
    
    // MARK: - Progress Tracking
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }
    }
    
    private func updateProgress() {
        guard let player = audioPlayer, player.isPlaying else {
            stopProgressTimer()
            return
        }
        
        if player.duration > 0 {
            audioProgress = Float(player.currentTime / player.duration)
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        audioProgress = 0.0
    }
    
    // MARK: - Audio Control
    
    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        stopProgressTimer()
        
        isPlayingAudio = false
        currentAudioFile = ""
        
        // 오디오 세션 해제 (다른 앱이 사용할 수 있도록)
        AudioSessionCoordinator.shared.releaseAudioSession(for: .audioPlayback)
        
        print("AudioManager: Audio stopped")
    }
    
    func pauseAudio() {
        audioPlayer?.pause()
        stopProgressTimer()
        print("AudioManager: Audio paused")
    }
    
    func resumeAudio() {
        audioPlayer?.play()
        startProgressTimer()
        print("AudioManager: Audio resumed")
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("AudioManager: Audio finished playing successfully: \(flag)")
        Task { @MainActor in
            self.handleAudioCompletion()
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("AudioManager: ❌ Audio decode error: \(String(describing: error))")
        Task { @MainActor in
            self.handleAudioCompletion()
        }
    }
    
    // MARK: - Completion Handling
    
    private func handleAudioCompletion() {
        stopProgressTimer()
        
        isPlayingAudio = false
        currentAudioFile = ""
        
        let callback = onCompletionCallback
        onCompletionCallback = nil
        
        print("AudioManager: ✅ Audio completion detected, calling callback")
        callback?()
    }
    
    // MARK: - Utility Methods
    
    /// 사용 가능한 오디오 파일 목록 확인
    func checkAvailableAudioFiles() {
        let requiredFiles = [
            "welcome_rotate_360.wav",
            "ask_what_object.wav", 
            "object_not_found.wav",
            "object_found_haptic_guide.wav",
            "target_locked_distance.wav",
            "target_reached_final.wav"
        ]
        
        print("AudioManager: Checking required audio files...")
        for filename in requiredFiles {
            let baseFilename = filename.replacingOccurrences(of: ".wav", with: "")
            if Bundle.main.url(forResource: baseFilename, withExtension: "wav") != nil {
                print("✅ Found: \(filename)")
            } else {
                print("❌ Missing: \(filename)")
            }
        }
    }
    
    deinit {
        progressTimer?.invalidate()
        audioPlayer?.stop()
        
        // 오디오 세션 해제
        Task { @MainActor in
            AudioSessionCoordinator.shared.releaseAudioSession(for: .audioPlayback)
        }
    }
}

// MARK: - Predefined Audio Files
extension AudioManager {
    
    /// Stage 1 진입시 환영 및 회전 안내
    func playWelcomeRotateAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("welcome_rotate_360.wav", onComplete: onComplete)
    }
    
    /// 360도 회전 완료 후 객체 문의
    func playAskObjectAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("ask_what_object.wav", onComplete: onComplete)
    }
    
    /// 객체를 찾지 못했을 때
    func playObjectNotFoundAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("object_not_found.wav", onComplete: onComplete)
    }
    
    /// 객체 발견 및 햅틱 가이드 시작
    func playObjectFoundHapticGuideAudio(onComplete: (() -> Void)? = nil) {
        playAudioFile("object_found_haptic_guide.wav", onComplete: onComplete)
    }
    
    /// 타겟 락온 및 Stage 2 진입
    func playTargetLockedAudio(distance: Float, onComplete: (() -> Void)? = nil) {
        playAudioFile("target_locked_distance.wav", onComplete: onComplete)
    }
    
    /// 타겟 도달 및 Stage 3 진입
    func playTargetReachedAudio(distance: Float, onComplete: (() -> Void)? = nil) {
        playAudioFile("target_reached_final.wav", onComplete: onComplete)
    }
} 