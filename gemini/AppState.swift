import Foundation
import SwiftUI

@MainActor
class AppState: ObservableObject, SpeechRecognitionDelegate {
    
    // MARK: - Navigation States (새로운 3단계 시스템)
    enum NavigationStage: String, CaseIterable {
        case sttScanningMode = "STT_Scanning_Mode"           // Stage 1: STT + AR 스캔 (Live API 연결 없음)
        case liveGuidanceMode = "Live_Guidance_Mode"         // Stage 2: Live API + 주기적 가이던스
        case pureConversationMode = "Pure_Conversation_Mode" // Stage 3: 순수 대화
    }
    
    // MARK: - Published Properties
    @Published var currentStage: NavigationStage = .sttScanningMode
    @Published var requestedObjectNameByUser: String = ""
    @Published var confirmedDetrObjectName: String? = nil
    @Published var isNavigationActive: Bool = false
    @Published var lastDetectedSpeech: String = "" // For debugging STT
    
    // MARK: - Stage 1 Specific Properties
    @Published var scannedObjectLabels: Set<String> = [] // 360도 스캔 중 누적된 객체들
    @Published var scanProgress: Float = 0.0 // 360도 회전 진행률 (0.0 ~ 1.0)
    @Published var isFullRotationComplete: Bool = false
    @Published var scanCompleted: Bool = false // ✅ 추가: 스캔 완료 플래그 (중복 호출 방지)
    @Published var objectMatchingInProgress: Bool = false // ✅ 추가: 객체 매칭 진행 플래그 (중복 호출 방지)
    
    // **Stage 1→2 전환을 위한 중심도 기준**
    private let requiredCenteredness: CGFloat = 0.85 // ✅ 85% 중심도 + 1초 유지 필요
    
    // MARK: - Stage 2 Specific Properties  
    @Published var guidanceTimer: Timer? = nil // 3초마다 자동 프롬프트용 타이머
    @Published var lastGuidanceTime: Date = Date.distantPast
    @Published var guidanceRequestCount: Int = 0 // 가이던스 요청 횟수
    
    // ✅ Stage 2→3 전환 안정성을 위한 프로퍼티
    @Published var stage3TransitionStartTime: Date? = nil
    private let stage3TransitionRequiredDuration: TimeInterval = 2.0 // 2초간 조건 유지 필요
    
    // ✅ 중복 요청 방지를 위한 프로퍼티
    @Published var isGuidanceRequestInProgress: Bool = false
    
    // MARK: - Audio Integration
    @Published var audioManager: AudioManager? = nil
    
    // MARK: - STT Integration
    @Published var speechManager: SpeechRecognitionManager
    
    // MARK: - AR Integration
    weak var arViewModel: ARViewModel?
    
    // MARK: - Gemini Integration  
    weak var geminiClient: GeminiLiveAPIClient?
    
    init() {
        self.speechManager = SpeechRecognitionManager()
        // AudioManager는 나중에 setupAudioManager()에서 초기화
        Task { @MainActor in
            self.speechManager.delegate = self
            // AudioManager 초기화는 Gemini Live API 연결 후로 연기
        }
    }
    
    // ✅ AudioManager 늦은 초기화 메서드
    private func setupAudioManager() {
        guard audioManager == nil else { return }
        
        print("AppState: Setting up AudioManager after Gemini Live API initialization")
        audioManager = AudioManager()
        audioManager?.checkAvailableAudioFiles()
        print("AppState: ✅ AudioManager setup completed")
    }
    
    // MARK: - STT Control
    func startListeningForKeywords() {
        guard currentStage == .sttScanningMode else {
            print("AppState: Not starting STT - not in STT scanning stage")
            return
        }
        
        // **Stage 1에서는 Gemini 소켓 연결하지 않음**
        if let geminiClient = geminiClient, geminiClient.isConnected {
            print("AppState: Disconnecting Gemini socket for Stage 1 (STT only)")
            geminiClient.disconnect()
        }
        
        // STT 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.speechManager.startListening()
            print("AppState: Started listening for Korean keywords in Stage 1")
        }
    }
    
    func stopListeningForKeywords() {
        speechManager.stopListening()
        print("AppState: Stopped listening for keywords")
    }
    
    // MARK: - SpeechRecognitionDelegate
    nonisolated func didDetectFindRequest(for objectName: String, in fullText: String) {
        Task { @MainActor in
            // Stage 1에서만 객체 찾기 요청 처리
            guard currentStage == .sttScanningMode else {
                print("AppState: Ignoring find request - not in STT scanning stage")
                return
            }
            
            lastDetectedSpeech = fullText
            setRequestedObject(objectName)
            
            // STT 중지
            speechManager.stopListening()
            print("AppState: STT stopped after keyword detection in Stage 1")
            
            // ✅ 5초 스캔이 완료되었다면 즉시 객체 매칭 진행
            if scanCompleted && !scannedObjectLabels.isEmpty {
                print("AppState: 5-second scan already completed, proceeding with object matching")
                requestGeminiObjectMatching()
            } else {
                print("AppState: 5-second scan not completed yet, starting AR scanning")
                // AR 스캔 시작
                startARScanning()
            }
        }
    }
    
    // MARK: - Stage Management
    func transitionTo(_ newStage: NavigationStage) {
        let previousStage = currentStage
        currentStage = newStage
        
        // ✅ Stage 전환 시 타이머 리셋
        stage3TransitionStartTime = nil
        
        print("AppState: Transitioned from \(previousStage.rawValue) to \(newStage.rawValue)")
        
        // ✅ 단순화: Stage 전환 시 과도한 cleanup 제거
        
        isNavigationActive = (newStage == .liveGuidanceMode || newStage == .pureConversationMode)
        
        handleStageEntry(newStage, from: previousStage)
    }
    
    private func handleStageEntry(_ stage: NavigationStage, from previousStage: NavigationStage) {
        switch stage {
        case .sttScanningMode:
            print("AppState: === STAGE 1: STT + AR Scanning Mode ===")
            
            // Reset all data
            requestedObjectNameByUser = ""
            confirmedDetrObjectName = nil
            isNavigationActive = false
            lastDetectedSpeech = ""
            scannedObjectLabels = []
            scanProgress = 0.0
            isFullRotationComplete = false
            scanCompleted = false // ✅ 추가: 스캔 완료 플래그 리셋
            objectMatchingInProgress = false // ✅ 추가: 객체 매칭 플래그 리셋
            guidanceRequestCount = 0
            
            stopPeriodicGuidance()
            
            // Disconnect Gemini for Stage 1 (STT only)
            if let geminiClient = geminiClient, geminiClient.isConnected {
                print("AppState: Disconnecting Gemini for Stage 1 (STT only)")
                geminiClient.disconnect()
            }
            
            arViewModel?.stopScanning()
            arViewModel?.stopHapticGuidance()
            
            // ✅ Audio-driven workflow: 환영 메시지 후 STT 시작
            if audioManager == nil {
                print("AppState: AudioManager not ready, setting up temporarily for Stage 1")
                setupAudioManager()
            }
            
            // ✅ 새로운 워크플로우: 5초 스캔 → 자동 질문
            audioManager?.playWelcomeRotateAudio { [weak self] in
                print("AppState: Welcome audio completed, starting 5-second scan")
                self?.startTenSecondScan()
            }
            
        case .liveGuidanceMode:
            print("AppState: === STAGE 2: Live Guidance Mode ===")
            
            speechManager.stopListening()
            print("AppState: STT stopped before Gemini connection")
            
            // ✅ KEEP HAPTIC: 햅틱 가이던스를 중단하지 않음
            // arViewModel?.stopHapticGuidance()  // ❌ 주석 처리
            
            // ✅ Audio confirmation: 타겟 락온 안내
            if let distance = arViewModel?.distanceToObject {
                audioManager?.playTargetLockedAudio(distance: distance) { [weak self] in
                    print("AppState: Target locked audio completed, starting guidance")
                    self?.connectToGeminiLiveAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.startPeriodicGuidance()
                    }
                }
            } else {
                // 거리 정보 없을 경우에도 오디오 파일 사용
                audioManager?.playTargetLockedAudio(distance: 0.0) { [weak self] in
                    print("AppState: Target locked audio completed, starting guidance")
                    self?.connectToGeminiLiveAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.startPeriodicGuidance()
                    }
                }
            }
            
        case .pureConversationMode:
            print("AppState: === STAGE 3: Pure Conversation Mode ===")
            
            stopPeriodicGuidance()
            
            // ✅ STAGE 3: 무조건 햅틱 피드백 중단 (Pure Conversation Mode)
            arViewModel?.stopHapticGuidance()
            print("AppState: Stopped haptic guidance - entering pure conversation mode")
            
            // ✅ 추가: 타겟 추적 완전 중단
            arViewModel?.userTargetObjectName = ""
            print("AppState: Cleared target object name - no more tracking")
            
            // ✅ 단순화: Stage 3 진입 시 중복 오디오 중단 제거
            // 녹음은 계속 유지하여 사용자 입력을 받을 수 있도록 함
            
            // ✅ AudioManager의 현재 재생도 중단
            audioManager?.stopAudio()
            
            // ✅ Stage 3: 재연결 없이 바로 대화 모드 활성화 (이미 Google Search 포함된 연결 사용)
            if let geminiClient = geminiClient {
                print("🔌 AppState: Activating Stage 3 conversation mode (no reconnection needed)")
                geminiClient.enablePureConversationMode()
            }
            
        }
    }
    
    // MARK: - Stage 1: AR Scanning Control
    
    // ✅ 새로운 메서드: 10초간 자동 스캔
    private func startTenSecondScan() {
        guard currentStage == .sttScanningMode else {
            print("AppState: Not starting scan - not in STT scanning stage")
            return
        }
        
        print("AppState: 🔍 Starting 5-second automatic scanning")
        print("AppState: ⏰ Timer set for 5 seconds - will auto-ask for object")
        
        // AR 스캔 시작 (객체 이름 없이)
        arViewModel?.startScanning(for: "")
        
        // 5초 스캔 진행 모니터링
        monitorTenSecondScan()
        
        // 5초 후 자동으로 질문 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.completeTenSecondScanAndAskUser()
        }
    }
    
    private func monitorTenSecondScan() {
        guard currentStage == .sttScanningMode, !scanCompleted else { 
            return 
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.currentStage == .sttScanningMode, !self.scanCompleted,
                  let arViewModel = self.arViewModel else { 
                return 
            }
            
            // 스캔된 객체들 누적
            self.scannedObjectLabels = arViewModel.allDetectedObjects
            
            // 계속 모니터링 (10초 동안)
            if !self.scanCompleted {
                self.monitorTenSecondScan()
            }
        }
    }
    
    private func completeTenSecondScanAndAskUser() {
        guard currentStage == .sttScanningMode, !scanCompleted else {
            print("AppState: ⚠️ 10-second scan already completed or stage changed")
            return
        }
        
        scanCompleted = true // ✅ 스캔 완료 표시
        print("AppState: ✅ 5-second scan completed. Found \(scannedObjectLabels.count) objects: \(Array(scannedObjectLabels))")
        
        // AR 스캔 중지
        arViewModel?.stopScanning()
        
        // ✅ 이미 유저가 객체를 요청했는지 확인
        if !requestedObjectNameByUser.isEmpty {
            print("AppState: User already requested object '\(requestedObjectNameByUser)', proceeding with matching")
            requestGeminiObjectMatching()
        } else {
            // 자동으로 질문 오디오 재생 후 STT 시작
            audioManager?.playAskObjectAudio { [weak self] in
                print("AppState: Ask what object audio completed, starting STT")
                self?.startListeningForKeywords()
            }
        }
    }
    
    private func startARScanning() {
        print("AppState: Starting AR scanning for: '\(requestedObjectNameByUser)'")
        
        // AR 스캔 시작
        arViewModel?.startScanning(for: requestedObjectNameByUser)
        
        // 스캔 진행 모니터링 시작
        monitorScanProgress()
    }
    
    private func monitorScanProgress() {
        guard currentStage == .sttScanningMode, !scanCompleted else { 
            if scanCompleted {
                print("AppState: ⚠️ Scan already completed, skipping monitorScanProgress")
            }
            return 
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.currentStage == .sttScanningMode, !self.scanCompleted,
                  let arViewModel = self.arViewModel else { 
                if self.scanCompleted {
                    print("AppState: ⚠️ Scan completed during monitoring, stopping")
                }
                return 
            }
            
            // Sync detected objects from ARViewModel
            self.scannedObjectLabels = arViewModel.allDetectedObjects
            self.scanProgress = arViewModel.scanProgress
            
            if arViewModel.scanProgress >= 1.0 {
                print("AppState: 🎯 Scan progress completed, calling completeScan()")
                self.completeScan()
            } else {
                self.monitorScanProgress()
            }
        }
    }
    
    private func completeScan() {
        // ✅ 중복 호출 방지
        guard !scanCompleted else {
            print("AppState: ⚠️ completeScan() already called, ignoring duplicate call")
            return
        }
        
        guard let arViewModel = arViewModel else { return }
        
        scanCompleted = true // ✅ 플래그 설정으로 추가 호출 방지
        
        // Always sync detected objects before proceeding
        scannedObjectLabels = arViewModel.allDetectedObjects
        print("AppState: ✅ Scan completed. Found target: \(arViewModel.foundTarget)")
        print("AppState: 📋 Total detected objects: \(scannedObjectLabels.count) - \(Array(scannedObjectLabels).sorted())")
        
        // Log scan completion summary
        
        // ✅ 5초 자동 스캔 중이었다면 단순히 누적만 하고 completeTenSecondScanAndAskUser가 처리
        if requestedObjectNameByUser.isEmpty {
            print("AppState: This was automatic 5-second scan, letting completeTenSecondScanAndAskUser handle it")
            return
        }
        
        // ✅ 사용자가 특정 객체를 요청한 상태에서의 스캔 완료
        if arViewModel.foundTarget {
            confirmedDetrObjectName = requestedObjectNameByUser
            arViewModel.userTargetObjectName = requestedObjectNameByUser
            startHapticGuidanceAndTransition()
        } else {
            requestGeminiObjectMatching()
        }
    }
    
    private func requestGeminiObjectMatching() {
        // ✅ 중복 호출 방지
        guard !objectMatchingInProgress else {
            print("AppState: ⚠️ Object matching already in progress, ignoring duplicate call")
            return
        }
        
        guard let geminiClient = geminiClient,
              let arViewModel = arViewModel else {
            print("AppState: Missing geminiClient or arViewModel for object matching")
            
            // ✅ Audio-driven transition: 객체 없음 안내
            audioManager?.playObjectNotFoundAudio { [weak self] in
                print("AppState: Object not found audio completed, transitioning to Stage 3")
                self?.transitionTo(.pureConversationMode)
            }
            return
        }
        
        // ✅ 최종 동기화: 객체 매칭 직전에 최신 상태로 동기화
        scannedObjectLabels = arViewModel.allDetectedObjects
        print("AppState: Final sync before matching - \(scannedObjectLabels.count) objects")
        
        let detectedObjects = Array(scannedObjectLabels).sorted() // Sort for consistent output
        guard !detectedObjects.isEmpty else {
            print("AppState: No objects detected for matching")
            // No objects detected
            
            // ✅ Audio-driven transition: 객체 없음 안내
            audioManager?.playObjectNotFoundAudio { [weak self] in
                print("AppState: Object not found audio completed, transitioning to Stage 3")
                self?.transitionTo(.pureConversationMode)
            }
            return
        }
        
        objectMatchingInProgress = true // ✅ 플래그 설정으로 중복 호출 방지
        print("AppState: 🔍 Requesting Gemini API matching for '\(requestedObjectNameByUser)' among: \(detectedObjects)")
        // Start object matching
        
        // ✅ WebSocket 연결 제거 - REST API는 WebSocket 없이도 작동
        // if !geminiClient.isConnected {
        //     geminiClient.connect()
        // }
        
        geminiClient.findSimilarObject(koreanObjectName: requestedObjectNameByUser, availableObjects: detectedObjects) { [weak self] matchedObject in
            guard let self = self else { return }
            
            // ✅ 플래그 해제
            DispatchQueue.main.async {
                self.objectMatchingInProgress = false
            }
            
            if let matchedObject = matchedObject {
                print("AppState: ✅ Gemini matched '\(self.requestedObjectNameByUser)' to '\(matchedObject)'")
                self.confirmedDetrObjectName = matchedObject
                
                DispatchQueue.main.async {
                    self.arViewModel?.userTargetObjectName = matchedObject
                    
                    // ✅ Audio + Haptic: 동시 시작 (Critical Requirement)
                    self.audioManager?.playObjectFoundHapticGuideAudio { [weak self] in
                        print("AppState: Object found haptic guide audio completed")
                    }
                    
                    // ✅ 객체 발견 특별 햅틱 패턴 (심장박동)
                    self.arViewModel?.playObjectFoundHaptic()
                    
                    // 햅틱 가이던스도 동시에 시작
                    self.startHapticGuidanceAndTransition()
                }
            } else {
                print("AppState: ❌ Gemini could not find a match for '\(self.requestedObjectNameByUser)'")
                
                // ✅ Audio-driven transition: 객체 없음 안내
                self.audioManager?.playObjectNotFoundAudio { [weak self] in
                    print("AppState: Object not found audio completed, transitioning to Stage 3")
                    self?.transitionTo(.pureConversationMode)
                }
            }
        }
    }
    
    private func startHapticGuidanceAndTransition() {
        guard let confirmedObject = confirmedDetrObjectName else { return }
        
        print("AppState: Starting haptic guidance for: '\(confirmedObject)'")
        
        // 햅틱 가이드 시작
        arViewModel?.startHapticGuidance(for: confirmedObject)
        
        // 타겟 도달 모니터링
        monitorTargetReached()
    }
    
    private func monitorTargetReached() {
        guard currentStage == .sttScanningMode else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.currentStage == .sttScanningMode,
                  let arViewModel = self.arViewModel else { return }
            
            // ✅ ARViewModel의 중앙 탐지 완료 상태 확인 (85%, 1초 유지)
            let currentCenteredness = arViewModel.detectedObjectCenteredness
            let isCenterDetectionCompleted = arViewModel.isCenterDetectionActive
            
            if isCenterDetectionCompleted {
                // ✅ 85% 중심도를 1초간 유지 완료 - Stage 2로 전환
                print("AppState: Center detection completed (85%, 1 second) - Centeredness: \(String(format: "%.1f", currentCenteredness * 100))%. Transitioning to Stage 2")
                
                // ✅ 추가: 거리 정보도 로깅
                if let distance = arViewModel.distanceToObject {
                    print("AppState: Target distance: \(String(format: "%.2f", distance))m")
                }
                
                // ✅ Stage 1→2 전환 햅틱 (상승 패턴)
                arViewModel.playStageTransitionHaptic(ascending: true)
                
                self.transitionTo(.liveGuidanceMode)
                return
            } else {
                // ✅ 중앙 탐지 진행 상태 피드백
                let progress = arViewModel.centerDetectionProgress
                if progress > 0 {
                    print("AppState: Center detection in progress - \(String(format: "%.1f", currentCenteredness * 100))%, Progress: \(String(format: "%.0f", progress * 100))%")
                } else {
                    print("AppState: Centeredness insufficient (\(String(format: "%.1f", currentCenteredness * 100))%), need 85% for 1 second")
                }
            }
            
            // 계속 모니터링
            self.monitorTargetReached()
        }
    }
    
    // MARK: - Stage 2: Periodic Guidance Control
    private func connectToGeminiLiveAPI() {
        guard let geminiClient = geminiClient else { 
            print("❌ AppState: No geminiClient reference - cannot connect")
            return 
        }
        
        // Stage 2에서도 Google Search 포함하여 연결 (Stage 3 재연결 방지)
        if !geminiClient.isConnected {
            print("🔌 AppState: Connecting to Gemini Live API for Stage 2 (with Google Search)")
            geminiClient.connect(includeGoogleSearch: true)
            
            // 연결 완료 대기 후 상태 확인
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if geminiClient.isConnected {
                    print("✅ AppState: Gemini Live API connected successfully")
                    print("   Recording: \(geminiClient.isRecording)")
                    print("   Video enabled: \(geminiClient.isVideoEnabled)")
                } else {
                    print("❌ AppState: Failed to connect to Gemini Live API")
                }
            }
        } else {
            print("✅ AppState: Gemini Live API already connected")
            print("   Recording: \(geminiClient.isRecording)")
            print("   Video enabled: \(geminiClient.isVideoEnabled)")
        }
    }
    
    private func startPeriodicGuidance() {
        stopPeriodicGuidance() // 기존 타이머 정리
        
        print("AppState: Starting robust guidance system with 2-second intervals")
        
        // ✅ 즉시 첫 가이던스 요청 전송
        self.sendPeriodicGuidanceRequest()
        
        // ✅ 견고한 2초 간격 타이머 시스템 (스마트 스킵으로 안전)
        guidanceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else {
                print("❌ AppState: Timer tick - self deallocated")
                return
            }
            
            guard self.currentStage == .liveGuidanceMode else {
                print("⏹️ AppState: Guidance timer stopped - stage changed to \(self.currentStage)")
                self.guidanceTimer?.invalidate()
                self.guidanceTimer = nil
                return
            }
            
            print("🔄 AppState: Timer tick #\(self.guidanceRequestCount + 1) - Stage: \(self.currentStage)")
            self.sendPeriodicGuidanceRequest()
        }
        
        print("AppState: ✅ Guidance timer started with 2s intervals")
        print("   Timer valid: \(guidanceTimer?.isValid ?? false)")
        print("   Current stage: \(currentStage)")
        
        // **추가: Stage 2에서 Stage 3로의 전환 모니터링 시작**
        monitorDistanceForStage3Transition()
    }
    
    // **추가: Stage 2 → Stage 3 전환 모니터링**
    private func monitorDistanceForStage3Transition() {
        guard currentStage == .liveGuidanceMode else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.currentStage == .liveGuidanceMode,
                  let arViewModel = self.arViewModel else { return }
            
            // **Stage 3 전환 조건: 80% 중심도 + 1m 이내 접근**
            let centeredness = arViewModel.detectedObjectCenteredness
            let distance = arViewModel.distanceToObject
            
            let isCenterConditionMet = centeredness > 0.8
            let isDistanceConditionMet = distance != nil && distance! < 1.0
            
            if isCenterConditionMet && isDistanceConditionMet {
                // ✅ 조건을 만족하면 타이머 시작 또는 체크
                if self.stage3TransitionStartTime == nil {
                    self.stage3TransitionStartTime = Date()
                    print("AppState: Stage 2→3 transition conditions met, starting 2-second stability timer")
                    print("   Centeredness: \(String(format: "%.1f", centeredness * 100))%, Distance: \(String(format: "%.2f", distance!))m")
                    print("✅ AppState: Pausing guidance requests during transition")
                } else {
                    // 타이머가 이미 시작됨 - 시간 체크
                    let elapsedTime = Date().timeIntervalSince(self.stage3TransitionStartTime!)
                    if elapsedTime >= self.stage3TransitionRequiredDuration {
                        print("AppState: Stage 2→3 transition confirmed after \(String(format: "%.1f", elapsedTime))s of stable conditions")
                        
                        // ✅ Stage 2→3 전환 햅틱 (축하 패턴)
                        arViewModel.playSuccessHapticPattern()
                        
                        self.transitionTo(.pureConversationMode)
                        return // 전환 완료
                    } else {
                        print("AppState: Stage 2→3 transition timer: \(String(format: "%.1f", elapsedTime))s / \(String(format: "%.0f", self.stage3TransitionRequiredDuration))s")
                        print("   Maintaining: Centeredness: \(String(format: "%.1f", centeredness * 100))%, Distance: \(String(format: "%.2f", distance!))m")
                    }
                }
                
                // ✅ 타이머 진행 중에도 계속 모니터링
                self.monitorDistanceForStage3Transition()
            } else {
                // ✅ 조건 미충족 시 타이머 리셋
                if self.stage3TransitionStartTime != nil {
                    print("AppState: Stage 2→3 transition conditions lost, resetting timer")
                    print("   Centeredness: \(String(format: "%.1f", centeredness * 100))%, Distance: \(distance != nil ? String(format: "%.2f", distance!) : "N/A")")
                    self.stage3TransitionStartTime = nil
                    print("✅ AppState: Resuming guidance requests")
                }
                // 조건 미충족 시 디버그 정보
                if !isCenterConditionMet {
                    print("AppState: Stage 2→3 Check: Centeredness insufficient: \(String(format: "%.1f", centeredness * 100))% (need 80%)")
                }
                if !isDistanceConditionMet {
                    if let d = distance {
                        print("AppState: Stage 2→3 Check: Distance too far: \(String(format: "%.2f", d))m (need <1.0m)")
                    } else {
                        print("AppState: Stage 2→3 Check: Distance not available")
                    }
                }
                
                // 계속 모니터링
                self.monitorDistanceForStage3Transition()
            }
        }
    }
    
    func stopPeriodicGuidance() {
        if guidanceTimer != nil {
            guidanceTimer?.invalidate()
            guidanceTimer = nil
            print("AppState: ✅ Periodic guidance timer stopped and invalidated")
        } else {
            print("AppState: ⚠️ No guidance timer to stop (already nil)")
        }
        
        // ✅ 추가 정보 로그
        print("AppState: Current stage: \(currentStage)")
        print("AppState: Guidance request count: \(guidanceRequestCount)")
        
        // ✅ 스마트 가이던스 시스템도 중단 (currentStage 변경으로 자동 중단됨)
        print("AppState: Smart guidance system will auto-stop on stage change")
    }
    
    private func sendPeriodicGuidanceRequest() {
        // ✅ 중복 요청 방지
        guard !isGuidanceRequestInProgress else {
            print("⏭️ AppState: Skipping guidance request - already in progress")
            return
        }
        
        // ✅ Stage 3 전환 타이머가 작동 중이면 가이던스 요청 중단
        if stage3TransitionStartTime != nil {
            print("⏸️ AppState: Pausing guidance requests - Stage 3 transition in progress")
            return
        }
        
        guard currentStage == .liveGuidanceMode,
              let geminiClient = geminiClient,
              let targetObject = confirmedDetrObjectName,
              let arViewModel = arViewModel else {
            print("❌ AppState: Cannot send guidance request - missing requirements")
            print("   Stage: \(currentStage)")
            print("   GeminiClient: \(geminiClient != nil ? "✅" : "❌")")
            print("   Target: \(confirmedDetrObjectName ?? "nil")")
            print("   ARViewModel: \(arViewModel != nil ? "✅" : "❌")")
            return
        }
        
        // ✅ 연결 상태 확인
        guard geminiClient.isConnected else {
            print("❌ AppState: Cannot send guidance - Gemini not connected")
            return
        }
        
        // ✅ 비디오 활성화 확인
        if !geminiClient.isVideoEnabled {
            print("⚠️ AppState: Video not enabled, enabling now")
            geminiClient.isVideoEnabled = true
        }
        
        // ✅ AI가 말하고 있으면 이번 요청 스킵 (강제 중단하지 않음)
        if geminiClient.isAISpeaking {
            print("⏸️ AppState: Skipping guidance request - AI still speaking")
            return
        }
        
        let now = Date()
        let timeSinceLastGuidance = now.timeIntervalSince(lastGuidanceTime)
        
        // **수정: 프롬프트에 변화 요소 추가로 응답 다양성 확보**
        guidanceRequestCount += 1
        
        // ✅ 거리 정보 추가
        let distanceInfo: String
        if let distance = arViewModel.distanceToObject {
            distanceInfo = "**현재 측정된 거리: \(String(format: "%.1f", distance))미터**"
        } else {
            distanceInfo = "**거리 측정 중...**"
        }
        
        let prompt = """
        찾는 물건: \(targetObject) (\(distanceInfo))
        
        카메라는 당신 눈 높이입니다. 어깨 폭 50cm 고려하세요.
        반드시 포함할 내용 (우선순위 순):
        1. 충돌 위험 장애물 (이름과 위치)
        2. 목표물 방향과 거리
        3. 안전한 이동 경로
        
        예시: "왼쪽에 의자, 우회하세요. 침대는 전방 2미터"
        20단어 이내, 장애물 우선.
        """
        
        lastGuidanceTime = now
        
        // ✅ 간단한 pending 상태 관리
        geminiClient.hasPendingGuidanceRequest = true
        
        print("🔄 AppState: Sending guidance request #\(guidanceRequestCount)")
        print("   Target: \(targetObject)")
        print("   Distance: \(arViewModel.distanceToObject?.description ?? "N/A")")
        print("   Time since last: \(String(format: "%.1f", timeSinceLastGuidance))s")
        print("   AI Speaking: \(geminiClient.isAISpeaking)")
        
        // ✅ Stage 2 주기적 가이던스: 녹음 유지하면서 텍스트+비디오 전송
        
        // ✅ 요청 진행 중 플래그 설정
        isGuidanceRequestInProgress = true
        
        // ✅ 비디오 프레임이 활성화되어 있는지 확인
        if geminiClient.isVideoEnabled {
            // ARViewModel에서 최신 프레임 강제 갱신 (동기적으로)
            if let arVM = self.arViewModel {
                _ = arVM.getCurrentVideoFrameForGemini() // 프레임 캐시 갱신
            }
            print("📹 AppState: Sending guidance with fresh video frame")
        }
        
        // **단순화: 기본 sendUserText 사용 (비디오 프레임 자동 포함)**
        geminiClient.sendUserText(prompt)
        
        // ✅ 2초 후 플래그 해제 (다음 요청 허용)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isGuidanceRequestInProgress = false
        }
        
        // ✅ 녹음은 계속 유지됨 (중단하지 않음)
        
        // ✅ 간단한 pending 해제 (타이머가 다음 요청 관리)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            geminiClient.hasPendingGuidanceRequest = false
            print("📝 AppState: Guidance request pending status cleared")
        }
    }
    
    // MARK: - Helper Methods
    func setRequestedObject(_ objectName: String) {
        requestedObjectNameByUser = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        print("AppState: Set requested object to: '\(requestedObjectNameByUser)'")
    }
    
    func resetNavigation() {
        stopListeningForKeywords()
        stopPeriodicGuidance()
        transitionTo(.sttScanningMode)
    }
    
    // MARK: - State Queries
    var isInARMode: Bool {
        return currentStage == .sttScanningMode || currentStage == .liveGuidanceMode
    }
    
    var shouldShowDebugInfo: Bool {
        return isInARMode
    }
    
    var currentStageDescription: String {
        switch currentStage {
        case .sttScanningMode:
            if requestedObjectNameByUser.isEmpty {
                return "Stage 1: 음성 인식 대기 중" + (speechManager.isListening ? " 🎤" : "")
            } else {
                return "Stage 1: '\(requestedObjectNameByUser)' 스캔 중"
            }
        case .liveGuidanceMode:
            return "Stage 2: Live 가이던스 중"
        case .pureConversationMode:
            return "Stage 3: 자유 대화 모드"
        }
    }
    
    // MARK: - AR Integration
    func setARViewModel(_ viewModel: ARViewModel) {
        self.arViewModel = viewModel
    }
    
    func setGeminiClient(_ client: GeminiLiveAPIClient) {
        self.geminiClient = client
        
        // ✅ Gemini Live API 설정 후 AudioManager 초기화
        setupAudioManager()
        
        // ✅ AppState 참조 설정 (Stage 체크용)
        client.appState = self
        
        // Connect ARViewModel with GeminiClient for fresh frames
        if let arViewModel = arViewModel {
            client.arViewModel = arViewModel
            print("AppState: Connected GeminiClient with ARViewModel for fresh frames")
        }
    }
} 