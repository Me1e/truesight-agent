import SwiftUI
import ARKit
import Vision
import CoreHaptics
import RealityKit
import Accelerate

// FourCharCode를 문자열로 변환하기 위한 유틸리티 (디버깅용)
extension FourCharCode {
    func toString() -> String {
        let cString: [CChar] = [
            CChar(self >> 24 & 0xFF),
            CChar(self >> 16 & 0xFF),
            CChar(self >> 8  & 0xFF),
            CChar(self >> 0  & 0xFF),
            0 // Null terminator
        ]
        return String(cString: cString)
    }
}

@MainActor
class ARViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var detectedObjectCenteredness: CGFloat = 0.0
    @Published var distanceToObject: Float? = nil
    @Published var raycastHitTransform: simd_float4x4? = nil
    @Published var detectedObjectLabels: [String] = []
    @Published var userTargetObjectName: String = "bed"
    @Published var lastDepthMap: CVPixelBuffer? = nil
    @Published var depthMapPreviewImage: Image? = nil
    
    // Scanning mode properties
    @Published var isScanningMode: Bool = false
    @Published var scanningTargetObject: String = ""
    @Published var scanProgress: Float = 0.0
    @Published var foundTarget: Bool = false
    
    // Haptic guidance properties
    @Published var isHapticGuideActive: Bool = false
    @Published var hapticGuidanceDirection: String = ""
    @Published var isTargetReached: Bool = false
    
    // ✅ 거리값 안정성을 위한 프로퍼티
    private var recentDistances: [Float] = []
    private let maxDistanceHistory = 5
    private var lastValidDistance: Float? = nil  // ✅ 마지막 유효한 거리값 저장

    // ✅ 중앙 탐지 강화를 위한 새로운 프로퍼티들 (Stage 1→2 전환용)
    @Published var centerDetectionProgress: Float = 0.0 // 중앙 탐지 진행률 (0.0 ~ 1.0)
    @Published var isCenterDetectionActive: Bool = false // 중앙 탐지가 활성화된 상태
    private let centerDetectionThreshold: CGFloat = 0.85 // 85% 중앙 탐지 임계값 (Stage 1→2)

    // ARKit properties
    var arView: ARView?
    let session = ARSession()
    private let sceneReconstruction: ARConfiguration.SceneReconstruction = .mesh
    
    // ✅ 라이다 기반 정확한 거리 측정을 위한 새로운 프로퍼티들
    @Published var lidarBasedDistance: Float? = nil // 라이다 직접 측정 거리
    private var lastLidarProcessingTime = TimeInterval(0)
    private let lidarProcessingInterval: TimeInterval = 0.5 // 라이다 처리 간격 (0.5초 -> 0.2초로 개선)

    // Vision properties
    private var segmentationModel: VNCoreMLModel?
    private var depthModel: VNCoreMLModel?
    private let visionQueue = DispatchQueue(label: "com.example.gemini.visionQueue", qos: .utility)
    private let confidenceThreshold: VNConfidence = 0.5
    
    // Haptics properties
    private var hapticEngine: CHHapticEngine?
    private var lastHapticTime: Date?
    private var debugSphere: ModelEntity?

    // Throttling properties
    private var lastFrameProcessingTime = TimeInterval(0)
    private let processingInterval: TimeInterval = 0.5 // Vision 처리 간격 (0.1초 -> 0.5초로 증가하여 ARFrame retention 감소)
    
    // ✅ Gemini 프레임 전송 시간 추적 추가
    private var lastGeminiFrameTime = TimeInterval(0)
    
    // Gemini API Client
    weak var geminiClient: GeminiLiveAPIClient?
    
    // ✅ 로딩 관리자 참조 추가
    weak var loadingManager: LoadingManager?

    // Class Labels for DETR model (원본 lidar test 프로젝트의 레이블 사용)
    private let detrClassLabels: [String] = {
        let labels = ["--", "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light", "fire hydrant", "--", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "--", "backpack", "umbrella", "--", "--", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "--", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed", "--", "dining table", "--", "--", "toilet", "--", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "--", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush", "--", "banner", "blanket", "--", "bridge", "--", "--", "--", "--", "cardboard", "--", "--", "--", "--", "--", "--", "counter", "--", "curtain", "--", "--", "door", "--", "--", "--", "--", "--", "floor (wood)", "flower", "--", "--", "fruit", "--", "--", "gravel", "--", "--", "house", "--", "light", "--", "--", "mirror", "--", "--", "--", "--", "net", "--", "--", "pillow", "--", "--", "platform", "playingfield", "--", "railroad", "river", "road", "--", "roof", "--", "--", "sand", "sea", "shelf", "--", "--", "snow", "--", "stairs", "--", "--", "--", "--", "tent", "--", "towel", "--", "--", "wall (brick)", "--", "--", "--", "wall (stone)", "wall (tile)", "wall (wood)", "water (other)", "--", "window (blind)", "window (other)", "--", "--", "tree", "fence", "ceiling", "sky (other)", "cabinet", "table", "floor (other)", "pavement", "mountain", "grass", "dirt", "paper", "food (other)", "building (other)", "rock", "wall (other)", "rug"]
        
        // ✅ 레이블 배열 유효성 검증
        guard !labels.isEmpty else {
            print("❌ CRITICAL: detrClassLabels is empty! This will cause crashes.")
            return ["--", "unknown"] // 최소한의 fallback
        }
        
        // ✅ 예상 크기 검증 (DETR는 보통 80-200개 클래스)
        guard labels.count > 50 else {
            print("❌ WARNING: detrClassLabels count (\(labels.count)) seems too small")
            return labels // ✅ 누락된 return 추가
        }
        
        print("✅ ARViewModel: detrClassLabels initialized with \(labels.count) classes")
        return labels
    }()

    // Object history accumulation
    @Published var allDetectedObjects: Set<String> = [] // 누적된 모든 객체들
    @Published var objectDetectionHistory: [(timestamp: Date, objects: [String])] = [] // 시간별 히스토리
    private let maxHistoryEntries = 50 // 최대 히스토리 개수

    // ✅ 추가: 햅틱 모니터링 취소용 작업 추적
    private var hapticMonitoringTask: DispatchWorkItem?

    init(geminiClient: GeminiLiveAPIClient? = nil, loadingManager: LoadingManager? = nil) {
        self.geminiClient = geminiClient
        self.loadingManager = loadingManager
        super.init()
        loadVisionModels()
        setupHaptics()
    }

    // MARK: - AR Session Management
    func setupARSession() {
        // ✅ AR 카메라 초기화 시작 알림
        loadingManager?.updateProgress(step: 1, message: "AR 카메라 초기화 중...")
        
        guard ARWorldTrackingConfiguration.isSupported else {
            print("ARViewModel: ARWorldTrackingConfiguration is not supported on this device.")
            ErrorHandler.shared.handle(.arSessionFailure, context: "AR not supported on this device")
            return
        }
        
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = sceneReconstruction
        } else {
            print("ARViewModel: Mesh reconstruction is not supported on this device for ARViewModel.")
        }
        configuration.planeDetection = [.horizontal, .vertical]
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            configuration.frameSemantics.insert(.personSegmentationWithDepth)
            // print("ARViewModel: Person segmentation with depth is supported and enabled.") // Already know this from logs
        } else {
            print("ARViewModel: Person segmentation with depth is not supported on this device for ARViewModel.")
        }

        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        print("ARViewModel: ARSession.run() called successfully.") // More specific log
        
        // ✅ AR 카메라 초기화 완료 알림
        loadingManager?.completeCurrentStep()
    }

    func pauseARSession() {
        session.pause()
        lastHapticTime = nil
        print("ARViewModel: ARSession paused.")
    }

    // MARK: - ARSessionDelegate
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ✅ autoreleasepool로 메모리 즉시 해제
        autoreleasepool {
            let currentTime = frame.timestamp
            
            // ✅ ARFrame 참조 최소화: 필요한 데이터만 즉시 복사
            let pixelBuffer = frame.capturedImage
            let cameraTransform = frame.camera.transform
            
            // ✅ 라이다 데이터는 별도로 추출 (frame 참조 최소화)
            let sceneDepth = frame.sceneDepth?.depthMap
            
            // MainActor 컨텍스트에서 실행
            Task { @MainActor in
                // ✅ 라이다 기반 거리 측정 (성능 개선: 0.5초 간격)
                if currentTime - lastLidarProcessingTime >= lidarProcessingInterval {
                    lastLidarProcessingTime = currentTime
                    // ✅ frame 대신 필요한 데이터만 전달
                    processLidarDistanceMeasurementOptimized(sceneDepth: sceneDepth, cameraTransform: cameraTransform)
                }
                
                // ✅ Gemini로 프레임 전송: 정확한 1초 간격으로 수정
                if let geminiClient = geminiClient, geminiClient.isConnected {
                    // ✅ 기존 부정확한 조건 제거하고 정확한 1초 간격으로 수정
                    if currentTime - lastGeminiFrameTime >= 1.0 {
                        lastGeminiFrameTime = currentTime
                        
                        // ✅ 즉시 동기적으로 프레임 전송 (비동기 제거)
                        geminiClient.sendVideoFrameImmediately(pixelBuffer: pixelBuffer)
                    }
                }

                // ✅ Vision 처리 주기 체크 (0.5초 간격)
                guard currentTime - lastFrameProcessingTime >= processingInterval else {
                    return
                }
                lastFrameProcessingTime = currentTime
                
                // ✅ ARFrame 없이 필요한 데이터만 전달
                processFrameForVision(pixelBuffer: pixelBuffer, cameraTransform: cameraTransform, timestamp: currentTime)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARViewModel: ARSession failed: \(error.localizedDescription)")
        
        Task { @MainActor in
            // AR 세션 오류 처리
            if let arError = error as? ARError {
                switch arError.code {
                case .cameraUnauthorized:
                    ErrorHandler.shared.handle(.arSessionFailure, context: "Camera access denied")
                case .unsupportedConfiguration:
                    ErrorHandler.shared.handle(.arSessionFailure, context: "Unsupported AR configuration")
                case .insufficientFeatures:
                    ErrorHandler.shared.handle(.arTrackingLost, context: "Insufficient features for tracking")
                case .worldTrackingFailed:
                    ErrorHandler.shared.handle(.arTrackingLost, context: "World tracking failed")
                default:
                    ErrorHandler.shared.handle(.arSessionFailure, context: "AR error: \(error.localizedDescription)")
                }
            } else {
                ErrorHandler.shared.handle(.arSessionFailure, context: "Unknown AR error: \(error.localizedDescription)")
            }
        }
    }

    // **추가: GeminiClient용 최신 프레임 제공 메서드**
    func getCurrentVideoFrameForGemini() -> String? {
        // ✅ 프레임 캐시를 통한 효율적인 처리
        guard let currentFrame = session.currentFrame else {
            return nil
        }
        
        // ✅ 즉시 필요한 데이터만 복사하고 ARFrame 참조 해제
        let pixelBuffer = currentFrame.capturedImage
        
        // ✅ autoreleasepool로 메모리 즉시 해제 + GeminiClient의 재사용 가능한 CIContext 사용
        return autoreleasepool {
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            ciImage = ciImage.oriented(.right)
            
            let targetScale: CGFloat = 0.5
            let scaleTransform = CGAffineTransform(scaleX: targetScale, y: targetScale)
            ciImage = ciImage.transformed(by: scaleTransform)
            
            // ✅ GeminiClient의 재사용 가능한 CIContext 사용 (성능 향상)
            guard let jpegData = geminiClient?.reusableCIContext.jpegRepresentation(
                of: ciImage,
                colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
            ) else {
                return nil
            }
            
            return jpegData.base64EncodedString()
        }
    }

    // MARK: - Vision Processing
    private func loadVisionModels() {
        // ✅ 로딩 시작 알림
        loadingManager?.updateProgress(step: 2, message: "객체 인식 모델 로딩 중...")
        
        // ✅ 백그라운드 큐에서 모델 로딩 (메인 스레드 블로킹 방지)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // ✅ detrClassLabels 사전 검증
            guard !self.detrClassLabels.isEmpty else {
                print("❌ CRITICAL: detrClassLabels is empty - Vision processing will be disabled")
                DispatchQueue.main.async {
                    self.segmentationModel = nil
                    self.depthModel = nil
                }
                return
            }
            
            print("✅ ARViewModel: detrClassLabels verified with \(self.detrClassLabels.count) classes")
            
            do {
                // ✅ DETR 세그멘테이션 모델 로딩
                guard let segModelURL = Bundle.main.url(forResource: "DETRResnet50SemanticSegmentationF16", withExtension: "mlmodelc") else {
                    print("❌ ARViewModel: DETR Segmentation model file not found.")
                    Task { @MainActor in
                        ErrorHandler.shared.handle(.mlModelLoadFailed(modelName: "DETR Segmentation"), context: "Model file not found")
                    }
                    DispatchQueue.main.async {
                        self.segmentationModel = nil
                    }
                    return
                }
                
                let segModel = try MLModel(contentsOf: segModelURL)
                let visionModel = try VNCoreMLModel(for: segModel)
                
                DispatchQueue.main.async {
                    self.segmentationModel = visionModel
                    print("✅ ARViewModel: DETR Segmentation model loaded successfully.")
                    
                    // ✅ 객체 인식 모델 로딩 완료 알림
                    self.loadingManager?.completeCurrentStep()
                }
                
                // ✅ 모델 출력 검증
                let modelDescription = segModel.modelDescription
                print("ARViewModel: DETR Model info:")
                print("   Input: \(modelDescription.inputDescriptionsByName.keys.joined(separator: ", "))")
                print("   Output: \(modelDescription.outputDescriptionsByName.keys.joined(separator: ", "))")
                
            } catch {
                print("❌ ARViewModel: Error loading DETR Segmentation model: \(error)")
                print("❌ ARViewModel: Vision processing will be limited without segmentation model")
                Task { @MainActor in
                    ErrorHandler.shared.handle(.mlModelLoadFailed(modelName: "DETR Segmentation"), context: "Load error: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    self.segmentationModel = nil
                }
            }

            // ✅ 깊이 추정 모델 로딩 시작 알림
            DispatchQueue.main.async {
                self.loadingManager?.updateProgress(step: 3, message: "깊이 추정 모델 로딩 중...")
            }
            
            do {
                // ✅ Depth 모델 로딩
                guard let depthModelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16P6", withExtension: "mlmodelc") else {
                    print("❌ ARViewModel: Depth Anything model file not found.")
                    Task { @MainActor in
                        ErrorHandler.shared.handle(.mlModelLoadFailed(modelName: "Depth Estimation"), context: "Model file not found")
                    }
                    DispatchQueue.main.async {
                        self.depthModel = nil
                    }
                    return
                }
                
                let depthMLModel = try MLModel(contentsOf: depthModelURL)
                let depthVisionModel = try VNCoreMLModel(for: depthMLModel)
                
                DispatchQueue.main.async {
                    self.depthModel = depthVisionModel
                    print("✅ ARViewModel: Depth Anything model loaded successfully.")
                    
                    // ✅ 깊이 추정 모델 로딩 완료 알림
                    self.loadingManager?.completeCurrentStep()
                }
                
            } catch {
                print("❌ ARViewModel: Error loading Depth Anything model: \(error)")
                print("❌ ARViewModel: Depth estimation will be unavailable")
                Task { @MainActor in
                    ErrorHandler.shared.handle(.mlModelLoadFailed(modelName: "Depth Estimation"), context: "Load error: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    self.depthModel = nil
                }
            }
            
            // ✅ 최종 상태 검증 (백그라운드에서)
            DispatchQueue.main.async {
                let segmentationAvailable = self.segmentationModel != nil
                let depthAvailable = self.depthModel != nil
                
                print("ARViewModel: Vision models status:")
                print("   - Segmentation: \(segmentationAvailable ? "✅" : "❌")")
                print("   - Depth: \(depthAvailable ? "✅" : "❌")")
                print("   - Class labels: \(self.detrClassLabels.count) classes")
                
                if !segmentationAvailable && !depthAvailable {
                    print("❌ ARViewModel: WARNING - No vision models available, app functionality will be severely limited")
                }
                
                // ✅ 모든 모델 로딩 완료 알림
                self.loadingManager?.updateProgress(step: 4, message: "AI 음성 시스템 준비 중...")
            }
        }
    }

    private func processFrameForVision(pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4, timestamp: TimeInterval) {
        // ✅ detrClassLabels 먼저 검증
        guard !detrClassLabels.isEmpty else {
            print("❌ ARViewModel: detrClassLabels is empty, skipping frame processing")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        guard let segModel = segmentationModel, let depthEstModel = depthModel else {
            // 로깅 빈도 줄임 (성능 개선)
            // 로깅 제거 (성능 향상)
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }

        // ✅ 성능 최적화: Vision 요청 설정
        let segmentationRequest = VNCoreMLRequest(model: segModel) { [weak self] request, error in
            // ✅ ARFrame 매개변수 제거로 메모리 누수 방지
            self?.processSegmentationResults(for: request, cameraTransform: cameraTransform, error: error)
        }
        segmentationRequest.imageCropAndScaleOption = .scaleFill
        // ✅ 성능 개선: 이미지 크기 제한
        segmentationRequest.usesCPUOnly = false // GPU 사용 허용

        let depthRequest = VNCoreMLRequest(model: depthEstModel) { [weak self] request, error in
            self?.processDepthResults(for: request, error: error)
        }
        depthRequest.imageCropAndScaleOption = .scaleFill
        depthRequest.usesCPUOnly = false // GPU 사용 허용

        // ✅ Vision 처리를 비동기 큐에서 실행 (우선순위 낮춤)
        visionQueue.async {
            autoreleasepool { // ✅ 메모리 즉시 해제
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                do {
                    try handler.perform([segmentationRequest, depthRequest])
                } catch {
                    // 에러 로깅 제거 (성능 향상)
                    Task { @MainActor in
                        ErrorHandler.shared.handle(.objectDetectionFailed, context: "Vision request failed: \(error.localizedDescription)")
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.clearVisionResults()
                    }
                }
                // ✅ autoreleasepool로 메모리 즉시 해제됨
            }
        }
    }
    
    private func clearVisionResults() {
        self.detectedObjectLabels = []
        self.detectedObjectCenteredness = 0.0
        self.distanceToObject = nil
        self.lastValidDistance = nil  // ✅ 마지막 유효 거리값도 리셋
        self.raycastHitTransform = nil
        self.lastDepthMap = nil
        self.depthMapPreviewImage = nil
        self.updateDebugSphere()
        self.updateHapticFeedback(centeredness: 0.0)
    }

    // MARK: - DETR Segmentation Results Processing
    private func processSegmentationResults(for request: VNRequest, cameraTransform: simd_float4x4, error: Error?) {
        guard error == nil else {
            print("ARViewModel: Error processing DETR segmentation: \(error!.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let segmentationMap = results.first?.featureValue.multiArrayValue else {
            print("ARViewModel: Unexpected result type or could not get MultiArray from DETR model.")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        // ✅ detrClassLabels 배열 유효성 먼저 검사
        guard !detrClassLabels.isEmpty else {
            print("❌ ARViewModel: detrClassLabels is empty - cannot process segmentation")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        let shapeDimensions = segmentationMap.shape.map { $0.intValue }
        guard shapeDimensions.count >= 2 else {
            print("❌ ARViewModel: Invalid segmentation map shape")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        let height = shapeDimensions[shapeDimensions.count - 2]
        let width = shapeDimensions[shapeDimensions.count - 1]
        
        // ✅ 메모리 크기 검증 및 안전 장치 강화
        let expectedDataSize = height * width
        let actualDataSize = segmentationMap.count
        
        guard expectedDataSize == actualDataSize && expectedDataSize > 0 && height > 0 && width > 0 else {
            print("❌ ARViewModel: Segmentation map size mismatch - expected: \(expectedDataSize), actual: \(actualDataSize), dims: \(width)x\(height)")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        // ✅ MLMultiArray 데이터 포인터 안전 검사
        guard segmentationMap.dataType == .int32,
              let dataPointer = try? segmentationMap.dataPointer.bindMemory(to: Int32.self, capacity: actualDataSize) else {
            print("❌ ARViewModel: Cannot access segmentation data safely or wrong data type")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        var detectedClassIDs = Set<Int32>()
        var targetPixelCoordinates: [(x: Int, y: Int)] = []
        
        let targetObjectNameLowercased = self.userTargetObjectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var validTargetClassID: Int? = nil
        if !targetObjectNameLowercased.isEmpty {
            validTargetClassID = detrClassLabels.firstIndex(where: { $0.lowercased() == targetObjectNameLowercased })
        }

        // ✅ 더 안전한 픽셀 순회 및 검증 with early exit
        let maxClassID = Int32(detrClassLabels.count - 1)
        
        // ✅ 배열 접근 오류 완전 방지를 위한 안전 검사 강화
        guard maxClassID >= 0 && detrClassLabels.count > 0 else {
            print("❌ ARViewModel: Invalid detrClassLabels array state - count: \(detrClassLabels.count)")
            DispatchQueue.main.async { [weak self] in self?.clearVisionResults() }
            return
        }
        
        for y_coord in 0..<height {
            for x_coord in 0..<width {
                let index = y_coord * width + x_coord
                
                // ✅ 인덱스 경계 검사 강화
                guard index >= 0 && index < actualDataSize else {
                    continue // 로깅 제거하여 성능 향상
                }
                
                let classID = dataPointer[index]
                
                // ✅ classID 범위 검사 - 더 엄격한 검증
                guard classID >= 0 && classID <= maxClassID else {
                    continue // 로깅 제거하여 성능 향상
                }

                // ✅ 배열 접근 전 triple 안전 검사
                let classIndex = Int(classID)
                guard classIndex >= 0 && 
                      classIndex < detrClassLabels.count && 
                      detrClassLabels.indices.contains(classIndex) else {
                    continue // 로깅 제거하여 성능 향상
                }
                
                // ✅ 이제 완전히 안전하게 배열 접근
                let labelValue = detrClassLabels[classIndex]
                if classID > 0 && labelValue != "--" && !labelValue.isEmpty {
                    detectedClassIDs.insert(classID)
                }
                
                if let targetID = validTargetClassID, classID == Int32(targetID) {
                    targetPixelCoordinates.append((x: x_coord, y: y_coord))
                }
            }
        }
        
        // ✅ 안전한 라벨 변환 - 추가 검증
        let finalLabels: [String] = detectedClassIDs.compactMap { id in
            let index = Int(id)
            // ✅ 이중 검사
            guard index >= 0 && index < detrClassLabels.count else { 
                print("❌ ARViewModel: Invalid index \(index) for detrClassLabels (count: \(detrClassLabels.count))")
                return nil 
            }
            
            let label = detrClassLabels[index]
            guard label != "--" && !label.isEmpty else { 
                return nil 
            }
            return label
        }.sorted()

        var targetCenterPoint: CGPoint? = nil
        var currentCenteredness: CGFloat = 0.0

        if !targetPixelCoordinates.isEmpty && validTargetClassID != nil {
            let totalX = targetPixelCoordinates.reduce(0) { $0 + $1.x }
            let totalY = targetPixelCoordinates.reduce(0) { $0 + $1.y }
            let avgX = CGFloat(totalX) / CGFloat(targetPixelCoordinates.count)
            let avgY = CGFloat(totalY) / CGFloat(targetPixelCoordinates.count)
            
            // ✅ 안전한 나누기 (0으로 나누기 방지)
            let safeWidth = max(1, width - 1)
            let safeHeight = max(1, height - 1)
            targetCenterPoint = CGPoint(x: avgX / CGFloat(safeWidth), y: avgY / CGFloat(safeHeight))

            if let center = targetCenterPoint {
                 let distanceToCenter = sqrt(pow(center.x - 0.5, 2) + pow(center.y - 0.5, 2))
                 currentCenteredness = max(0.0, 1.0 - (distanceToCenter / 0.707))
            }
        }
        
        // ✅ 중앙 탐지 강화 로직 추가 (Stage 1→2 전환 감지용)
        let isCurrentlyInCenter = currentCenteredness > self.centerDetectionThreshold
        
        // ✅ 거리 측정을 위한 raycast는 별도 조건으로 실행 (더 관대한 조건)
        let shouldExecuteRaycast = currentCenteredness > 0.7 && targetCenterPoint != nil && validTargetClassID != nil
        
        // ✅ raycast 결과를 위한 변수
        var targetHitTransform: simd_float4x4? = nil
        var targetDistance: Float? = nil
        
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
             
             // ✅ 현재 프레임 탐지 결과 업데이트
             self.detectedObjectLabels = finalLabels
             self.detectedObjectCenteredness = currentCenteredness
             
             // ✅ 누적 객체 리스트 업데이트 (고유한 객체들만)
             let newObjects = Set(finalLabels)
             let previousCount = self.allDetectedObjects.count
             self.allDetectedObjects.formUnion(newObjects)
             let newCount = self.allDetectedObjects.count
             
             // Log only if significant new objects detected
             if newCount > previousCount && (newCount - previousCount) > 2 {
                 print("[AR] Added \(newCount - previousCount) new objects, total: \(newCount)")
             }
             
             // ✅ 중앙 탐지 진행률 업데이트 (Stage 1→2 전환 감지용)
             self.updateCenterDetectionProgress(isInCenter: isCurrentlyInCenter)
             
             // ✅ 거리 측정을 위한 raycast (Stage 1→2 전환과 별개)
             if shouldExecuteRaycast, let center = targetCenterPoint, let view = self.arView {
                 // ✅ 라이다 거리 측정은 별도 프로세스에서 처리되므로 여기서는 raycast만 실행
                 let viewPoint = CGPoint(x: center.x * view.bounds.width, y: center.y * view.bounds.height)
                 
                 if let result = self.performRaycast(from: viewPoint, in: view) {
                     targetDistance = simd_distance(cameraTransform.columns.3.xyz, result.worldTransform.columns.3.xyz)
                     targetHitTransform = result.worldTransform
                     // 로깅 제거 (성능 향상)
                 } else {
                     targetDistance = nil
                     targetHitTransform = nil
                 }
                 
                 // ✅ 라이다 거리가 이미 측정되었다면 라이다 우선 사용
                 if let lidarDistance = self.lidarBasedDistance {
                     targetDistance = lidarDistance
                     // 로깅 제거 (성능 향상)
                 }
                 
                 // ✅ 거리값 안정화 적용
                 if let distance = targetDistance {
                     self.updateStableDistance(distance)
                 } else {
                     // ✅ 거리값이 없어도 마지막 값 유지
                     if self.lastValidDistance != nil {
                         self.distanceToObject = self.lastValidDistance
                     }
                 }
                 self.raycastHitTransform = targetHitTransform
                 self.updateDebugSphere()
             } else {
                 if self.distanceToObject != nil || self.raycastHitTransform != nil {
                    // ✅ 타겟이 감지되지 않아도 마지막 거리값 유지
                    // self.distanceToObject = nil  // 거리값은 유지
                    self.raycastHitTransform = nil
                    self.updateDebugSphere()
                 }
             }
             
             
             // **스캔 모드 중일 때 추가 처리**
             if self.isScanningMode {
                 // 360도 스캔 진행률 업데이트 (임시로 객체 수 기반)
                 let progress = min(1.0, Float(self.allDetectedObjects.count) / 10.0)
                 self.scanProgress = progress
                 
                 // 타겟 객체 발견 여부 확인
                 if !self.foundTarget && finalLabels.contains(where: { 
                     $0.lowercased() == self.scanningTargetObject.lowercased() 
                 }) {
                     self.foundTarget = true
                 }
             }
             
             if validTargetClassID == nil && !targetObjectNameLowercased.isEmpty {
                 // 타겟 객체가 감지 가능한 리스트에 없음
             }
             
             // ✅ 햅틱 피드백도 메인 스레드에서 호출
             self.updateHapticFeedback(centeredness: currentCenteredness)
        }
    }

    // MARK: - Depth Anything Results Processing
    private func processDepthResults(for request: VNRequest, error: Error?) {
        guard error == nil else {
            print("ARViewModel: Error processing Depth Anything: \(error!.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.lastDepthMap = nil
                self?.depthMapPreviewImage = nil
            }
            return
        }

        if let results = request.results as? [VNPixelBufferObservation], let depthMap = results.first?.pixelBuffer {
            DispatchQueue.main.async { [weak self] in
                self?.lastDepthMap = depthMap
                self?.updateDepthMapPreviewImage()
            }
        } else {
            print("ARViewModel: Could not process depth map from Depth Anything results or unexpected format.")
            DispatchQueue.main.async { [weak self] in
                self?.lastDepthMap = nil
                self?.depthMapPreviewImage = nil
            }
        }
    }

    // MARK: - Depth Map Visualization
    private func updateDepthMapPreviewImage() {
        guard let depthPixelBuffer = self.lastDepthMap else {
            self.depthMapPreviewImage = nil
            return
        }
        
        // ✅ 딜레이 개선: 비동기 처리 제거하고 바로 메인 스레드에서 처리
        if let cgImage = self.createGrayscaleCGImageFromDepthBuffer(depthPixelBuffer) {
            // ✅ 원본 가로 방향 유지 (회전 제거)
            self.depthMapPreviewImage = Image(decorative: cgImage, scale: 1.0, orientation: .up)
        } else {
            self.depthMapPreviewImage = nil
        }
    }

    private func createGrayscaleCGImageFromDepthBuffer(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_OneComponent16Half ||
              pixelFormat == kCVPixelFormatType_DepthFloat32 || pixelFormat == kCVPixelFormatType_OneComponent32Float else {
            print("ARViewModel: Unsupported pixel format for depth map: \(pixelFormat.toString())")
            return nil
        }
        
        // ✅ 최소 크기 검증 추가
        guard width > 0 && height > 0 else {
            print("ARViewModel: Invalid depth buffer dimensions: \(width)x\(height)")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            print("ARViewModel: Failed to get base address from CVPixelBuffer for depth.")
            return nil
        }
        
        let expectedBytes = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
        guard expectedBytes > 0 else {
            print("ARViewModel: Invalid depth buffer byte size: \(expectedBytes)")
            return nil
        }
        
        var srcBuffer = vImage_Buffer(data: baseAddress,
                                      height: vImagePixelCount(height),
                                      width: vImagePixelCount(width),
                                      rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        
        var float32PlanarBuffer: vImage_Buffer
        var allocatedFloat32Data: UnsafeMutableRawPointer? = nil
        
        let dataSize = width * height * MemoryLayout<Float32>.size
        allocatedFloat32Data = malloc(dataSize)
        guard let validAllocatedData = allocatedFloat32Data else {
            print("ARViewModel: Failed to allocate memory for Float32 depth buffer.")
            return nil
        }
        float32PlanarBuffer = vImage_Buffer(data: validAllocatedData,
                                            height: vImagePixelCount(height),
                                            width: vImagePixelCount(width),
                                            rowBytes: width * MemoryLayout<Float32>.size)

        // ✅ vImage 변환 실패 시 안전하게 처리
        var conversionSuccess = false
        if pixelFormat == kCVPixelFormatType_DepthFloat16 || pixelFormat == kCVPixelFormatType_OneComponent16Half {
            let conversionError = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &float32PlanarBuffer, 0)
            if conversionError == kvImageNoError {
                conversionSuccess = true
            } else {
                print("ARViewModel: vImageConvert_Planar16FtoPlanarF error: \(conversionError)")
            }
        } else { // Float32 formats
            if srcBuffer.rowBytes == width * MemoryLayout<Float32>.size {
                 memcpy(float32PlanarBuffer.data, srcBuffer.data, dataSize)
                 conversionSuccess = true
             } else {
                 for y_coord in 0..<height {
                     let srcRow = srcBuffer.data!.advanced(by: y_coord * srcBuffer.rowBytes)
                     let dstRow = float32PlanarBuffer.data!.advanced(by: y_coord * float32PlanarBuffer.rowBytes)
                     memcpy(dstRow, srcRow, width * MemoryLayout<Float32>.size)
                 }
                 conversionSuccess = true
             }
        }
        
        guard conversionSuccess else {
            free(allocatedFloat32Data)
            print("ARViewModel: Failed to convert depth buffer to Float32")
            return nil
        }
        
        var minPixelVal: Float = 0.0
        var maxPixelVal: Float = 1.0
        
        // ✅ 완전히 안전한 포인터 접근
        guard let dataPtr = float32PlanarBuffer.data?.assumingMemoryBound(to: Float32.self) else {
            free(allocatedFloat32Data)
            print("ARViewModel: Failed to bind memory to Float32 pointer")
            return nil
        }
        
        let pixelCount = width * height
        guard pixelCount > 0 else {
            free(allocatedFloat32Data)
            print("ARViewModel: Zero pixel count")
            return nil
        }
        
        // ✅ 메모리 경계 검사를 통한 안전한 접근
        var validPixelFound = false
        for i in 0..<pixelCount {
            let pixelValue = dataPtr[i]
            if !pixelValue.isNaN && !pixelValue.isInfinite && pixelValue >= 0 {
                if !validPixelFound {
                    minPixelVal = pixelValue
                    maxPixelVal = pixelValue
                    validPixelFound = true
                } else {
                    if pixelValue < minPixelVal { minPixelVal = pixelValue }
                    if pixelValue > maxPixelVal { maxPixelVal = pixelValue }
                }
            }
        }
        
        if !validPixelFound {
            free(allocatedFloat32Data)
            print("ARViewModel: No valid depth pixels found")
            return nil
        }
        
        if maxPixelVal <= minPixelVal { maxPixelVal = minPixelVal + 1.0 }
        
        var destGrayscaleBuffer: vImage_Buffer
        let grayscaleDataSize = width * height * MemoryLayout<UInt8>.size
        guard let allocatedGrayscaleData = malloc(grayscaleDataSize) else {
            free(allocatedFloat32Data)
            print("ARViewModel: Failed to allocate memory for UInt8 depth buffer.")
            return nil
        }
        destGrayscaleBuffer = vImage_Buffer(data: allocatedGrayscaleData,
                                            height: vImagePixelCount(height),
                                            width: vImagePixelCount(width),
                                            rowBytes: width * MemoryLayout<UInt8>.size)

        let conversionErrorUInt8 = vImageConvert_PlanarFtoPlanar8(&float32PlanarBuffer, &destGrayscaleBuffer, minPixelVal, maxPixelVal, vImage_Flags(kvImageNoFlags))
        guard conversionErrorUInt8 == kvImageNoError else {
            print("ARViewModel: vImageConvert_PlanarFtoPlanar8 error: \(conversionErrorUInt8)")
            free(allocatedGrayscaleData)
            free(allocatedFloat32Data)
            return nil
        }

        // ✅ Float32 메모리 해제
        free(allocatedFloat32Data)

        guard let provider = CGDataProvider(dataInfo: allocatedGrayscaleData,
                                            data: destGrayscaleBuffer.data!,
                                            size: grayscaleDataSize,
                                            releaseData: { info, _, size in free(info) }) else {
            print("ARViewModel: Failed to create CGDataProvider for depth image.")
            free(allocatedGrayscaleData)
            return nil
        }

        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: destGrayscaleBuffer.rowBytes,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - LiDAR Raycasting
    private func performRaycast(from point: CGPoint, in view: ARView) -> ARRaycastResult? {
        guard view.window != nil else { return nil }
        return view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first
    }
    
    // ✅ 새로운 메서드: 라이다 기반 정확한 거리 측정 (최적화됨)
    private func processLidarDistanceMeasurementOptimized(sceneDepth: CVPixelBuffer?, cameraTransform: simd_float4x4) {
        // 타겟 객체가 중앙에 어느 정도 위치해야 거리 측정 시작
        guard detectedObjectCenteredness > 0.3 else {
            lidarBasedDistance = nil
            return
        }
        
        // ✅ sceneDepth 지원 여부 먼저 확인
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            // 라이다 미지원 기기에서는 raycast 사용
            fallbackToRaycastDistanceOptimized(cameraTransform: cameraTransform)
            return
        }
        
        // ✅ 전달받은 depth 데이터 활용
        guard let depthData = sceneDepth else {
            // print("ARViewModel: No sceneDepth data available, using raycast") // 로그 간소화
            fallbackToRaycastDistanceOptimized(cameraTransform: cameraTransform)
            return
        }
        
        // ✅ autoreleasepool로 메모리 즉시 해제
        autoreleasepool {
            // ✅ 화면 중심점에서의 depth 값 추출
            let depthWidth = CVPixelBufferGetWidth(depthData)
            let depthHeight = CVPixelBufferGetHeight(depthData)
            
            // 화면 중심점 계산
            let centerX = depthWidth / 2
            let centerY = depthHeight / 2
            
            // ✅ depth 데이터에서 실제 거리 값 추출
            if let actualDistance = extractDepthValue(from: depthData, at: CGPoint(x: centerX, y: centerY)) {
                DispatchQueue.main.async { [weak self] in
                    self?.lidarBasedDistance = actualDistance
                    // ✅ 거리값 안정화 적용
                    self?.updateStableDistance(actualDistance)
                    // 로깅 제거 (성능 향상)
                }
            } else {
                // 라이다 데이터 추출 실패 시 raycast 사용
                fallbackToRaycastDistanceOptimized(cameraTransform: cameraTransform)
            }
        }
    }
    
    // ✅ 라이다 실패 시 기존 raycast 방식으로 fallback (최적화됨)
    private func fallbackToRaycastDistanceOptimized(cameraTransform: simd_float4x4) {
        guard let arView = arView, 
              detectedObjectCenteredness > 0.7 else {
            return
        }
        
        // 화면 중심점에서 raycast 실행
        let centerPoint = CGPoint(x: arView.bounds.width / 2, y: arView.bounds.height / 2)
        
        if let result = performRaycast(from: centerPoint, in: arView) {
            let raycastDistance = simd_distance(cameraTransform.columns.3.xyz, result.worldTransform.columns.3.xyz)
            
            DispatchQueue.main.async { [weak self] in
                self?.lidarBasedDistance = raycastDistance
                // ✅ 거리값 안정화 적용
                self?.updateStableDistance(raycastDistance)
                // 로깅 제거 (성능 향상)
            }
        }
    }

    // MARK: - Debug Visualization
    private func updateDebugSphere() {
        guard let arView = arView else { return }

        // ✅ 예시 코드처럼 기존 구체를 확실히 제거
        if let oldSphere = self.debugSphere {
            // 기존 앵커 찾아서 제거
            let anchorsContainingOldSphere = arView.scene.anchors.filter { anchorEntity in
                anchorEntity.children.contains(oldSphere)
            }
            for anchor in anchorsContainingOldSphere {
                arView.scene.removeAnchor(anchor)
            }
            self.debugSphere = nil
        }

        // ✅ 새로운 유효한 hitTransform이 있으면 구체 생성 및 추가
        if let hitTransform = raycastHitTransform {
            // ✅ 예시 코드처럼 더 작은 반지름과 빨간색 사용
            let sphereMesh = MeshResource.generateSphere(radius: 0.01)
            let sphereMaterial = SimpleMaterial(color: .red, isMetallic: false)
            let sphereEntity = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
            
            let newAnchor = AnchorEntity(world: hitTransform)
            newAnchor.addChild(sphereEntity)
            arView.scene.addAnchor(newAnchor)
            self.debugSphere = sphereEntity
            
            // print("ARViewModel: Debug sphere created at target position")
        } else {
            // print("ARViewModel: Debug sphere removed (no valid hit transform)")
        }
    }

    // MARK: - Haptics
    private func setupHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
            hapticEngine?.playsHapticsOnly = true
            hapticEngine?.stoppedHandler = { reason in
                print("ARViewModel: Haptic engine stopped for reason: \(reason.rawValue)")
            }
            hapticEngine?.resetHandler = { [weak self] in
                print("ARViewModel: Haptic engine reset. Attempting to restart.")
                do {
                    try self?.hapticEngine?.start()
                } catch {
                    print("ARViewModel: Failed to restart haptic engine after reset: \(error)")
                    Task { @MainActor in
                        ErrorHandler.shared.handle(.audioEngineFailure, context: "Failed to restart haptic engine: \(error.localizedDescription)")
                    }
                }
            }
            print("ARViewModel: Haptic engine started.")
        } catch {
            print("ARViewModel: Error starting haptic engine: \(error.localizedDescription)")
            Task { @MainActor in
                ErrorHandler.shared.handle(.audioEngineFailure, context: "Failed to start haptic engine: \(error.localizedDescription)")
            }
        }
    }

    private func updateHapticFeedback(centeredness: CGFloat) {
        // ✅ 햅틱 가이드가 비활성화되어 있으면 바로 리턴
        guard isHapticGuideActive else { 
            return 
        }
        
        guard let engine = hapticEngine else { return }

        let now = Date()
        // ✅ 접근성을 위해 더 명확한 간격 (0.1초)
        if let lastTime = lastHapticTime, now.timeIntervalSince(lastTime) < 0.1 {
            return
        }

        // ✅ 전면 개선: 전체 강도 범위 활용 및 패턴 다양화
        do {
            var events: [CHHapticEvent] = []
            
            if centeredness > 0.9 {
                // 🎯 완벽한 중심 - 빠른 연속 탭 3회 (성공 신호)
                for i in 0..<3 {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    let event = CHHapticEvent(eventType: .hapticTransient, 
                                            parameters: [intensity, sharpness], 
                                            relativeTime: Double(i) * 0.1)
                    events.append(event)
                }
                hapticGuidanceDirection = "완벽한 중심!"
                
            } else if centeredness > 0.7 {
                // ✅ 좋은 방향 - 강한 연속 진동 (0.4초)
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: 0,
                    duration: 0.4)
                
                events = [event]
                hapticGuidanceDirection = "좋은 방향입니다"
                
            } else if centeredness > 0.5 {
                // 👍 조정 필요 - 중간 강도 Continuous (0.2초)
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0,
                    duration: 0.2)
                events = [event]
                hapticGuidanceDirection = "조금 더 조정하세요"
                
            } else if centeredness > 0.3 {
                // 📍 방향 전환 - 약한 펄스형 패턴 (0.1초 간격 2회)
                for i in 0..<2 {
                    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4)
                    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                    let event = CHHapticEvent(eventType: .hapticTransient, 
                                            parameters: [intensity, sharpness], 
                                            relativeTime: Double(i) * 0.15)
                    events.append(event)
                }
                hapticGuidanceDirection = "방향 조정이 필요해요"
                
            } else if centeredness > 0.1 {
                // 🔍 탐색 중 - 매우 약한 단일 탭
                let event = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                    ],
                    relativeTime: 0)
                events = [event]
                hapticGuidanceDirection = "물체를 찾았어요"
                
            } else {
                // ❌ 10% 미만 - 햅틱 없음 (배터리 절약)
                lastHapticTime = nil
                hapticGuidanceDirection = "천천히 둘러보세요"
                return
            }
            
            // 패턴 생성 및 재생
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            lastHapticTime = now
            
        } catch {
            print("❌ ARViewModel: Haptic error: \(error.localizedDescription)")
            if let chError = error as? CHHapticError {
                switch chError.code {
                case .engineNotRunning,
                     .resourceNotAvailable,
                     .notSupported,
                     .operationNotPermitted,
                     .invalidAudioSession:
                    setupHaptics()
                default:
                    setupHaptics()
                }
            } else {
                setupHaptics()
            }
        }
    }
    
    deinit {
        hapticEngine?.stop()
        hapticMonitoringTask?.cancel() // ✅ 햅틱 모니터링 작업 취소
        
        print("ARViewModel deinitialized, haptic engine stopped.")
    }

    // MARK: - Scanning Mode Control
    func startScanning(for objectName: String) {
        print("ARViewModel: Starting scan mode for: '\(objectName)'")
        isScanningMode = true
        scanningTargetObject = objectName
        scanProgress = 0.0
        foundTarget = false
        userTargetObjectName = objectName // Update the existing target property
        
        // **중요: 한국어 객체명인 경우 영어 매칭 필요성을 로그로 알림**
        let containsKorean = objectName.range(of: "[ㄱ-ㅎㅏ-ㅣ가-힣]", options: .regularExpression) != nil
        if containsKorean {
            print("ARViewModel: Warning - Korean object name '\(objectName)' detected. This should be translated to English via Gemini API first.")
        }
        
        // 감지 가능한 영어 객체명인지 확인
        let objectNameLower = objectName.lowercased()
        let canDetectDirectly = detrClassLabels.contains { $0.lowercased() == objectNameLower }
        if canDetectDirectly {
            print("ARViewModel: Object '\(objectName)' found in DETR class labels - direct detection possible")
        } else {
            print("ARViewModel: Object '\(objectName)' not in DETR class labels - Gemini API matching will be required")
        }
        
        // Start scanning progress simulation
        simulateScanProgress()
    }
    
    func stopScanning() {
        print("ARViewModel: Stopping scan mode")
        isScanningMode = false
        scanningTargetObject = ""
        scanProgress = 0.0
        foundTarget = false
    }
    
    private func simulateScanProgress() {
        guard isScanningMode else { return }
        
        // Simulate scanning progress over 5 seconds
        let progressIncrement: Float = 0.1 // 10% increments
        let intervalTime: TimeInterval = 0.5 // 500ms intervals
        
        DispatchQueue.main.asyncAfter(deadline: .now() + intervalTime) {
            guard self.isScanningMode else { return }
            
            self.scanProgress += progressIncrement
            
            // Check if we found the target object during scanning
            if !self.foundTarget && self.allDetectedObjects.contains(where: { 
                $0.lowercased().contains(self.scanningTargetObject.lowercased()) 
            }) {
                self.foundTarget = true
                print("ARViewModel: Target object '\(self.scanningTargetObject)' found during scan!")
            }
            
            if self.scanProgress < 1.0 {
                self.simulateScanProgress() // Continue scanning
            } else {
                // Scanning completed
                print("ARViewModel: Scan completed. Found target: \(self.foundTarget)")
                self.completeScan()
            }
        }
    }
    
    private func completeScan() {
        print("ARViewModel: Scan completion - Target found: \(foundTarget)")
        
        // Notify completion through delegate or callback mechanism
        // For now, we'll let AppState monitor the scanning completion
    }

    // MARK: - Haptic Guidance Control
    func startHapticGuidance(for objectName: String) {
        print("ARViewModel: Starting haptic guidance for: '\(objectName)'")
        isHapticGuideActive = true
        hapticGuidanceDirection = ""
        isTargetReached = false
        userTargetObjectName = objectName
        
        // Start haptic guidance monitoring
        startHapticGuidanceMonitor()
    }
    
    func stopHapticGuidance() {
        print("ARViewModel: Stopping haptic guidance")
        isHapticGuideActive = false
        hapticGuidanceDirection = ""
        isTargetReached = false
        
        // ✅ 중요: 스케줄된 햅틱 모니터링 작업 취소
        hapticMonitoringTask?.cancel()
        hapticMonitoringTask = nil
        
        // ✅ 추가: 햅틱 엔진 완전 중단
        hapticEngine?.stop()
        lastHapticTime = nil
        
        print("ARViewModel: ✅ Cancelled scheduled haptic monitoring tasks")
        print("ARViewModel: ✅ Stopped haptic engine completely")
    }
    
    private func startHapticGuidanceMonitor() {
        guard isHapticGuideActive else { return }
        
        // ✅ 기존 작업이 있으면 취소
        hapticMonitoringTask?.cancel()
        
        // ✅ 새로운 취소 가능한 작업 생성
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isHapticGuideActive else { 
                print("ARViewModel: Haptic monitoring cancelled or guide inactive")
                return 
            }
            
            let centeredness = self.detectedObjectCenteredness
            let distance = self.distanceToObject
            
            // ✅ 더 넓은 범위에서 세밀한 가이던스 제공
            if let actualDistance = distance, 
               centeredness > 0.85 && actualDistance < 0.5 {
                // ✅ 타겟 도달
                self.isTargetReached = true
                self.hapticGuidanceDirection = "🎯 목표 도달!"
                
                // ✅ 타겟 도달 성공 - 축하 패턴 (상승하는 강도 3연속)
                self.playSuccessHapticPattern()
                
                return
            } else if centeredness > 0.7 {
                // ✅ 매우 좋은 방향 - 직진
                self.hapticGuidanceDirection = "🚀 직진하세요!"
                self.isTargetReached = false
                
            } else if centeredness > 0.55 {
                // ✅ 좋은 방향 - 계속 진행
                self.hapticGuidanceDirection = "✅ 좋은 방향이에요"
                self.isTargetReached = false
                
            } else if centeredness > 0.4 {
                // ✅ 괜찮은 방향 - 조금 조정
                self.hapticGuidanceDirection = "📍 조금 더 조정하세요"
                self.isTargetReached = false
                
            } else if centeredness > 0.25 {
                // ✅ 물체가 보임 - 방향 조정
                self.hapticGuidanceDirection = "👀 물체가 화면에 있어요"
                self.isTargetReached = false
                
            } else if centeredness > 0.1 {
                // ✅ 물체 감지됨 - 더 큰 조정
                self.hapticGuidanceDirection = "🔍 물체를 감지했어요"
                self.isTargetReached = false
                
            } else {
                // ✅ 물체 없음 - 둘러보기
                self.hapticGuidanceDirection = "🔄 천천히 둘러보세요"
                self.isTargetReached = false
            }
            
            // ✅ 더 빠른 모니터링으로 반응성 향상
            self.startHapticGuidanceMonitor()
        }
        
        // ✅ 더 짧은 간격으로 즉각적인 피드백 (0.15초)
        hapticMonitoringTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    // MARK: - Special Haptic Patterns
    
    /// 성공 패턴 - 상승하는 강도의 3연속 햅틱
    func playSuccessHapticPattern() {
        guard let engine = hapticEngine else { return }
        
        do {
            var events: [CHHapticEvent] = []
            for i in 0..<3 {
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6 + (Float(i) * 0.2))
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5 + (Float(i) * 0.25))
                let event = CHHapticEvent(eventType: .hapticTransient, 
                                        parameters: [intensity, sharpness], 
                                        relativeTime: Double(i) * 0.15)
                events.append(event)
            }
            
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("❌ ARViewModel: Failed to play success haptic pattern")
        }
    }
    
    /// Stage 전환 패턴 - 상승 또는 하강
    func playStageTransitionHaptic(ascending: Bool) {
        guard let engine = hapticEngine else { return }
        
        do {
            var events: [CHHapticEvent] = []
            
            // Continuous 이벤트로 부드러운 전환 효과
            let startIntensity: Float = ascending ? 0.3 : 1.0
            let endIntensity: Float = ascending ? 1.0 : 0.3
            
            // 0.5초 동안 지속되는 continuous 이벤트
            let continuous = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: startIntensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0,
                duration: 0.5)
            
            // 강도 변화를 위한 parameter curve
            let intensityCurve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: startIntensity),
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0.5, value: endIntensity)
                ],
                relativeTime: 0)
            
            events = [continuous]
            
            let pattern = try CHHapticPattern(events: events, parameterCurves: [intensityCurve])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("❌ ARViewModel: Failed to play stage transition haptic")
        }
    }
    
    /// 객체 발견 패턴 - 심장박동 효과
    func playObjectFoundHaptic() {
        guard let engine = hapticEngine else { return }
        
        do {
            var events: [CHHapticEvent] = []
            
            // 첫 번째 박동 (강함)
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                ],
                relativeTime: 0))
            
            // 두 번째 박동 (약함)
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0.1))
            
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("❌ ARViewModel: Failed to play object found haptic")
        }
    }

    // MARK: - Center Detection Management
    private func updateCenterDetectionProgress(isInCenter: Bool) {
        if isInCenter {
            // ✅ 85% 중앙에 들어가면 바로 활성화 (1초 유지 조건 제거)
            centerDetectionProgress = 1.0
            if !isCenterDetectionActive {
                isCenterDetectionActive = true
                print("✅ ARViewModel: Center detection activated immediately! (85% threshold met)")
            }
        } else {
            // ✅ 중앙에서 벗어난 경우 - 리셋
            if isCenterDetectionActive {
                print("❌ ARViewModel: Center detection reset (moved away from center)")
                resetCenterDetection()
            }
        }
    }
    
    private func resetCenterDetection() {
        centerDetectionProgress = 0.0
        isCenterDetectionActive = false
    }
    
    // MARK: - Distance Stabilization
    private func updateStableDistance(_ newDistance: Float) {
        // ✅ 이상치 필터링 - 너무 극단적인 값 제거
        guard newDistance > 0.1 && newDistance < 20.0 else {
            print("❌ ARViewModel: Ignoring outlier distance: \(newDistance)m")
            return
        }
        
        // ✅ 최근 거리값 저장
        recentDistances.append(newDistance)
        if recentDistances.count > maxDistanceHistory {
            recentDistances.removeFirst()
        }
        
        // ✅ 이동 평균 계산
        let averageDistance = recentDistances.reduce(0, +) / Float(recentDistances.count)
        
        // ✅ 현재 거리와 평균의 차이가 크면 필터링
        if let currentDistance = distanceToObject {
            let difference = abs(averageDistance - currentDistance)
            let threshold: Float = 0.5 // 50cm 이상 차이나면 점진적 업데이트
            
            if difference > threshold {
                // 급격한 변화는 점진적으로 적용
                let smoothedDistance = currentDistance + (averageDistance - currentDistance) * 0.3
                distanceToObject = smoothedDistance
            } else {
                // 작은 변화는 그대로 적용
                distanceToObject = averageDistance
            }
        } else {
            // 첫 거리값
            distanceToObject = averageDistance
        }
        
        // ✅ 마지막 유효한 거리값 저장
        lastValidDistance = distanceToObject
    }

    // ✅ Depth 버퍼에서 특정 좌표의 깊이 값 추출
    private func extractDepthValue(from depthBuffer: CVPixelBuffer, at point: CGPoint) -> Float? {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        
        let x = Int(point.x)
        let y = Int(point.y)
        
        // 경계 검사 강화
        guard x >= 0 && x < width && y >= 0 && y < height else {
            return nil
        }
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        
        // ✅ 픽셀 포맷에 따른 depth 값 추출 (더 안전한 방식)
        switch pixelFormat {
        case kCVPixelFormatType_DepthFloat32:
            let bytesPerPixel = MemoryLayout<Float32>.size
            let expectedBytesPerRow = width * bytesPerPixel
            
            // 메모리 안전성 검사
            guard bytesPerRow >= expectedBytesPerRow else {
                print("❌ ARViewModel: Invalid bytesPerRow for Float32 depth")
                return nil
            }
            
            let rowData = baseAddress.advanced(by: y * bytesPerRow)
            let pixelData = rowData.assumingMemoryBound(to: Float32.self)
            let depthValue = pixelData[x]
            
            // 유효한 depth 값인지 확인 (더 엄격한 조건)
            guard !depthValue.isNaN && !depthValue.isInfinite && depthValue > 0.1 && depthValue < 10.0 else {
                return nil
            }
            return depthValue
            
        case kCVPixelFormatType_DepthFloat16:
            let bytesPerPixel = MemoryLayout<UInt16>.size // Float16은 UInt16으로 저장됨
            let expectedBytesPerRow = width * bytesPerPixel
            
            // 메모리 안전성 검사
            guard bytesPerRow >= expectedBytesPerRow else {
                print("❌ ARViewModel: Invalid bytesPerRow for Float16 depth")
                return nil
            }
            
            let rowData = baseAddress.advanced(by: y * bytesPerRow)
            let pixelData = rowData.assumingMemoryBound(to: UInt16.self)
            let rawValue = pixelData[x]
            
            // ✅ UInt16을 Float16으로 변환 후 Float으로 변환
            let float16Value = Float16(bitPattern: rawValue)
            let depthValue = Float(float16Value)
            
            // 유효한 depth 값인지 확인
            guard !depthValue.isNaN && !depthValue.isInfinite && depthValue > 0.1 && depthValue < 10.0 else {
                return nil
            }
            return depthValue
            
        default:
            print("❌ ARViewModel: Unsupported depth pixel format: \(pixelFormat.toString())")
            return nil
        }
    }
}

// Helper extensions
extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        return SIMD3<Float>(x, y, z)
    }
}

// ✅ UIImage rotation extension
extension UIImage {
    func rotated(by angle: CGFloat) -> UIImage? {
        let rotatedSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: angle))
            .integral.size
        
        UIGraphicsBeginImageContext(rotatedSize)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        let origin = CGPoint(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: angle)
        
        draw(in: CGRect(
            x: -origin.y,
            y: -origin.x,
            width: size.width,
            height: size.height
        ))
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
