#!/bin/zsh
# 목적: 종료 후 앱 교체·재실행 재시도·실패 복원 및 오류코드 알림
# 이용처: 앱 내 업데이트의 독립 설치 helper
# 사용방법: OLD_PID TARGET_APP VERIFIED_APP WORKSPACE VERSION STATE_DIRECTORY NONCE
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
stage_code=2
launch_exit=0
recovery="unchanged"

# 경로가 정확히 일치하는 실행 중 앱 조회
find_new_pid() {
    /bin/ps -axww -o pid=,comm= | while read -r pid command_path; do
        if [[ "$command_path" == "$executable" ]]; then print -r -- "$pid"; break; fi
    done
}

# 실제 실행시간 상한을 갖는 외부 명령
run_bounded() {
    local attempts="$1"
    shift
    local result_file="$(/usr/bin/mktemp "$state_directory/.command.XXXXXX")"
    (
        local command_exit=0
        "$@" || command_exit=$?
        print -r -- "$command_exit" > "$result_file"
        exit "$command_exit"
    ) &
    local command_pid=$!
    for (( attempt=0; attempt<attempts; attempt++ )); do
        if [[ -s "$result_file" ]]; then
            local command_exit="$(<"$result_file")"
            wait "$command_pid" 2>/dev/null || true
            rm -f -- "$result_file"
            [[ "$command_exit" == <-> ]] || return 7
            return "$command_exit"
        fi
        /bin/sleep 0.1
    done
    /usr/bin/pkill -TERM -P "$command_pid" 2>/dev/null || true
    kill -TERM "$command_pid" 2>/dev/null || true
    /bin/sleep 0.25
    /usr/bin/pkill -KILL -P "$command_pid" 2>/dev/null || true
    kill -KILL "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
    rm -f -- "$result_file"
    return 7
}

# 신규 앱 초기화 신호의 설치 요청·실행 경로·실제 PID 일치 확인
is_ready() {
    [[ "$new_pid" == <-> && -f "$ready" ]] &&
    [[ "$(/usr/bin/plutil -extract nonce raw "$ready" 2>/dev/null)" == "$nonce" ]] &&
    [[ "$(/usr/bin/plutil -extract version raw "$ready" 2>/dev/null)" == "$version" ]] &&
    [[ "$(/usr/bin/plutil -extract target raw "$ready" 2>/dev/null)" == "$target_app" ]] &&
    [[ "$(/usr/bin/plutil -extract executable raw "$ready" 2>/dev/null)" == "$executable" ]] &&
    [[ "$(/usr/bin/plutil -extract pid raw "$ready" 2>/dev/null)" == "$new_pid" ]] &&
    [[ "$(/bin/ps -p "$new_pid" -ww -o comm=)" == "$executable" ]] && kill -0 "$new_pid" 2>/dev/null
}

# 실행 요청을 최대 3회 재시도하고 중복 실행 없이 프로세스·준비 상태 확인
launch_app() {
    local mode="$1"
    local accepted=0
    for launch_attempt in {1..3}; do
        new_pid="$(find_new_pid)"
        if (( launch_attempt == 1 )) || [[ "$new_pid" != <-> ]]; then
            local -a arguments=(-n "$target_app")
            [[ "$mode" != "updated" ]] || arguments+=(--args --codex-update-nonce "$nonce")
            launch_exit=0
            run_bounded 100 /usr/bin/open "${arguments[@]}" || launch_exit=$?
            print -r -- "launch mode=$mode attempt=$launch_attempt exit=$launch_exit"
            (( launch_exit != 0 )) || accepted=1
        fi
        for launch_wait in {1..20}; do
            new_pid="$(find_new_pid)"
            if [[ "$new_pid" == <-> ]] && kill -0 "$new_pid" 2>/dev/null; then
                if [[ "$mode" == "restored" ]]; then
                    /bin/sleep 0.5
                    if [[ "$(/bin/ps -p "$new_pid" -ww -o comm=)" == "$executable" ]] && kill -0 "$new_pid" 2>/dev/null; then return 0; fi
                else
                    for ready_wait in {1..300}; do
                        if is_ready; then return 0; fi
                        kill -0 "$new_pid" 2>/dev/null || break
                        /bin/sleep 0.1
                    done
                    if kill -0 "$new_pid" 2>/dev/null; then return 5; fi
                fi
                break
            fi
            /bin/sleep 0.1
        done
        /bin/sleep 0.5
    done
    if [[ "$mode" == "restored" ]]; then
        (( accepted )) && return 13
        return 12
    fi
    (( accepted )) && return 5
    return 4
}

# 앱이 실행되지 않아도 외부 시스템 대화상자로 실패·원인·복구 코드 전달
notify_failure() {
    local code="$1"
    local cause="$2"
    local message="오류코드: UPD-${(l:3::0:)code}"
    message+=$'\n'"발생 식별자: $nonce"
    [[ "$code" == "$cause" ]] || message+=$'\n'"최초 오류코드: UPD-${(l:3::0:)cause}"
    case "$recovery" in
        restored) message+=$'\n구버전 앱을 복원했습니다. 업데이트를 다시 시도해 주세요.' ;;
        backupPreserved) message+=$'\n앱 복원에 실패했습니다. 원본 백업은 보존했습니다.' ;;
        launchFailed) message+=$'\n구버전 파일은 보존했지만 앱을 다시 실행하지 못했습니다.' ;;
        *) message+=$'\n업데이트를 완료하지 못했습니다. 다시 시도해 주세요.' ;;
    esac
    if (( launch_exit != 0 )); then message+=$'\n'"실행 명령 종료코드: $launch_exit"; fi
    local diagnostics="$(/usr/bin/grep -E '^launch mode=(updated|restored) attempt=[1-3] exit=[0-9]+$' "$state_directory/attempt-$nonce.log" 2>/dev/null | /usr/bin/tail -n 6)"
    [[ -n "$diagnostics" ]] || diagnostics="관련 진단 없음"
    local report="Codex Quota Checker 업데이트 오류 정보"$'\n'"요청 버전: $version"$'\n'"$message"$'\n\n'"해당 설치 시도 진단:"$'\n'"$diagnostics"
    (
        for notification_wait in {1..50}; do
            [[ ! -f "$state_directory/result.json" ]] || break
            /bin/sleep 0.1
        done
        local delivery_exit=0
        /usr/bin/osascript -e 'on run argv' -e 'set result to display alert "업데이트 실패했습니다" message (item 1 of argv) as critical buttons {"오류 정보 복사", "확인"} default button "확인"' -e 'if button returned of result is "오류 정보 복사" then set the clipboard to (item 2 of argv)' -e 'end run' "$message" "$report" >/dev/null 2>&1 || delivery_exit=$?
        print -r -- "$delivery_exit" > "$state_directory/.notification-$nonce.tmp"
        chmod 600 "$state_directory/.notification-$nonce.tmp"
        mv -f -- "$state_directory/.notification-$nonce.tmp" "$state_directory/notification-$nonce.done"
    ) &
    print -r -- "$!" > "$state_directory/notification-$nonce.pid"
}

# 현재 복원 프로세스가 앱 자체 오류 대화상자 처리를 등록했는지 확인
has_app_observer() {
    local observer="$state_directory/observer-$nonce.json"
    [[ "$new_pid" == <-> && -f "$observer" ]] && kill -0 "$new_pid" 2>/dev/null &&
    [[ "$(/usr/bin/plutil -extract nonce raw "$observer" 2>/dev/null)" == "$nonce" ]] &&
    [[ "$(/usr/bin/plutil -extract pid raw "$observer" 2>/dev/null)" == "$new_pid" ]] &&
    [[ "$(/usr/bin/plutil -extract executable raw "$observer" 2>/dev/null)" == "$executable" ]]
}

# 실패 단계 보존·원본 복원·복원 앱 실행 검증·사용자 알림 및 결과 기록
cleanup() {
    local original_exit=$?
    trap - EXIT
    set +e
    local code=0
    if (( ! success )); then
        code=$stage_code
        (( original_exit != 7 )) || code=7
    fi
    local cause=$code
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
            recovery="restored"
        else
            code=6
            recovery="backupPreserved"
            /usr/bin/logger -t CodexQuotaChecker "UPD-006: preserved app backup at $backup"
        fi
    fi
    if (( ! success && ! backup_owned )) && [[ -d "$target_app" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        if launch_app restored; then
            recovery="restored"
        else
            code=$?
            recovery="launchFailed"
        fi
    fi
    if (( success && backup_owned )); then rm -rf -- "$backup"; fi
    if [[ -n "$staging" && -d "$staging" ]]; then rm -rf -- "$staging"; fi
    rm -rf -- "$workspace"
    local outcome="failed"
    (( ! success )) || outcome="success"
    local notification_requested=false
    if (( ! success )) && ! has_app_observer; then
        notification_requested=true
        notify_failure "$code" "$cause"
    fi
    print -r -- "{\"status\":\"$outcome\",\"version\":\"$version\",\"code\":$code,\"occurrenceID\":\"$nonce\",\"causeCode\":$cause,\"recovery\":\"$recovery\",\"notificationRequested\":$notification_requested}" > "$state_directory/.result.$$.json"
    chmod 600 "$state_directory/.result.$$.json"
    mv -f -- "$state_directory/.result.$$.json" "$state_directory/result.json"
    rm -f -- "$ready" "$state_directory/helper-$nonce.ready" "$state_directory/observer-$nonce.json"
    if [[ "$(/usr/bin/plutil -extract nonce raw "$state_directory/pending.json" 2>/dev/null)" == "$nonce" ]]; then rm -f -- "$state_directory/pending.json"; fi
    exit "$code"
}
trap cleanup EXIT
print -r -- "$nonce" > "$state_directory/helper-$nonce.ready"

# 기존 앱의 실행 파일·잠금 해제까지 최대 45초 대기
stage_code=3
for attempt in {1..450}; do
    kill -0 "$old_pid" 2>/dev/null || break
    /bin/sleep 0.1
done
if kill -0 "$old_pid" 2>/dev/null; then exit 3; fi
stage_code=8
staging="$(/usr/bin/mktemp -d "$parent/.CodexQuotaChecker.update.XXXXXX")"
candidate="$staging/CodexQuotaChecker.app"
run_bounded 300 /usr/bin/ditto "$verified_app" "$candidate"
stage_code=9
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$candidate/Contents/Info.plist")" == "com.example.codexquotamonitor" ]]
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$candidate/Contents/Info.plist")" == "$version" ]]
run_bounded 150 /usr/bin/codesign --verify --deep --strict "$candidate"
stage_code=10
backup="$parent/.CodexQuotaChecker.backup.$$.app"
[[ ! -e "$backup" ]]
mv -- "$target_app" "$backup"
backup_owned=1
stage_code=11
mv -- "$candidate" "$target_app"
installed=1
stage_code=4
if launch_app updated; then success=1; else stage_code=$?; exit "$stage_code"; fi
