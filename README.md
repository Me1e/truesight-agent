# TrueSight Agent

시각장애인을 위한 AI 기반 실시간 길찾기 도우미 iOS 앱

## 프로젝트 개요

TrueSight Agent는 AR, AI, 음성 인식 기술을 결합하여 시각장애인이 실내외 환경에서 원하는 물건을 찾고 목적지까지 안전하게 도달할 수 있도록 돕는 접근성 앱입니다.

### 주요 기능

- 🎯 **물체 인식 및 추적**: DETR 모델을 활용한 실시간 객체 탐지
- 🗣️ **한국어 음성 인식**: "노트북 찾아줘" 같은 자연스러운 명령 이해
- 🤖 **AI 음성 가이드**: Google Gemini Live API를 통한 실시간 음성 안내
- 📳 **햅틱 피드백**: 방향 안내를 위한 직관적인 진동 패턴
- 📏 **LiDAR 거리 측정**: iPhone의 LiDAR 센서로 정확한 거리 계산

## 시스템 요구사항

- iOS 18.4 이상
- LiDAR 센서가 탑재된 iPhone (iPhone 12 Pro 이상)
- Xcode 16.3 이상
- 안정적인 인터넷 연결

## 설치 방법

1. 저장소 클론

```bash
git clone https://github.com/yourusername/true-sight-agent.git
cd true-sight-agent
```

2. Xcode에서 프로젝트 열기

```bash
open gemini/gemini.xcodeproj
```

3. 개발 팀 설정

   - 프로젝트 설정에서 Signing & Capabilities 탭 선택
   - Team을 본인의 Apple Developer 계정으로 변경

4. 실제 기기에서 실행
   - LiDAR 센서가 있는 iPhone 연결
   - Scheme을 기기로 설정 후 Run

## 사용 방법

### 시나리오 1: 물건 찾기

1. **앱 실행**: 자동으로 5초간 주변 환경 스캔
2. **음성 안내**: "무엇을 찾으시나요?" 음성이 들리면
3. **음성 명령**: "노트북 찾아줘"라고 말하기
4. **햅틱 가이드**: 진동으로 방향 안내 받으며 이동
5. **음성 가이드**: "왼쪽으로 2미터 가세요" 같은 구체적 안내
6. **도착 알림**: 목적지 도달 시 AI가 먼저 인사

### 시나리오 2: 주변 환경 문의

목적지에 도착한 후 (Stage 3):

- "여기 의자가 몇 개 있어?"
- "테이블 위에 뭐가 있어?"
- "출구가 어디야?"

## 기술 스택

- **AR**: ARKit, RealityKit
- **AI**: Google Gemini Live API
- **ML**: Core ML (DETR, Depth Anything V2)
- **음성**: Speech Framework, AVFoundation
- **언어**: Swift, SwiftUI

## 아키텍처

### 3단계 네비게이션 시스템

1. **탐색 단계 (Stage 1)**: 5초간 환경 스캔 + 음성 인식으로 목표 설정
2. **안내 단계 (Stage 2)**: 실시간 AI 가이드 + 햅틱 피드백 (2초마다 환경 분석)
3. **대화 단계 (Stage 3)**: 목적지 도달 후 자유로운 상호작용 (1m 이내 + 2초간 안정적 위치 유지 시 전환)

### 핵심 컴포넌트

- `AppState`: 전체 앱 상태 및 단계 전환 관리
- `ARViewModel`: AR 세션 및 객체 탐지 처리
- `GeminiLiveAPIClient`: AI 서버와의 실시간 통신 (간소화된 오디오 아키텍처)
- `AudioSessionCoordinator`: 오디오 충돌 방지 관리
- `SpeechRecognitionManager`: 한국어 음성 인식 처리

### 기술적 특징

- **간소화된 오디오 처리**: 복잡한 버퍼 관리 제거, 즉시 재생 방식 채택
- **서버 기반 음성 중단**: Gemini의 VAD(Voice Activity Detection) 활용
- **끊김 없는 전환**: Stage 2에서 Google Search를 미리 활성화하여 Stage 3 전환 시 재연결 불필요

## 기여 방법

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다.

## 문의

프로젝트 관련 문의사항은 Issues 탭을 이용해주세요.

---

**Note**: 이 앱은 시각장애인의 독립적인 이동을 돕기 위해 개발되었습니다. 하지만 안전을 위해 항상 주의를 기울이며 사용해주시기 바랍니다.
