# Codex Quota Checker

> [26.10.31] Codex·Claude의 다계정 이용 관련 규정에 따라, 한 기기에서 동일한 서비스에 여러 계정을 연결하는 것을 권장하지 않습니다.

**KOR** | [ENG](README.en.md)

- Codex·Claude 계정을 구분 없이 조합해 총 최대 4개 연결 지원 (예: Codex 2개 + Claude 2개)
- macOS 메뉴 막대·노치에서 연결 계정의 할당량, 세션 실행 기록, 토큰 사용량 확인
- Codex/Claude로 제작한 비공식 독립 앱

## 화면 미리보기

- 현재 구현된 UI에 예시 계정·사용량을 넣어 캡처한 화면

### 메뉴 막대·노치 계정 표시

<img src="assets/screenshots/quota-cluster.png" alt="두 계정의 할당량 잔여율과 이름을 표시하는 계정 도넛" width="220">

### 계정 상세

- 5시간·전체 할당량, 최근 24주 토큰 사용량, 세션 실행 기록 및 초기화 시간 설정

<img src="assets/screenshots/account-detail.png" alt="계정별 할당량과 토큰 사용량 잔디를 표시하는 상세 화면" width="640">

### 설정

<img src="assets/screenshots/settings.png" alt="자동 새로고침 간격과 계정 연결 경로를 설정하는 화면" width="640">

## 주요 기능

| 기능 | 설명 |
|---|---|
| 할당량 확인 | 5시간·전체 할당량 잔여율, 초기화 시각과 남은 시간 표시 |
| 계정 관리 | Codex·Claude 혼합 또는 한 종류만 총 최대 4개 연결, 이름·표시 여부·순서 설정 |
| 토큰 사용량 | 주간 막대·선그래프 또는 최근 24주 잔디, Codex는 서버 기준 누적·일 최대 토큰, Claude는 로컬 기록 합계·일 최대 토큰 표시 |
| Codex 당일 사용량 보완 | 당일 서버 값 우선 사용, 0이거나 미제공이면 연결 계정의 로컬 기록으로 보완 |
| 토큰 숫자 단위 | 1만 미만은 정수, 이후 만·백만·천만·억 단위로 소수 최대 한 자리 표시; 반올림 경계에서 다음 단위 적용 |
| 집계 안내 | 토큰 사용량 제목 옆 `(i)`에 마우스를 올려 집계 기준·조회 상태 확인 |
| 세션 실행 기록 | 연결 계정의 최근 CLI 세션과 하위 에이전트 활동 표시 |
| 초기화 시간·알림 | 최소 요청 후 할당량 시간 고정 여부 확인, 초기화 사전·도달 및 일정 변경 알림 |
| 리셋권 | 잔여 개수·소멸일 확인 및 확인 창 승인 후 사용 |
| 알림 권한·테스트 | 알림 탭 최상단에 설정 경로·권한 상태, 테스트 요청 전송 시각 또는 실패 원인 표시 |
| 서비스 상태·업데이트 | OpenAI 서비스 상태 확인, 앱 내 업데이트 설치·재실행, 현재·최신 버전과 빌드 번호 표시 |

- 4개는 Codex·Claude 합산 한도이며, 제공자별 4개씩 연결하는 방식은 미지원
- 토큰 날짜는 UTC 기준이며 미제공 날짜는 0과 구분
- Codex: 이전 날짜는 서버 제공 내역 사용, 로컬 보완은 연결 계정 폴더의 당일 기록 범위로 제한
- Claude: 연결 폴더의 Stats 캐시·세션 기록으로 최근 12개월 집계, 웹·다른 기기 및 계정 전체 서버 통계 제외; 같은 폴더에서 계정 변경 시 이전 계정 기록 포함 가능
- 초기화 시간 확인 요청은 실제 사용량 발생 가능; 알림은 macOS 권한·시스템 설정에 따라 표시
- 알림 권한 확인 경로: **설정 → 알림 → 응용프로그램 알림**; 테스트 기록은 앱 실행 중 유지되며 전송 성공이 알림 배너 표시를 보장하지는 않음

## 요구 사항

- macOS 14 이상
- 연결할 제공자의 CLI 설치 및 계정 로그인: Codex CLI 또는 Claude Code CLI (혼합 연결 시 둘 다 필요)
- 제공 릴리스: Apple Silicon(arm64)용 앱 ZIP; Intel Mac은 소스 빌드 필요

## 설치

1. [최신 릴리스](https://github.com/jh-shi-n/codex_quota_checker/releases/latest)에서 앱 ZIP 다운로드
2. 압축 해제 후 `CodexQuotaChecker.app`을 `/Applications`로 이동하고 실행
3. 첫 실행이 차단되면 출처 확인 후 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 허용
4. 앱의 연결 가이드에서 로그인한 Codex 또는 Claude 계정 폴더 선택 후 연결 확인

- Codex 계정 폴더: `CODEX_HOME` 경로, 별도 설정이 없으면 `~/.codex`
- Claude 계정 폴더: `CLAUDE_CONFIG_DIR` 경로, 별도 설정이 없으면 `~/.claude`
- 임시 서명(ad-hoc) 적용, Developer ID 서명·공증 미적용; 첫 실행 허용은 [Apple 안내](https://support.apple.com/ko-kr/102445) 참고
- 이후 업데이트: **앱 설정 → 앱 업데이트 → 업데이트 확인 → 업데이트 설치 후 재실행**

### 소스 빌드

- Swift tools 6.0 지원 도구 체인과 macOS SDK 필요
- 패키징 스크립트에서 실행 파일·아이콘·리소스 포함 및 임시 서명 적용

```bash
git clone https://github.com/jh-shi-n/codex_quota_checker.git
cd codex_quota_checker
scripts/package_app.sh --output "$PWD/dist" --configuration release
open "$PWD/dist/CodexQuotaChecker.app"
```

## 사용 방법

- 계정 도넛 클릭: 할당량·토큰 사용량·세션 실행 기록 표시
- 도넛 중앙 숫자: 5시간 잔여율, 외곽 링: 전체 할당량 잔여율
- 상세 화면 진입 시 토큰 사용량 조회; 우상단 새로고침으로 즉시 갱신
- 설정에서 계정 표시·자동 새로고침·차트 방식·날짜 표시 범위·알림·로그인 시 자동 실행 지정
- 날짜 표시 범위를 늘려도 Codex 서버에서 미제공하거나 Claude 연결 폴더에 없는 과거 내역은 추가되지 않음

## 라이선스

- [MIT](LICENSE)
