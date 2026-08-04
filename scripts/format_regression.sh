#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-contracts}"
PROJECT="$ROOT/LyricPlayer.xcodeproj"
SCHEME="LyricPlayer"
DERIVED="${ECHO_DERIVED_DATA:-/tmp/echo-player-format-regression}"
PACKAGES="$ROOT/build/SourcePackages"
MINIMUM_MACOS_VERSION="14.1"
if [ -n "${XCODEBUILD:-}" ]; then
    XCODEBUILD="$XCODEBUILD"
elif SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null)" &&
     [[ "$SELECTED_DEVELOPER_DIR" == *.app/Contents/Developer ]] &&
     [ -x "$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    XCODEBUILD="$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild"
elif [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
else
    XCODEBUILD=""
fi

command -v rg >/dev/null 2>&1 || {
    echo "format-regression: 缺少 rg" >&2
    exit 1
}

fail() {
    echo "format-regression: $*" >&2
    exit 1
}

require_pattern() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    rg -q -- "$pattern" "$file" || fail "$message"
}

reject_pattern() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    if rg -q -- "$pattern" "$file"; then fail "$message"; fi
}

contracts() {
    local source="$ROOT/LyricPlayer/Transcription/AnalysisAudioSource.swift"
    local player="$ROOT/LyricPlayer/Models/PlayerModel.swift"
    local track="$ROOT/LyricPlayer/Models/Track.swift"
    local update="$ROOT/LyricPlayer/Models/UpdateChecker.swift"
    local cache="$ROOT/LyricPlayer/Models/TranscriptCache.swift"
    local ffmpeg="$ROOT/LyricPlayer/Models/FFmpegBackend.swift"
    local whisper="$ROOT/LyricPlayer/Transcription/WhisperTranscriber.swift"
    local identity="$ROOT/LyricPlayer/Models/MediaFileIdentity.swift"
    local project="$ROOT/LyricPlayer.xcodeproj/project.pbxproj"
    local compatibility="$ROOT/LyricPlayer/Views/SystemCompatibility.swift"
    local translation="$ROOT/LyricPlayer/Transcription/SystemTranslationTask.swift"
    local captions="$ROOT/LyricPlayer/Transcription/LiveCaptionEngine.swift"
    local summary="$ROOT/LyricPlayer/Transcription/MeetingSummarizer.swift"

    [ -f "$source" ] || fail "缺少 AnalysisAudioSource.swift"
    require_pattern 'MACOSX_DEPLOYMENT_TARGET = 14\.1;' "$project" "最低系统版本未设为 macOS 14.1"
    reject_pattern 'MACOSX_DEPLOYMENT_TARGET = (1[5-9]|2[0-9])' "$project" \
        "工程中仍有高于 Sonoma 14.1 的部署目标"
    require_pattern 'AdaptiveGlassContainer' "$compatibility" "Liquid Glass 缺少旧系统回退"
    require_pattern '#available\(macOS 15\.0' "$translation" "系统翻译未与 Sonoma 隔离"
    require_pattern 'summarizeLocally' "$summary" "旧系统缺少本地会议摘要"
    [ "$(rg -c 'startDiarizationLoop\(gen: gen\)' "$captions")" -ge 2 ] || \
        fail "旧语音引擎未接入说话人分离"
    require_pattern 'AnalysisAudioSource\.Prepared' "$player" "PlayerModel 未持有分析音频生命周期"
    require_pattern 'AnalysisAudioSource\.prepare' "$player" "PlayerModel 未建立原生/FFmpeg 共享准备通路"
    require_pattern 'startLyricsPipeline' "$player" "曲目加载未接入歌词管线"
    require_pattern 'startBeatGridAnalysis' "$player" "曲目加载未接入拍点分析"
    require_pattern 'Task\.checkCancellation|Task\.isCancelled' "$source" "解码准备缺少取消检查"
    require_pattern 'deinit' "$source" "Prepared 未声明生命周期清理"
    require_pattern 'removeItem' "$source" "Prepared 未清理临时文件"
    require_pattern 'maximumTemporaryPCMBytes' "$source" "临时 PCM 缺少硬上限"
    require_pattern 'temporarySpaceReserve' "$source" "临时 PCM 缺少磁盘保留空间"
    require_pattern 'runtimeSpaceReserve' "$source" "长音轨解码缺少运行期容量检查"
    require_pattern 'abandonedTemporaryFileCleanup' "$source" "异常退出后缺少临时音频回收"
    reject_pattern 'Process\(|executableURL|/opt/homebrew|/usr/local/bin|/usr/bin/ffmpeg' "$source" \
        "分析回退不得依赖宿主 ffmpeg 命令"
    require_pattern 'maximumFingerprintBytes' "$cache" "媒体缓存指纹缺少 I/O 上限"
    require_pattern 'generation.*&\+=|generation &\+=' "$cache" "强制重试缺少缓存删除代次"
    require_pattern 'runBeforeWriteHookForTesting' "$cache" "缓存删除竞态缺少确定性回归屏障"
    require_pattern 'generationIdentifierKey' "$identity" "大文件缓存缺少内容代次"
    require_pattern 'sourceIdentity' "$cache" "识别缓存未绑定源文件身份"
    require_pattern 'lyricsPipelineGeneration' "$player" "同曲强制识别缺少流水线代次"
    require_pattern 'lyricsProgressGeneration' "$player" "歌词终态缺少迟到进度隔离"
    require_pattern 'playbackSourceIdentity' "$player" "媒体分析未绑定播放时的文件版本"
    require_pattern 'expectedSourceIdentity' "$source" "分析音频准备可切换到同路径新文件"
    require_pattern 'videoStreamIndex.*av_find_best_stream|videoStreamIndex = av_find_best_stream' "$source" \
        "FFmpeg 分析未按播放视频节目选择音轨"
    require_pattern 'prepared\.sourceIdentity\.isCurrentContent' "$player" "拍点分析未绑定源文件身份"
    require_pattern 'softwareEdgeSamplePending' "$ffmpeg" "FFmpeg 软件画面取色缺少背压"
    require_pattern 'AVAudioEngineConfigurationChange' "$ffmpeg" "FFmpeg 音频设备切换缺少自愈"
    require_pattern 'applyPlaybackSettings\(to: mePlayer\)' "$ffmpeg" "FFmpeg ready 后未恢复音量与倍速"
    require_pattern 'onPlaybackError' "$ffmpeg" "FFmpeg 异步解码失败被当成自然播完"
    reject_pattern 'currentTime < duration.*finish|finish[^{]*\{[^}]*currentTime < duration' "$ffmpeg" \
        "FFmpeg 纯音频 EOF 不得用已切换的 KSPlayer 时钟判定意外结束"
    require_pattern 'failedToPlayToEndTimeNotification' "$ROOT/LyricPlayer/Models/VideoBackend.swift" \
        "原生视频异步解码失败未上报"
    require_pattern 'cancellableValue' "$whisper" "Whisper single-flight 等待无法取消脱离"
    require_pattern 'modelRevision = "[0-9a-f]{40}"' "$whisper" "Whisper 运行时模型下载未锁定提交"
    require_pattern 'ModelDownloader' "$whisper" "Whisper 运行时仍跟随可变 main 模型"
    reject_pattern 'WhisperKit\.download' "$whisper" "Whisper 运行时仍从可变 main 下载模型"
    require_pattern 'deepChunkSeconds' "$whisper" "Whisper 深度识别缺少内存分段上限"
    require_pattern 'deepChunkRange' "$whisper" "Whisper 深度识别未通过有界范围迭代"
    require_pattern 'deepChunkOverlapSeconds' "$whisper" "Whisper 深度识别在分段边界会丢词"
    require_pattern '\.filter \{ owns\(' "$whisper" "Whisper 重叠分段未做唯一归属去重"
    require_pattern 'inputReadSeconds' "$whisper" "Whisper 音频读取缺少可取消分段"
    reject_pattern 'AudioProcessor\.loadAudio\(fromFile: file' "$whisper" \
        "Whisper 分段读取仍会窄化超长音轨帧数"
    reject_pattern 'transcribe\(audioPath: url\.path' "$whisper" "Whisper 不得一次加载整首音轨"
    require_pattern 'box\.install\(task\)' "$ROOT/LyricPlayer/Transcription/SystemTranscriber.swift" \
        "旧系统识别任务安装存在取消竞态"
    require_pattern 'abandonedChunkCleanup' "$ROOT/LyricPlayer/Transcription/SystemTranscriber.swift" \
        "旧系统识别缺少异常退出后的临时分片回收"
    require_pattern 'AuthorizationBox' "$ROOT/LyricPlayer/Transcription/SystemTranscriber.swift" \
        "旧系统识别授权等待不可取消"
    require_pattern 'collector\.cancel\(\)' "$ROOT/LyricPlayer/Transcription/SystemTranscriber.swift" \
        "新系统识别结果收集未随父任务取消"
    reject_pattern 'AudioProcessor\.loadAudio\(fromFile: file' \
        "$ROOT/LyricPlayer/Transcription/SystemTranscriber.swift" \
        "旧系统识别分片仍会窄化超长音轨帧数"

    for extension in mkv webm ogg oga opus ape wma flv avi ts; do
        require_pattern "\"$extension\"" "$track" "媒体路由丢失扩展名: $extension"
    done

    require_pattern 'UpdateRepository' "$ROOT/LyricPlayer/Info.plist" "自动更新源配置丢失"
    require_pattern 'isTrustedSource' "$update" "自动更新来源校验丢失"
    require_pattern 'SHA-?256|sha256' "$update" "自动更新指纹链路丢失"
    require_pattern 'isExpectedVersion' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验发布版本"
    require_pattern 'isCompatibleMinimumSystemVersion' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验最低系统版本"
    require_pattern 'LSMinimumSystemVersion' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未读取最低系统版本"
    require_pattern 'minimumSystemVersions\(inMachO' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验 Mach-O 最低系统版本"
    require_pattern 'LSMinimumSystemVersionByArchitecture' \
        "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验分架构最低系统版本"
    require_pattern 'NSWindow\.willCloseNotification' "$ROOT/LyricPlayer/Views/LiveCaptionsView.swift" \
        "关闭实时字幕窗口后可能继续占用麦克风"
    require_pattern 'executableSupportsCurrentArchitecture' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验当前架构"
    require_pattern 'codesign.*--verify|--verify.*--deep.*--strict' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未校验完整性"
    require_pattern 'removeAbandonedTemporaryFiles' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新器缺少异常退出后的临时文件回收"
    require_pattern 'isValidSHA256' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "自动更新允许缺失发布指纹"
    require_pattern 'renameatx_np.*RENAME_SWAP|RENAME_SWAP' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "自动更新未使用同卷原子交换"
    require_pattern 'Task\.detached\(priority: \.userInitiated\)' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新校验与解压仍可能阻塞主线程"
    require_pattern 'format_regression\.sh universal' "$ROOT/.github/workflows/release.yml" \
        "发版产物未执行 universal 与签名门禁"
    require_pattern 'format_regression\.sh test' "$ROOT/.github/workflows/release.yml" \
        "发版前未运行 XCTest"
    require_pattern '^    runs-on: macos-14$' "$ROOT/.github/workflows/release.yml" \
        "发版前未在 Sonoma runner 启动产物"
    require_pattern '/usr/bin/arch.*matrix\.architecture' "$ROOT/.github/workflows/release.yml" \
        "Sonoma runner 未分别启动 universal 两个架构"
    reject_pattern 'macos-14-arm64' "$ROOT/.github/workflows/release.yml" \
        "GitHub Actions 不支持 macos-14-arm64 YAML 标签"
    require_pattern 'RELEASE_MARKETING_VERSION=.*RELEASE_TAG' "$ROOT/.github/workflows/release.yml" \
        "发版 tag 未写入应用版本"
    require_pattern 'actions/checkout@[0-9a-f]{40}' "$ROOT/.github/workflows/release.yml" \
        "发版 checkout 未锁定不可变提交"
    require_pattern 'persist-credentials: false' "$ROOT/.github/workflows/release.yml" \
        "发版构建仍向工作树写入仓库令牌"
    require_pattern 'MODEL_REVISION: [0-9a-f]{40}' "$ROOT/.github/workflows/release.yml" \
        "发版内置模型未锁定不可变提交"
    reject_pattern 'pip3 install|hf download' "$ROOT/.github/workflows/release.yml" \
        "发版构建不得运行未锁定的 Python/Hugging Face 工具链"
    reject_pattern 'continue-on-error: true' "$ROOT/.github/workflows/release.yml" \
        "内置语音模型失败时不得继续发版"
    require_pattern '^  publish-release:' "$ROOT/.github/workflows/release.yml" \
        "发版写权限未与构建 job 隔离"
    require_pattern 'usesFFmpegPlayback' "$ROOT/LyricPlayer/Views/ContentView.swift" \
        "FFmpeg 视频缺少完整播放控制条"
    require_pattern 'pendingSeek' "$ffmpeg" "FFmpeg opening 阶段的 seek 会丢失"
    require_pattern 'activeSeek' "$ffmpeg" "FFmpeg seek 完成回调会覆盖最新播放意图"
    require_pattern 'watchdogOpeningTicks' "$ffmpeg" "FFmpeg 打开媒体可能无限等待"
    require_pattern 'watchdogSeekTicks' "$ffmpeg" "FFmpeg seek 可能无限等待"
    require_pattern 'openingTimeoutTask' "$ROOT/LyricPlayer/Models/VideoBackend.swift" \
        "原生视频打开媒体可能无限等待"
    require_pattern 'AVPlayer\.rateDidChangeNotification' \
        "$ROOT/LyricPlayer/Models/VideoBackend.swift" \
        "原生视频打开阶段无法保留 AVKit HUD 暂停意图"
    require_pattern 'reason == \.setRateCalled' "$ROOT/LyricPlayer/Models/VideoBackend.swift" \
        "原生视频把系统强制暂停误判为用户意图"
    require_pattern 'preferredAudioTrackID' "$source" "原生多音轨视频分析未跟随播放音轨"
    require_pattern 'preferredAudioStreamIndex' "$source" "FFmpeg 多音轨分析未跟随播放音轨"
    require_pattern 'track-' "$player" "多音轨识别缓存未按音轨隔离"
    require_pattern 'stream-' "$player" "FFmpeg 多音轨识别缓存未按音轨隔离"
    require_pattern 'onAudioTracksChange' "$player" "FFmpeg 音轨选择未接入播放模型"
    require_pattern 'fallBackToFFmpeg' "$player" "原生视频异步失败后未降级 FFmpeg"
    require_pattern 'playbackIntentGeneration' "$player" \
        "播放失败延迟跳转会覆盖用户的最新暂停命令"
    require_pattern 'playbackSourceIdentity == nil' "$player" \
        "播放失败卸载后无法用播放键重试当前曲目"
    require_pattern 'preferAudioTrack\(at:' "$player" "原生视频降级 FFmpeg 后丢失用户音轨选择"
    require_pattern 'handleAudioTrackChange' "$player" "切换音轨后未重建分析管线"
    require_pattern 'startLyricsPipeline\(forceRecognize: false\)' "$player" \
        "切换音轨后会跳过侧车 LRC"
    require_pattern 'guard player === audioBackend' "$player" "原生音频失败后未回退内置 FFmpeg"
    require_pattern 'defaultRate' "$ROOT/LyricPlayer/Models/VideoBackend.swift" \
        "AVKit HUD 倍速未与播放模型同步"
    require_pattern 'frameSegments' "$ROOT/LyricPlayer/Models/EnginePlayer.swift" \
        "超长原生音频仍可能窄化 frameCount"
    require_pattern 'onPlaybackError' "$ROOT/LyricPlayer/Models/EnginePlayer.swift" \
        "原生音频输出启动失败未上报降级"
    require_pattern '#if DEBUG' "$update" "生产更新源允许 UserDefaults 覆盖"
    require_pattern 'activeSession' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新下载会话未显式释放"
    require_pattern 'currentBundleURL' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新清理可能删除当前运行包"
    require_pattern 'maximumDownloadBytes' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新下载缺少体积上限"
    require_pattern 'maximumExpandedBytes' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新解压缺少 zip bomb 上限"
    require_pattern 'archiveSummary' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新包未在解压前检查条目与展开体积"
    require_pattern 'beginPendingUpdateLaunch' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "新版启动失败后无法回滚旧版"
    require_pattern 'confirmPendingUpdateLaunchAfterHealthCheck' \
        "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新器在新版健康确认前删除了旧版"
    require_pattern 'willPerformHTTPRedirection' "$ROOT/LyricPlayer/Models/UpdateInstaller.swift" \
        "更新下载重定向未重新校验来源"
    require_pattern 'actions: read' "$ROOT/.github/workflows/release.yml" \
        "发布 job 无权读取构建产物"
    require_pattern 'KSPlayer' "$ROOT/LyricPlayer.xcodeproj/project.pbxproj" "KSPlayer 产品依赖丢失"
    require_pattern 'gh release create.*|gh release create' "$ROOT/.github/workflows/release.yml" \
        "发布 job 缺少 release 创建步骤"
    require_pattern '--repo "\$GITHUB_REPOSITORY"' "$ROOT/.github/workflows/release.yml" \
        "发布 job 未明确指定目标仓库"

    echo "format-regression: 快速契约检查通过"
}

xcodebuild_common() {
    [ -n "$XCODEBUILD" ] && [ -x "$XCODEBUILD" ] || fail "找不到完整 Xcode 的 xcodebuild"
    local developer_dir="${XCODEBUILD%/usr/bin/xcodebuild}"
    DEVELOPER_DIR="$developer_dir" "$XCODEBUILD" -version >/dev/null 2>&1 || \
        fail "xcodebuild 不可用，请安装或选择完整 Xcode"
    mkdir -p "$DERIVED/ModuleCache.noindex" "$DERIVED/SwiftPMModuleCache" "$DERIVED/Cache" \
        "$DERIVED/Coverage"
    export DEVELOPER_DIR="$developer_dir"
    export CLANG_MODULE_CACHE_PATH="$DERIVED/ModuleCache.noindex"
    export SWIFTPM_MODULECACHE_OVERRIDE="$DERIVED/SwiftPMModuleCache"
    export XDG_CACHE_HOME="$DERIVED/Cache"
    export LLVM_PROFILE_FILE="$DERIVED/Coverage/%p.profraw"
}

unit_tests() {
    contracts
    require_pattern 'LyricPlayerTests' "$ROOT/LyricPlayer.xcodeproj/project.pbxproj" \
        "尚未把 LyricPlayerTests 加入 Xcode 工程"
    xcodebuild_common
    "$XCODEBUILD" \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
        -clonedSourcePackagesDirPath "$PACKAGES" -skipPackageUpdates \
        -disableAutomaticPackageResolution -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO test
}

assert_universal() {
    local binary="$1"
    local architectures
    [ -f "$binary" ] || fail "缺少 Mach-O: $binary"
    architectures="$(/usr/bin/lipo -archs "$binary")"
    [[ " $architectures " == *" arm64 "* ]] || fail "$binary 缺少 arm64"
    [[ " $architectures " == *" x86_64 "* ]] || fail "$binary 缺少 x86_64"
}

binary_minimum_versions() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '$1 == "minos" { print $2 }' | /usr/bin/sort -u
}

version_at_most() {
    /usr/bin/awk -v actual="$1" -v maximum="$2" 'BEGIN {
        split(actual, a, "."); split(maximum, m, ".")
        for (i = 1; i <= 3; i++) {
            if (a[i] + 0 < m[i] + 0) exit 0
            if (a[i] + 0 > m[i] + 0) exit 1
        }
        exit 0
    }'
}

assert_macos_compatible() {
    local binary="$1"
    local versions version
    versions="$(binary_minimum_versions "$binary")"
    [ -n "$versions" ] || fail "$binary 缺少 macOS 最低版本"
    while IFS= read -r version; do
        version_at_most "$version" "$MINIMUM_MACOS_VERSION" || \
            fail "$binary 最低要求 macOS $version，高于 $MINIMUM_MACOS_VERSION"
    done <<< "$versions"
}

universal_build() {
    contracts
    xcodebuild_common
    local build_command=(
        "$XCODEBUILD"
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release
        -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES"
        -skipPackageUpdates -disableAutomaticPackageResolution
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
    )
    if [ -n "${RELEASE_MARKETING_VERSION:-}" ]; then
        build_command+=("MARKETING_VERSION=$RELEASE_MARKETING_VERSION")
    fi
    if [ -n "${RELEASE_BUILD_NUMBER:-}" ]; then
        build_command+=("CURRENT_PROJECT_VERSION=$RELEASE_BUILD_NUMBER")
    fi
    "${build_command[@]}" build

    local app="$DERIVED/Build/Products/Release/LyricPlayer.app"
    local executable="$app/Contents/MacOS/LyricPlayer"
    local frameworks="$app/Contents/Frameworks"
    local info="$app/Contents/Info.plist"
    [ -d "$app" ] || fail "未生成 Release app"
    assert_universal "$executable"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")" \
        = "$MINIMUM_MACOS_VERSION" ] || fail "Release app 最低系统版本不是 macOS $MINIMUM_MACOS_VERSION"
    [ "$(binary_minimum_versions "$executable")" = "$MINIMUM_MACOS_VERSION" ] || \
        fail "Release 主程序的 Mach-O 最低系统版本不是 macOS $MINIMUM_MACOS_VERSION"
    /usr/bin/xcrun dyld_info -dependents "$executable" | \
        rg -q 'weak-link.*Translation\.framework' || fail "Translation.framework 未弱链接"
    /usr/bin/xcrun dyld_info -dependents "$executable" | \
        rg -q 'weak-link.*FoundationModels\.framework' || fail "FoundationModels.framework 未弱链接"

    local framework_count deep_framework_count
    framework_count="$(find "$frameworks" -maxdepth 1 -type d -name '*.framework' | wc -l | tr -d ' ')"
    [ "$framework_count" -gt 0 ] || fail "Release app 未内嵌 FFmpeg frameworks"
    local framework name
    for framework in "$frameworks"/*.framework; do
        name="$(basename "$framework" .framework)"
        assert_universal "$framework/$name"
        assert_macos_compatible "$framework/$name"
        /usr/bin/otool -L "$framework/$name" | reject_binary_paths
        /usr/bin/codesign --verify --strict "$framework" || fail "$name.framework 签名无效"
    done
    deep_framework_count="$(find "$frameworks" -path '*/Versions/A/Resources/Info.plist' | wc -l | tr -d ' ')"
    [ "$framework_count" = "$deep_framework_count" ] || \
        fail "FFmpeg frameworks 未全部转换为 macOS deep bundle"
    [ -z "$(find "$frameworks" -maxdepth 2 -name Info.plist -print -quit)" ] || \
        fail "FFmpeg frameworks 仍含根目录 Info.plist"
    /usr/bin/otool -L "$executable" | reject_binary_paths
    local repository
    repository="$(/usr/libexec/PlistBuddy -c 'Print :UpdateRepository' "$info")"
    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        fail "Release app 的 UpdateRepository 格式无效"
    [[ "$repository" != OWNER/* ]] || fail "Release app 仍在使用更新源占位值"
    if [ -n "${RELEASE_MARKETING_VERSION:-}" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" \
            = "$RELEASE_MARKETING_VERSION" ] || fail "Release app 版本未匹配发版 tag"
    fi
    if [ -n "${RELEASE_BUILD_NUMBER:-}" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" \
            = "$RELEASE_BUILD_NUMBER" ] || fail "Release app build number 未匹配 CI"
    fi
    /usr/bin/codesign --force --sign - --timestamp=none "$app"
    /usr/bin/codesign --verify --deep --strict "$app" || fail "Release app ad-hoc 签名验证失败"
    echo "format-regression: universal Release 与自动更新包契约检查通过"
}

reject_binary_paths() {
    if rg -q '/opt/homebrew|/usr/local'; then
        fail "Release app 含开发机绝对动态库路径"
    fi
}

case "$MODE" in
    contracts) contracts ;;
    test) unit_tests ;;
    universal) universal_build ;;
    *) fail "用法: $0 [contracts|test|universal]" ;;
esac
