import Foundation
import Combine

// MARK: - Navigation State Machine
@MainActor
class NavigationStateMachine: ObservableObject {
    
    // MARK: - State Definition
    enum State: String, CaseIterable {
        case idle = "Idle"
        case sttScanning = "STT_Scanning"
        case objectMatching = "Object_Matching"
        case hapticGuidance = "Haptic_Guidance"
        case liveGuidance = "Live_Guidance"
        case conversation = "Conversation"
        
        var description: String {
            switch self {
            case .idle: return "대기 중"
            case .sttScanning: return "음성 인식 중"
            case .objectMatching: return "객체 매칭 중"
            case .hapticGuidance: return "햅틱 가이드 중"
            case .liveGuidance: return "실시간 가이드 중"
            case .conversation: return "대화 모드"
            }
        }
    }
    
    // MARK: - Event Definition
    enum Event: Hashable {
        case start
        case voiceCommandReceived(objectName: String)
        case scanCompleted(foundObjects: Set<String>)
        case objectMatched(objectName: String)
        case objectNotFound
        case targetReached
        case targetApproached(distance: Float)
        case reset
        case error(String) // Error 타입을 String으로 변경 (Hashable 지원)
        
        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.start, .start), (.objectNotFound, .objectNotFound), 
                 (.targetReached, .targetReached), (.reset, .reset):
                return true
            case let (.voiceCommandReceived(l), .voiceCommandReceived(r)):
                return l == r
            case let (.scanCompleted(l), .scanCompleted(r)):
                return l == r
            case let (.objectMatched(l), .objectMatched(r)):
                return l == r
            case let (.targetApproached(l), .targetApproached(r)):
                return l == r
            case let (.error(l), .error(r)):
                return l == r
            default:
                return false
            }
        }
        
        func hash(into hasher: inout Hasher) {
            switch self {
            case .start:
                hasher.combine("start")
            case .voiceCommandReceived(let name):
                hasher.combine("voiceCommandReceived")
                hasher.combine(name)
            case .scanCompleted(let objects):
                hasher.combine("scanCompleted")
                hasher.combine(objects)
            case .objectMatched(let name):
                hasher.combine("objectMatched")
                hasher.combine(name)
            case .objectNotFound:
                hasher.combine("objectNotFound")
            case .targetReached:
                hasher.combine("targetReached")
            case .targetApproached(let distance):
                hasher.combine("targetApproached")
                hasher.combine(distance)
            case .reset:
                hasher.combine("reset")
            case .error(let message):
                hasher.combine("error")
                hasher.combine(message)
            }
        }
    }
    
    // MARK: - Properties
    @Published private(set) var currentState: State = .idle
    @Published private(set) var previousState: State = .idle
    @Published private(set) var stateHistory: [State] = []
    @Published private(set) var requestedObject: String = ""
    @Published private(set) var matchedObject: String? = nil
    @Published private(set) var isTransitioning = false
    
    // Dependencies
    weak var appState: AppState?
    weak var arViewModel: ARViewModel?
    weak var geminiClient: GeminiLiveAPIClient?
    weak var audioManager: AudioManager?
    
    // State-specific data
    private var stateData: [String: Any] = [:]
    private let maxHistorySize = 10
    
    // MARK: - State Transition Rules
    // 연관 값이 있는 Event를 위해 함수로 처리
    private func getNextState(from state: State, for event: Event) -> State? {
        switch (state, event) {
        case (.idle, .start):
            return .sttScanning
            
        case (.sttScanning, .voiceCommandReceived):
            return .objectMatching
        case (.sttScanning, .reset):
            return .idle
            
        case (.objectMatching, .objectMatched):
            return .hapticGuidance
        case (.objectMatching, .objectNotFound):
            return .conversation
        case (.objectMatching, .reset):
            return .idle
            
        case (.hapticGuidance, .targetReached):
            return .liveGuidance
        case (.hapticGuidance, .reset):
            return .idle
            
        case (.liveGuidance, .targetApproached):
            return .conversation
        case (.liveGuidance, .reset):
            return .idle
            
        case (.conversation, .reset):
            return .idle
            
        default:
            return nil
        }
    }
    
    // MARK: - State Machine Methods
    
    func handleEvent(_ event: Event) {
        guard !isTransitioning else {
            print("⚠️ StateMachine: Transition in progress, ignoring event")
            return
        }
        
        print("📊 StateMachine: Handling event \(event) in state \(currentState)")
        
        // Extract parameters from event
        switch event {
        case .voiceCommandReceived(let objectName):
            requestedObject = objectName
        case .objectMatched(let objectName):
            matchedObject = objectName
        case .scanCompleted(let objects):
            stateData["scannedObjects"] = objects
        case .targetApproached(let distance):
            stateData["targetDistance"] = distance
        default:
            break
        }
        
        // Find next state based on current state and event
        let nextState = findNextState(for: event)
        
        if let next = nextState, next != currentState {
            transition(to: next, triggeredBy: event)
        } else if nextState == nil {
            print("⚠️ StateMachine: No transition defined for event \(event) in state \(currentState)")
        }
    }
    
    private func findNextState(for event: Event) -> State? {
        return getNextState(from: currentState, for: event)
    }
    
    private func eventsMatch(_ pattern: Event, _ event: Event) -> Bool {
        switch (pattern, event) {
        case (.start, .start),
             (.reset, .reset),
             (.objectNotFound, .objectNotFound),
             (.targetReached, .targetReached):
            return true
        case (.voiceCommandReceived, .voiceCommandReceived),
             (.objectMatched, .objectMatched),
             (.scanCompleted, .scanCompleted),
             (.targetApproached, .targetApproached):
            return true
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
    
    private func transition(to newState: State, triggeredBy event: Event) {
        isTransitioning = true
        
        // Exit current state
        exitState(currentState)
        
        // Update state
        previousState = currentState
        currentState = newState
        
        // Update history
        stateHistory.append(newState)
        if stateHistory.count > maxHistorySize {
            stateHistory.removeFirst()
        }
        
        print("✅ StateMachine: Transitioned from \(previousState) to \(currentState)")
        
        // Enter new state
        enterState(newState, triggeredBy: event)
        
        isTransitioning = false
    }
    
    // MARK: - State Entry/Exit Actions
    
    private func exitState(_ state: State) {
        switch state {
        case .sttScanning:
            // STT 종료 처리는 AppState에서 자동으로 수행
            break
            
        case .hapticGuidance:
            arViewModel?.stopHapticGuidance()
            
        case .liveGuidance:
            appState?.stopPeriodicGuidance()
            
        default:
            break
        }
    }
    
    private func enterState(_ state: State, triggeredBy event: Event) {
        switch state {
        case .idle:
            // Reset all data
            requestedObject = ""
            matchedObject = nil
            stateData.removeAll()
            appState?.resetNavigation()
            
        case .sttScanning:
            // Start STT
            appState?.transitionTo(.sttScanningMode)
            
        case .objectMatching:
            // Start object matching process
            if let objects = stateData["scannedObjects"] as? Set<String> {
                performObjectMatching(requestedObject: requestedObject, availableObjects: Array(objects))
            }
            
        case .hapticGuidance:
            // Start haptic guidance
            if let matched = matchedObject {
                arViewModel?.startHapticGuidance(for: matched)
                startTargetMonitoring()
            }
            
        case .liveGuidance:
            // Start live guidance mode
            appState?.transitionTo(.liveGuidanceMode)
            
        case .conversation:
            // Enter conversation mode
            appState?.transitionTo(.pureConversationMode)
        }
    }
    
    // MARK: - Helper Methods
    
    private func performObjectMatching(requestedObject: String, availableObjects: [String]) {
        guard let geminiClient = geminiClient else {
            handleEvent(.objectNotFound)
            return
        }
        
        geminiClient.findSimilarObject(
            koreanObjectName: requestedObject,
            availableObjects: availableObjects
        ) { [weak self] matchedObject in
            guard let self = self else { return }
            
            if let matched = matchedObject {
                self.handleEvent(.objectMatched(objectName: matched))
            } else {
                self.handleEvent(.objectNotFound)
            }
        }
    }
    
    private func startTargetMonitoring() {
        // Monitor target reach status
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self,
                  self.currentState == .hapticGuidance,
                  let arViewModel = self.arViewModel else {
                timer.invalidate()
                return
            }
            
            // Check if target is reached (85% centeredness for 1 second)
            if arViewModel.isCenterDetectionActive {
                timer.invalidate()
                self.handleEvent(.targetReached)
            }
        }
    }
    
    func reset() {
        handleEvent(.reset)
    }
    
    // MARK: - State Queries
    
    var isInARMode: Bool {
        return [.sttScanning, .objectMatching, .hapticGuidance, .liveGuidance].contains(currentState)
    }
    
    var canAcceptVoiceCommand: Bool {
        return currentState == .sttScanning
    }
    
    var isNavigating: Bool {
        return [.hapticGuidance, .liveGuidance].contains(currentState)
    }
    
    var stateDescription: String {
        var description = currentState.description
        
        switch currentState {
        case .sttScanning:
            if !requestedObject.isEmpty {
                description += " - '\(requestedObject)'"
            }
        case .hapticGuidance, .liveGuidance:
            if let matched = matchedObject {
                description += " - '\(matched)'"
            }
        default:
            break
        }
        
        return description
    }
}