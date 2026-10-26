#!/bin/zsh
# 목적: 기존 앱 종료 후 교체·준비 신호 확인 및 실패 시 원본 복원
# 이용처: 앱 내 업데이트의 독립 설치 helper
# 사용방법: OLD_PID TARGET_APP VERIFIED_APP WORKSPACE VERSION STATE_DIRECTORY NONCE 인수 전달
set -euo pipefail
umask 077
[[ $# == 7 ]] || exit 2
old_pid="$1"
target_app="$2"
verified_app="$3"
workspace="$4"
version="$5"
state_directory="$6"
nonce="$7"
[[ "$old_pid" == <-> && "$old_pid" -gt 1 ]] || exit 2
[[ "$target_app" == /*/CodexQuotaChecker.app && -d "$target_app/Contents" ]] || exit 2
[[ "$verified_app" == "$workspace"/*/CodexQuotaChecker.app && -d "$verified_app/Contents" ]] || exit 2
[[ "$workspace" == /*/CodexQuotaChecker-update-* && -d "$workspace" ]] || exit 2
[[ "$version" == <->.<->.<-> && "$state_directory" == /* && -d "$state_directory" ]] || exit 2
[[ ${#nonce} == 36 && "$nonce" != *[^0-9A-Fa-f-]* ]] || exit 2
[[ "$(/usr/bin/plutil -extract nonce raw "$state_directory/pending.json")" == "$nonce" ]] || exit 2
chmod 700 "$state_directory"
parent="${target_app:h}"
executable="$target_app/Contents/MacOS/CodexQuotaMonitor"
ready="$state_directory/ready-$nonce.json"
staging=""
backup=""
backup_owned=0
installed=0
success=0
new_pid=""

# 실제 설치 경로를 실행하는 신규 PID 조회
find_new_pid() {
    /bin/ps -axww -o pid=,comm= | while read -r pid command_path; do
        if [[ "$command_path" == "$executable" ]]; then print -r -- "$pid"; break; fi
    done
}

# 실패 결과를 보존하고 신규 앱 종료·원본 복원·임시 산출물 정리
cleanup() {
    local exit_code=$?
    set +e
    if (( ! success && installed )); then
        [[ -n "$new_pid" ]] || new_pid="$(find_new_pid)"
        if [[ "$new_pid" == <-> && "$(/bin/ps -p "$new_pid" -ww -o comm=)" == "$executable" ]]; then
            kill -TERM "$new_pid" 2>/dev/null
            /bin/sleep 0.25
            if [[ "$(/bin/ps -p "$new_pid" -ww -o comm=)" == "$executable" ]]; then kill -KILL "$new_pid" 2>/dev/null; fi
        fi
    fi
    if (( ! success && backup_owned )); then
        if (( installed )) && [[ -d "$target_app" ]]; then rm -rf -- "$target_app"; fi
        if mv -- "$backup" "$target_app"; then
            backup_owned=0
        else
            exit_code=6
            /usr/bin/logger -t CodexQuotaChecker "Update rollback failed; preserved app: $backup"
        fi
    fi
    local outcome="failed"
    (( success )) && outcome="success"
    print -r -- "{\"status\":\"$outcome\",\"version\":\"$version\",\"code\":$exit_code}" > "$state_directory/.result.$$.json"
    chmod 600 "$state_directory/.result.$$.json"
    mv -f -- "$state_directory/.result.$$.json" "$state_directory/result.json"
    rm -f -- "$ready"
    if [[ "$(/usr/bin/plutil -extract nonce raw "$state_directory/pending.json" 2>/dev/null)" == "$nonce" ]]; then
        rm -f -- "$state_directory/pending.json"
    fi
    if (( success && backup_owned )); then rm -rf -- "$backup"; fi
    if [[ -n "$staging" && -d "$staging" ]]; then rm -rf -- "$staging"; fi
    rm -rf -- "$workspace"
    if (( ! success && ! backup_owned )) && [[ -d "$target_app" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        /usr/bin/open "$target_app" || true
    fi
    return "$exit_code"
}
trap cleanup EXIT

# 복사·서명 도구의 실제 실행시간 제한
run_bounded() {
    local attempts="$1"
    shift
    "$@" &
    local command_pid=$!
    for (( attempt=0; attempt<attempts; attempt++ )); do
        if ! kill -0 "$command_pid" 2>/dev/null; then wait "$command_pid"; return $?; fi
        /bin/sleep 0.1
    done
    kill -TERM "$command_pid" 2>/dev/null || true
    /bin/sleep 0.25
    kill -KILL "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
    return 7
}

# 기존 앱의 인스턴스 잠금·실행 파일 해제까지 최대 45초 대기
for attempt in {1..450}; do
    kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
if kill -0 "$old_pid" 2>/dev/null; then exit 3; fi

staging="$(/usr/bin/mktemp -d "$parent/.CodexQuotaChecker.update.XXXXXX")"
candidate="$staging/CodexQuotaChecker.app"
run_bounded 300 /usr/bin/ditto "$verified_app" "$candidate"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$candidate/Contents/Info.plist")" == "com.example.codexquotamonitor" ]]
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$candidate/Contents/Info.plist")" == "$version" ]]
run_bounded 150 /usr/bin/codesign --verify --deep --strict "$candidate"
backup="$parent/.CodexQuotaChecker.backup.$$.app"
[[ ! -e "$backup" ]]
mv -- "$target_app" "$backup"
backup_owned=1
mv -- "$candidate" "$target_app"
installed=1
if ! /usr/bin/open -n "$target_app" --args --codex-update-nonce "$nonce"; then exit 4; fi

# 초기화 완료 신호의 버전·PID·설치 경로·실행 경로·nonce 일치 후에만 백업 제거
for attempt in {1..300}; do
    new_pid="$(find_new_pid)"
    if [[ "$new_pid" == <-> && -f "$ready" ]] &&
       [[ "$(/usr/bin/plutil -extract nonce raw "$ready" 2>/dev/null)" == "$nonce" ]] &&
       [[ "$(/usr/bin/plutil -extract version raw "$ready" 2>/dev/null)" == "$version" ]] &&
       [[ "$(/usr/bin/plutil -extract target raw "$ready" 2>/dev/null)" == "$target_app" ]] &&
       [[ "$(/usr/bin/plutil -extract executable raw "$ready" 2>/dev/null)" == "$executable" ]] &&
       [[ "$(/usr/bin/plutil -extract pid raw "$ready" 2>/dev/null)" == "$new_pid" ]] &&
       [[ "$(/bin/ps -p "$new_pid" -ww -o comm=)" == "$executable" ]] && kill -0 "$new_pid" 2>/dev/null; then
        success=1
        break
    fi
    /bin/sleep 0.1
done
if (( ! success )); then exit 5; fi
