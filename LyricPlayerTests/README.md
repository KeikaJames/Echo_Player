# 格式分析回归

这组测试把“能播放”与“能分析”分开验证：播放仍由 AVFoundation / KSPlayer 选路，转写和拍点共享一个 `AnalysisAudioSource.Prepared`。测试不请求语音权限、不访问网络，也不依赖宿主安装 `ffmpeg`。

覆盖面：

- 原生音频直通，不删用户原文件；
- WMA 触发 FFmpeg 回退，产物可被 `AVAudioFile` 读取；
- 并发准备、预取消、失败解码、容量上限和临时文件清理；
- 全格式路由、否定缓存、语言隔离、大文件内容代次与同路径替换；
- 原生 / FFmpeg 准备音频共用拍点管线，歌词 ID 可无损交给双语管线；
- 自动更新信任源，以及 Release app/FFmpeg frameworks 的 arm64 + x86_64 架构。

工程接入测试 target 后，执行：

```bash
scripts/format_regression.sh contracts
scripts/format_regression.sh test
scripts/format_regression.sh universal
```

`contracts` 会拒绝 `Process` 或 Homebrew 绝对路径，因此可及时发现对宿主 `ffmpeg` 的偶然依赖。`universal` 会强制双架构构建，再对 App 主程序和关键 libav frameworks 逐一执行 `lipo` 检查。
