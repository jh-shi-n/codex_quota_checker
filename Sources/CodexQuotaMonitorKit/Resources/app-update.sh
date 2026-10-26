#!/bin/zsh
# 목적: 기존 앱 종료 후 검증된 앱 교체·재실행 및 실패 시 원본 복원
# 이용처: 앱 내 업데이트 버튼의 별도 보조 프로세스
# 사용방법: OLD_PID TARGET_APP VERIFIED_APP WORKSPACE VERSION 인수 전달
set -euo pipefail
[[ $# == 5 ]] || exit 2
old_pid="$1"
target_app="$2"
verified_app="$3"
workspace="$4"
version="$5"
[[ "$old_pid" == <-> && "$old_pid" -gt 1 ]] || exit 2
[[ "$target_app" == /*/CodexQuotaChecker.app && -d "$target_app/Contents" ]] || exit 2
[[ "$verified_app" == "$workspace"/*/CodexQuotaChecker.app && -d "$verified_app/Contents" ]] || exit 2
[[ "$workspace" == /*/CodexQuotaChecker-update-* && -d "$workspace" ]] || exit 2
[[ "$version" == <->.<->.<-> ]] || exit 2
parent="${target_app:h}"
staging=""
backup=""
backup_owned=0
installed=0
success=0
new_pid=""

# 실패 시 신규 앱 종료·기존 번들 복원 및 임시 산출물 정리
cleanup() {
    if (( ! success && backup_owned )); then
        if [[ -n "$new_pid" ]]; then kill -TERM "$new_pid" 2>/dev/null || true; fi
        if (( installed )) && [[ -d "$target_app" ]]; then rm -rf -- "$target_app"; fi
        if mv -- "$backup" "$target_app"; then
            backup_owned=0
        else
            /usr/bin/logger -t CodexQuotaChecker "Update rollback failed; preserved app: $backup"
        fi
    fi
    if (( ! success && ! backup_owned )) && [[ -d "$target_app" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        /usr/bin/open "$target_app" || true
    fi
    if (( success && backup_owned )); then rm -rf -- "$backup"; fi
    if [[ -n "$staging" && -d "$staging" ]]; then rm -rf -- "$staging"; fi
    rm -rf -- "$workspace"
}
trap cleanup EXIT

# 기존 앱의 인스턴스 잠금과 실행 파일 해제까지 최대 45초 대기
for attempt in {1..450}; do
    kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
if kill -0 "$old_pid" 2>/dev/null; then exit 3; fi

staging="$(/usr/bin/mktemp -d "$parent/.CodexQuotaChecker.update.XXXXXX")"
candidate="$staging/CodexQuotaChecker.app"
/usr/bin/ditto "$verified_app" "$candidate"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$candidate/Contents/Info.plist")" == "com.example.codexquotamonitor" ]]
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$candidate/Contents/Info.plist")" == "$version" ]]
/usr/bin/codesign --verify --deep --strict "$candidate"
backup="$parent/.CodexQuotaChecker.backup.$$.app"
[[ ! -e "$backup" ]]
mv -- "$target_app" "$backup"
backup_owned=1
mv -- "$candidate" "$target_app"
installed=1
if ! /usr/bin/open "$target_app"; then exit 4; fi

# 실제 설치 경로의 신규 프로세스 실행과 최소 생존 여부 확인
executable="$target_app/Contents/MacOS/CodexQuotaMonitor"
for attempt in {1..100}; do
    new_pid="$(/bin/ps -axww -o pid=,args= | while read -r pid command_line; do
        if [[ "$command_line" == "$executable" || "$command_line" == "$executable "* ]]; then
            print -r -- "$pid"
            break
        fi
    done)"
    if [[ -n "$new_pid" ]]; then
        /bin/sleep 2
        if kill -0 "$new_pid" 2>/dev/null; then success=1; break; fi
        new_pid=""
    fi
    /bin/sleep 0.1
done
if (( ! success )); then exit 5; fi
