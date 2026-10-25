#!/bin/zsh
# 목적: 빌드 진행 표시와 서명된 macOS 앱 패키징·교체
# 이용처: 로컬 설치 및 릴리스 배포본 생성
# 사용방법: --output으로 앱 번들 또는 출력 폴더 지정
# 실행 예시: ./scripts/package_app.sh --output /Applications/CodexQuotaChecker.app
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
configuration="release"
output_path=""
stage_dir=""
stage_owned=0
backup_app=""
backup_owned=0
spinner_pid=""

# 패키징 인수와 기본 사용법 출력
usage() {
    print "Usage: $0 --output DESTINATION [--configuration release|debug]"
}

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || { print -u2 "--output requires a path"; exit 2; }
            output_path="$2"
            shift 2
            ;;
        --configuration)
            (( $# >= 2 )) || { print -u2 "--configuration requires a value"; exit 2; }
            configuration="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$output_path" ]] || { print -u2 "--output is required"; usage >&2; exit 2; }
[[ "$configuration" == "release" || "$configuration" == "debug" ]] || {
    print -u2 "Unsupported configuration: $configuration"
    exit 2
}

if [[ "$output_path" == *.app ]]; then
    target_app="${output_path:A}"
    destination_dir="${target_app:h}"
    explicit_app_target=1
else
    destination_dir="${output_path:A}"
    target_app="$destination_dir/CodexQuotaChecker.app"
    explicit_app_target=0
fi

[[ "${target_app:t}" == "CodexQuotaChecker.app" ]] || {
    print -u2 "Destination must be named CodexQuotaChecker.app: $target_app"
    exit 2
}

mkdir -p "$destination_dir"
if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" && -d "$target_app/Contents" ]] || {
        print -u2 "Existing destination is not an app bundle directory: $target_app"
        exit 2
    }
    if [[ "$explicit_app_target" != 1 ]]; then
        print -u2 "Refusing to replace an existing app unless --output names that exact .app bundle: $target_app"
        exit 2
    fi
fi

# 스피너 종료와 터미널의 진행 표시 줄 정리
stop_build_progress() {
    [[ -n "$spinner_pid" ]] || return 0
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    spinner_pid=""
    printf '\r\033[2K' >&2
}

# 실패한 교체 작업의 기존 앱 복원
restore_backup() {
    (( backup_owned )) || return 0
    if [[ -z "$backup_app" || ! -d "$backup_app" ]]; then
        print -u2 "Rollback cannot find preserved app bundle: ${backup_app:-<unset>}"
        return 1
    fi
    if [[ -e "$target_app" ]]; then
        print -u2 "Rollback will not overwrite an existing target: $target_app"
        return 1
    fi
    if mv -- "$backup_app" "$target_app"; then
        backup_owned=0
        return 0
    fi
    print -u2 "Rollback failed; preserved old app bundle at: $backup_app"
    return 1
}

# 빌드 표시·임시 스테이징 정리 및 보존 앱 복원
cleanup() {
    stop_build_progress
    if (( stage_owned )) && [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir"
    fi
    if (( backup_owned )); then
        restore_backup || print -u2 "Old app bundle remains preserved at: $backup_app"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 터미널에서 스피너·경과 시간 표시 및 원본 빌드 로그·종료 코드 유지
build_app() {
    if [[ ! -t 1 || ! -t 2 || "${TERM:-dumb}" == "dumb" ]]; then
        (cd "$package_root" && swift build -c "$configuration" --product CodexQuotaMonitor)
        return
    fi

    local build_started=$SECONDS
    local build_result=0
    (
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local frame_index=1
        while true; do
            printf '\r\033[2K%s Building app… %ds' "$frames[$frame_index]" "$(( SECONDS - build_started ))" >&2
            frame_index=$(( frame_index % ${#frames} + 1 ))
            sleep 0.1
        done
    ) &
    spinner_pid=$!

    if (cd "$package_root" && swift build -c "$configuration" --product CodexQuotaMonitor 2>&1) |
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '\r\033[2K%s\n' "$line"
        done
    then
        build_result=0
    else
        build_result=$?
    fi
    stop_build_progress
    if (( build_result == 0 )); then
        print "✓ Build complete ($(( SECONDS - build_started ))s)"
    else
        print -u2 "✗ Build failed (exit $build_result, $(( SECONDS - build_started ))s)"
    fi
    return "$build_result"
}

build_app
build_bin_path="$(cd "$package_root" && swift build -c "$configuration" --show-bin-path)"
binary="$build_bin_path/CodexQuotaMonitor"
info_plist="$package_root/resource/Info.plist"
app_icon="$package_root/resource/AppIcon.icns"
[[ -x "$binary" ]] || { print -u2 "Built executable not found: $binary"; exit 1; }
[[ -f "$info_plist" ]] || { print -u2 "Info.plist not found: $info_plist"; exit 1; }
[[ -f "$app_icon" ]] || { print -u2 "App icon not found: $app_icon"; exit 1; }

stage_dir="$(mktemp -d "$destination_dir/.CodexQuotaChecker.stage.XXXXXX")"
stage_owned=1
stage_app="$stage_dir/CodexQuotaChecker.app"

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp -- "$binary" "$stage_app/Contents/MacOS/CodexQuotaMonitor"
cp -- "$info_plist" "$stage_app/Contents/Info.plist"
cp -- "$app_icon" "$stage_app/Contents/Resources/AppIcon.icns"
# 서비스 표정 SVG의 Swift 패키지 리소스 번들 포함
resource_bundle="$build_bin_path/CodexQuotaMonitor_CodexQuotaMonitorKit.bundle"
[[ -d "$resource_bundle" ]] || { print -u2 "Resource bundle not found: $resource_bundle"; exit 1; }
cp -R -- "$resource_bundle" "$stage_app/Contents/Resources/"
chmod 755 "$stage_app/Contents/MacOS/CodexQuotaMonitor"

[[ -x "$stage_app/Contents/MacOS/CodexQuotaMonitor" ]] || {
    print -u2 "Staged executable is not runnable: $stage_app"
    exit 1
}
[[ -f "$stage_app/Contents/Info.plist" && -d "$stage_app/Contents/Resources" ]] || {
    print -u2 "Staged app bundle is incomplete: $stage_app"
    exit 1
}
/usr/bin/plutil -lint "$stage_app/Contents/Info.plist" >/dev/null

# ServiceManagement의 앱 식별을 위한 번들·리소스 임시 서명 및 식별자 대조
/usr/bin/codesign --force --deep --sign - --timestamp=none "$stage_app"
/usr/bin/codesign --verify --deep --strict "$stage_app"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$stage_app/Contents/Info.plist")"
signed_identifier="$(/usr/bin/codesign -dv --verbose=4 "$stage_app" 2>&1 | /usr/bin/awk -F= '$1 == "Identifier" { print $2; exit }')"
[[ -n "$bundle_identifier" && "$signed_identifier" == "$bundle_identifier" ]] || {
    print -u2 "Signed identifier does not match CFBundleIdentifier: $signed_identifier != $bundle_identifier"
    exit 1
}

if [[ -e "$target_app" ]]; then
    backup_app="$target_app.backup.$$.$RANDOM"
    [[ ! -e "$backup_app" ]] || {
        print -u2 "Refusing to overwrite an existing backup path: $backup_app"
        exit 1
    }
    mv -- "$target_app" "$backup_app"
    backup_owned=1
fi

# 기존 앱을 형제 백업으로 보존한 뒤 검증된 스테이징 번들로 교체
if ! mv -- "$stage_app" "$target_app"; then
    restore_backup || true
    print -u2 "Unable to install staged app bundle: $target_app"
    exit 1
fi

stage_owned=0
if [[ -d "$stage_dir" ]]; then
    rmdir "$stage_dir" 2>/dev/null || true
fi
if (( backup_owned )); then
    rm -rf -- "$backup_app"
    backup_owned=0
fi
print "Packaged ad-hoc signed app: $target_app"
