# VoiceInput

`VoiceInput` 是一个 macOS 14+ 菜单栏语音输入工具。它沿用 `lilong7676/doubao-murmur` 的豆包 Web 登录劫持和 WSS ASR 方案，在此基础上补了原生悬浮窗、可配置快捷键、LLM 流式后处理、更新检查、卸载和分发链路。

## 特性

- 菜单栏常驻应用，`LSUIElement = YES`
- 豆包 Web 登录提取凭证后销毁 `WKWebView`
- 底部居中的 HUD 悬浮窗，实时波形由音频 RMS 驱动
- 可配置快捷键系统
  - `Right Option` / `Left Option` / `Right Command` / `Left Command` / `Right Control`
  - `Caps Lock` 引导关闭锁定行为
  - `Fn` 可选但带警告
  - `Hold` / `Single Tap Toggle` / `Double Tap Toggle`
- LLM 流式润色
  - 自定义 `Base URL` / `API Key` / `Model` / `System Prompt` / `Timeout`
  - API Key 存 Keychain，其他配置存 `UserDefaults`
  - 任意失败都回退粘贴 ASR 原文
- 原生 Settings 窗口
  - `General`
  - `Shortcut`
  - `LLM 润色`
- 日志同时写 `os.Logger` 和 `~/Library/Logs/DoubaoMurmur/voiceinput.log`
- `make build` / `make run` / `make release` / `make install` / `make clean`

## 系统要求

- macOS 14+
- XcodeGen
- Swift toolchain
- 首次运行时授予：
  - `辅助功能`
  - `麦克风`

## 安装

从 Releases 下载以下任一产物：

- `VoiceInput-vX.Y.Z.app`
- `VoiceInput-vX.Y.Z.zip`
- `VoiceInput-vX.Y.Z.dmg`

首次打开未公证的构建时，Gatekeeper 可能阻止启动。可按下面流程放行：

1. 先双击应用，让系统拦截一次。
2. 打开 `系统设置 -> 隐私与安全性`。
3. 在底部找到 `仍要打开`。
4. 再次确认启动。

## 首次使用

1. 启动应用后，在菜单栏确认状态项出现。
2. 如果还没登录，点击 `登录豆包`，在弹出的窗口里完成网页登录。
3. 授予 `辅助功能` 和 `麦克风` 权限。
4. 在 `设置... -> Shortcut` 里确认触发键和模式。
5. 如果要启用后处理，在 `设置... -> LLM 润色` 里配置 API。

## 快捷键

默认值：

- 触发键：`Right Option`
- 模式：`Hold`
- Double Tap 时间窗：`300ms`
- 取消：`Esc`

在 `Hold` 模式下，按住说话，松开结束。短于 `80ms` 的按压会被当成误触忽略。

## 快捷键失灵怎么办

因 ad-hoc 签名，升级后 TCC 记录的签名哈希会跟新 app 对不上，系统设置里权限看起来已允许但快捷键不响应。修复：

```bash
tccutil reset Accessibility com.voiceinput.app
```

然后重启 PennSay，同意新的权限请求即可。Homebrew cask 的 `postflight` 已在新装/升级时自动处理。

## LLM 润色

`LLM 润色` 面板支持：

- 启用/禁用
- API Base URL
- API Key
- Model
- System Prompt
- Timeout
- `Test`
- `重置 System Prompt 为默认值`
- `Save`

失败兜底策略：

- Timeout：通知 `LLM timeout`，粘贴 ASR 原文
- HTTP 错误：通知 `LLM error: {code}`，粘贴 ASR 原文
- 网络不可达：通知 `LLM unreachable`，粘贴 ASR 原文
- API Key 为空时，启用开关自动灰显

## 构建

```bash
xcodegen generate
make build
make run
```

发布构建：

```bash
make release
```

安装到 `/Applications`：

```bash
make install
```

## 目录

- App Support：`~/Library/Application Support/DoubaoMurmur/`
- Preferences：`~/Library/Preferences/com.voiceinput.app.plist`
- Logs：`~/Library/Logs/DoubaoMurmur/`
- Keychain Service：`DoubaoMurmur`

## 手动卸载

菜单栏里有 `卸载并退出`，会尝试自动清理。若需手动审计或兜底删除，请检查并移除：

- `/Applications/VoiceInput.app`
- `~/Library/Application Support/DoubaoMurmur/`
- `~/Library/Preferences/com.voiceinput.app.plist`
- `~/Library/Logs/DoubaoMurmur/`
- Keychain 中 service 为 `DoubaoMurmur` 的通用密码项

可用于复核的命令：

```bash
security find-generic-password -s DoubaoMurmur
find ~/Library \( -iname "*doubaomurmur*" -o -iname "voiceinput*" \)
```

## 开发说明

本仓库保留 `project.yml` 和 `xcodegen generate`，同时补了一个不依赖完整 Xcode 的 `swiftc` 打包链路，便于在只装 Command Line Tools 的机器上构建 `.app`。

## License

MIT
