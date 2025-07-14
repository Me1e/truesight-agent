import Foundation
import SwiftUI

// MARK: - Error Types
enum TrueSightError: LocalizedError {
    // Network Errors
    case networkConnectionFailed
    case networkTimeout
    case apiKeyInvalid
    case websocketDisconnected
    
    // Audio Errors
    case audioSessionUnavailable
    case microphonePermissionDenied
    case audioEngineFailure
    case audioFileNotFound(filename: String)
    
    // AR Errors
    case arSessionFailure
    case arTrackingLost
    case lidarUnavailable
    case objectDetectionFailed
    
    // Speech Recognition Errors
    case speechRecognitionUnavailable
    case speechPermissionDenied
    case noSpeechDetected
    
    // Model Errors
    case mlModelLoadFailed(modelName: String)
    case mlInferenceFailed
    
    // System Errors
    case insufficientMemory
    case backgroundTaskExpired
    
    var errorDescription: String? {
        switch self {
        // Network
        case .networkConnectionFailed:
            return "네트워크 연결에 실패했습니다"
        case .networkTimeout:
            return "네트워크 연결 시간이 초과되었습니다"
        case .apiKeyInvalid:
            return "API 키가 유효하지 않습니다"
        case .websocketDisconnected:
            return "실시간 연결이 끊어졌습니다"
            
        // Audio
        case .audioSessionUnavailable:
            return "오디오 세션을 사용할 수 없습니다"
        case .microphonePermissionDenied:
            return "마이크 권한이 필요합니다"
        case .audioEngineFailure:
            return "오디오 엔진 오류가 발생했습니다"
        case .audioFileNotFound(let filename):
            return "오디오 파일을 찾을 수 없습니다: \(filename)"
            
        // AR
        case .arSessionFailure:
            return "AR 세션을 시작할 수 없습니다"
        case .arTrackingLost:
            return "AR 추적을 잃었습니다"
        case .lidarUnavailable:
            return "LiDAR 센서를 사용할 수 없습니다"
        case .objectDetectionFailed:
            return "객체 인식에 실패했습니다"
            
        // Speech
        case .speechRecognitionUnavailable:
            return "음성 인식을 사용할 수 없습니다"
        case .speechPermissionDenied:
            return "음성 인식 권한이 필요합니다"
        case .noSpeechDetected:
            return "음성이 감지되지 않았습니다"
            
        // Model
        case .mlModelLoadFailed(let modelName):
            return "ML 모델 로드 실패: \(modelName)"
        case .mlInferenceFailed:
            return "ML 추론 중 오류가 발생했습니다"
            
        // System
        case .insufficientMemory:
            return "메모리가 부족합니다"
        case .backgroundTaskExpired:
            return "백그라운드 작업이 만료되었습니다"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .networkConnectionFailed, .networkTimeout:
            return "네트워크 연결을 확인하고 다시 시도해주세요"
        case .apiKeyInvalid:
            return "올바른 API 키를 설정해주세요"
        case .websocketDisconnected:
            return "자동으로 재연결을 시도합니다"
        case .microphonePermissionDenied:
            return "설정에서 마이크 권한을 허용해주세요"
        case .speechPermissionDenied:
            return "설정에서 음성 인식 권한을 허용해주세요"
        case .lidarUnavailable:
            return "LiDAR가 지원되는 기기에서 실행해주세요"
        case .insufficientMemory:
            return "다른 앱을 종료하고 다시 시도해주세요"
        default:
            return "앱을 재시작해주세요"
        }
    }
}

// MARK: - Error Handler
@MainActor
class ErrorHandler: ObservableObject {
    static let shared = ErrorHandler()
    
    @Published var currentError: TrueSightError?
    @Published var showError = false
    @Published var errorHistory: [ErrorRecord] = []
    
    struct ErrorRecord {
        let error: TrueSightError
        let timestamp: Date
        let context: String
        let recovered: Bool
    }
    
    private let maxErrorHistory = 50
    
    private init() {}
    
    // MARK: - Error Handling
    
    func handle(_ error: TrueSightError, context: String = "", canRecover: Bool = true) {
        print("❌ ErrorHandler: \(error.localizedDescription ?? "Unknown error") - Context: \(context)")
        
        currentError = error
        showError = true
        
        // Record error
        let record = ErrorRecord(
            error: error,
            timestamp: Date(),
            context: context,
            recovered: false
        )
        errorHistory.append(record)
        
        // Limit history size
        if errorHistory.count > maxErrorHistory {
            errorHistory.removeFirst()
        }
        
        // Attempt recovery if possible
        if canRecover {
            attemptRecovery(for: error)
        }
    }
    
    // MARK: - Error Recovery
    
    private func attemptRecovery(for error: TrueSightError) {
        switch error {
        case .websocketDisconnected:
            // Trigger reconnection in GeminiLiveAPIClient
            NotificationCenter.default.post(name: .websocketReconnectRequired, object: nil)
            
        case .arTrackingLost:
            // Reset AR session
            NotificationCenter.default.post(name: .arSessionResetRequired, object: nil)
            
        case .audioSessionUnavailable:
            // Retry audio session setup
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AudioSessionCoordinator.shared.requestAudioSession(for: .audioPlayback)
            }
            
        case .mlModelLoadFailed:
            // Retry model loading
            NotificationCenter.default.post(name: .mlModelReloadRequired, object: nil)
            
        default:
            // No automatic recovery available
            break
        }
    }
    
    // MARK: - User Actions
    
    func dismissError() {
        showError = false
        currentError = nil
    }
    
    func retry() {
        if let error = currentError {
            dismissError()
            attemptRecovery(for: error)
        }
    }
    
    // MARK: - Error Statistics
    
    func errorCount(for type: TrueSightError) -> Int {
        errorHistory.filter { record in
            // Compare error types
            switch (record.error, type) {
            case (.networkConnectionFailed, .networkConnectionFailed),
                 (.networkTimeout, .networkTimeout),
                 (.apiKeyInvalid, .apiKeyInvalid),
                 (.websocketDisconnected, .websocketDisconnected),
                 (.audioSessionUnavailable, .audioSessionUnavailable),
                 (.microphonePermissionDenied, .microphonePermissionDenied),
                 (.audioEngineFailure, .audioEngineFailure),
                 (.arSessionFailure, .arSessionFailure),
                 (.arTrackingLost, .arTrackingLost),
                 (.lidarUnavailable, .lidarUnavailable),
                 (.objectDetectionFailed, .objectDetectionFailed),
                 (.speechRecognitionUnavailable, .speechRecognitionUnavailable),
                 (.speechPermissionDenied, .speechPermissionDenied),
                 (.noSpeechDetected, .noSpeechDetected),
                 (.mlInferenceFailed, .mlInferenceFailed),
                 (.insufficientMemory, .insufficientMemory),
                 (.backgroundTaskExpired, .backgroundTaskExpired):
                return true
            default:
                return false
            }
        }.count
    }
    
    var recentErrors: [ErrorRecord] {
        Array(errorHistory.suffix(10))
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let websocketReconnectRequired = Notification.Name("websocketReconnectRequired")
    static let arSessionResetRequired = Notification.Name("arSessionResetRequired")
    static let mlModelReloadRequired = Notification.Name("mlModelReloadRequired")
}

// MARK: - Error Alert View
struct ErrorAlertView: View {
    @ObservedObject var errorHandler = ErrorHandler.shared
    
    var body: some View {
        EmptyView()
            .alert(isPresented: $errorHandler.showError) {
                Alert(
                    title: Text("오류 발생"),
                    message: Text(errorHandler.currentError?.localizedDescription ?? "알 수 없는 오류"),
                    primaryButton: .default(Text("재시도")) {
                        errorHandler.retry()
                    },
                    secondaryButton: .cancel(Text("확인")) {
                        errorHandler.dismissError()
                    }
                )
            }
    }
}