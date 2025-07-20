# TrueSight Agent 실행 가이드

## 시스템 요구사항

- **macOS** (Xcode 실행용)
- **Xcode 16.3** 이상
- **LiDAR 센서 탑재 iPhone** (iPhone 12 Pro 이상)
- **iOS 18.4** 이상
- 인터넷 연결 필수

## 실행 단계

### 1. Gemini API 키 설정 (필수)

1. Google AI Studio에서 API 키 발급: https://aistudio.google.com/apikey
2. `gemini/GeminiLiveAPIClient.swift` 파일 열기
3. 14번째 줄 찾기:
   ```swift
   private let apiKey = "YOUR_API_KEY_HERE"
   ```
4. `YOUR_API_KEY_HERE`를 발급받은 API 키로 교체
   ```swift
   private let apiKey = "AIzaSyD...실제키값"
   ```

### 2. 프로젝트 빌드 및 실행

1. Xcode에서 프로젝트 열기:
   ```bash
   open gemini.xcodeproj
   ```

2. iPhone 연결 후 상단 디바이스 선택 메뉴에서 연결된 기기 선택

3. **Signing & Capabilities** 설정:
   - 프로젝트 네비게이터에서 `gemini` 선택
   - `Signing & Capabilities` 탭 클릭
   - Team을 개인 Apple ID로 변경

4. **Run** 버튼(▶️) 클릭 또는 `Cmd + R`

### 3. 앱 권한 허용

첫 실행 시 다음 권한 요청 모두 허용:
- 카메라 (AR 기능)
- 마이크 (음성 인식)
- 음성 인식

## 테스트 시나리오

### 기본 동작 테스트

1. **앱 시작**: "주변을 360도 돌면서 살펴보세요" 음성 안내
2. **5초 대기**: 자동으로 환경 스캔
3. **음성 명령**: "노트북 찾아줘" 또는 "의자 찾아줘"
4. **진동 피드백**: 물체 방향으로 안내 (왼쪽/오른쪽)
5. **도착**: 1m 이내 도달 시 AI가 먼저 인사

### 테스트 가능한 음성 명령

- "노트북 찾아줘"
- "의자 찾아줘"
- "사람 찾아줘"
- "컵 찾아줘"

## 주의사항

- LiDAR 센서가 없는 기기에서는 정상 작동하지 않음
- 실내 밝은 환경에서 테스트 권장
- 네트워크 연결 상태 확인 필수
- API 키가 올바르게 설정되지 않으면 AI 응답 불가

## 문제 해결

- **빌드 실패**: Xcode 재시작 후 Clean Build (`Cmd + Shift + K`)
- **권한 오류**: 설정 > 개인정보 보호에서 권한 확인
- **AI 응답 없음**: API 키 및 네트워크 연결 확인

## macOS 빌드 환경이 없는 경우

macOS 개발 환경이나 LiDAR 탑재 iPhone이 없으신 경우, 아래 이메일로 연락 주시면 라이브 데모를 시연해드리겠습니다.

**연락처**: mele0404@jbnu.ac.kr