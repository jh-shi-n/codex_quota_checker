# Codex Quota Checker

**KOR** | [ENG](README.en.md)

- macOS 메뉴 막대·노치에서 최대 4개 Codex 계정의 할당량과 사용량 확인
- Codex로 제작한 비공식 독립 앱

## 주요 기능

| 기능 | 설명 |
|---|---|
| 할당량 확인 | 5시간·전체 할당량 잔여율, 초기화 시각과 남은 시간 표시 |
| 계정 관리 | 최대 4개 계정 연결, 이름·표시 여부·순서 설정 |
| 토큰 사용량 | 주간 막대·선그래프 또는 최근 24주 잔디, 서버 기준 누적·일 최대 토큰 표시 |
| 당일 사용량 보완 | 서버에 오늘 값이 있으면 우선 사용, 없으면 연결 계정의 로컬 기록으로 보완 |
| 집계 안내 | 토큰 사용량 제목 옆 `(i)`에 마우스를 올려 집계 기준·조회 상태 확인 |
| 세션 실행 기록 | 연결 계정의 최근 CLI 세션과 하위 에이전트 활동 표시 |
| 초기화 시간·알림 | 최소 요청 후 할당량 시간 고정 여부 확인, 초기화 사전·도달 및 일정 변경 알림 |
| 리셋권 | 잔여 개수·소멸일 확인 및 확인 창 승인 후 사용 |
| 서비스 상태·업데이트 | OpenAI 서비스 상태 확인, 앱 내 업데이트 설치·재실행 |

- 토큰 날짜는 UTC 기준; 이전 날짜는 서버 제공 내역 사용, 미제공 날짜는 0과 구분
- 로컬 보완은 연결 계정 폴더에 남아 있는 오늘 기록 범위로 제한
- 초기화 시간 확인 요청은 실제 사용량 발생 가능; 알림은 macOS 권한·시스템 설정에 따라 표시

## 요구 사항

- macOS 14 이상
- Codex CLI 설치 및 사용할 계정 로그인
- 제공 릴리스: Apple Silicon(arm64)용 앱 ZIP; Intel Mac은 소스 빌드 필요

## 설치

1. [최신 릴리스](https://github.com/jh-shi-n/codex_quota_checker/releases/latest)에서 앱 ZIP 다운로드
2. 압축 해제 후 `CodexQuotaChecker.app`을 `/Applications`로 이동하고 실행
3. 첫 실행이 차단되면 출처 확인 후 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 허용
4. 앱의 연결 가이드에서 로그인한 계정의 Codex 폴더 선택 후 연결 확인

- 계정 폴더: 해당 CLI의 `CODEX_HOME` 경로, 별도 설정이 없으면 `~/.codex`
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
- 날짜 표시 범위는 서버에서 제공하지 않는 과거 내역을 추가하지 않음

## 라이선스

- [MIT](LICENSE)
