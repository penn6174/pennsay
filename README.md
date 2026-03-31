# Doubao Murmur

一个 macOS 菜单栏应用，通过劫持豆包 Web 版的语音识别能力，实现全局语音输入。

按下右 `⌥ Option` 键开始/停止语音识别，识别结果自动复制到剪贴板并粘贴到当前光标所在的输入框。

<p align="center">
  <img src="docs/screenshots/overlay_pannel.png" width="500" alt="语音识别悬浮窗">
</p>

## 免责声明

- **本项目仅供个人学习和研究使用**，不得用于任何商业用途。
- 本项目通过内嵌 WKWebView 加载豆包（doubao.com）网页版来调用其语音识别功能，**并非官方提供的 API 或 SDK**。豆包的页面结构、接口随时可能变化，届时本项目可能无法正常工作。
- 使用本项目前，你需要拥有一个有效的豆包账号并自行完成登录。
- 本项目不会收集、存储或上传你的任何数据（包括语音数据和识别结果），所有处理均在本地完成，语音数据由豆包服务端处理。
- 使用本项目所产生的一切后果由使用者自行承担，作者不对因使用本项目而导致的任何损失或问题负责。
- 如果本项目侵犯了相关方的权益，请联系作者删除。

## 实现方式

### 整体架构

```
┌─────────────────────────────────────────────┐
│  doubao-murmur (菜单栏应用, 无 Dock 图标)      │
├─────────────────────────────────────────────┤
│  HotkeyManager        全局热键监听             │
│  ├─ CGEvent tap 监听右 ⌥ Option / ESC         │
│  └─ 需要辅助功能权限 (Accessibility)            │
├─────────────────────────────────────────────┤
│  WebViewManager       隐藏的 WKWebView        │
│  ├─ 加载 https://www.doubao.com/chat          │
│  ├─ JS 注入: 拦截 WebSocket ASR 消息           │
│  ├─ JS 注入: DOM 操作 (点击语音按钮)            │
│  ├─ WKContentRuleList: 屏蔽 /completion 请求   │
│  └─ 自动授予麦克风权限                          │
├─────────────────────────────────────────────┤
│  OverlayPanel         浮动悬浮窗               │
│  ├─ 屏幕顶部居中显示                            │
│  └─ 实时展示识别文本                            │
├─────────────────────────────────────────────┤
│  TranscriptionManager 状态机调度器             │
│  └─ idle → starting → recording → stopping    │
├─────────────────────────────────────────────┤
│  PasteHelper          剪贴板 + 自动粘贴        │
│  ├─ NSPasteboard 写入文本                      │
│  └─ CGEvent 模拟 ⌘V                           │
└─────────────────────────────────────────────┘
```

### 核心原理

1. **内嵌 WebView 加载豆包**：应用启动后在后台加载 `doubao.com/chat`，复用豆包网页版的语音识别功能。
2. **WebSocket 拦截**：在页面加载前通过 JS 注入 monkey-patch `WebSocket`，拦截豆包 ASR（语音识别）的 WebSocket 消息，实时获取识别结果。
3. **DOM 操控**：通过 JS 注入模拟点击豆包页面上的语音输入按钮，控制录音的开始和结束。
4. **请求屏蔽**：使用 `WKContentRuleList` 屏蔽 `/chat/completion` 请求，阻止豆包将语音识别结果发送给大模型。
5. **全局热键**：通过 `CGEvent tap` 监听右 `⌥ Option` 键，实现全局快捷键触发，无需切换到应用窗口。

## 使用方式

### 安装

从 [Releases](../../releases) 页面下载最新版本的 `Doubao-Murmur-vX.X.X.zip`，解压后将 `Doubao Murmur.app` 拖入「应用程序」文件夹即可。

> 要求 macOS 13.0+

### 首次使用

1. **授予辅助功能权限**：首次启动时，系统会提示授予辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能），这是监听全局快捷键所必需的。
2. **授予麦克风权限**：首次语音输入时，系统会提示授予麦克风权限。
3. **登录豆包**：点击菜单栏图标，选择「登录豆包」，在弹出的窗口中完成登录。登录成功后窗口会自动关闭。

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| 右 `⌥ Option` | 开始 / 停止语音识别 |
| `ESC` | 取消当前语音识别（不复制、不粘贴） |

### 使用流程

<img src="docs/screenshots/menu_bar.png" width="240" alt="菜单栏">

1. 确保菜单栏显示「已登录」状态
2. 将光标定位到任意输入框
3. 按下右 `⌥ Option` 键，屏幕顶部出现悬浮窗，开始说话
4. 悬浮窗中会实时显示识别到的文字
5. 再次按下右 `⌥ Option` 键结束识别，文字会自动复制到剪贴板并粘贴到输入框
6. 如果想取消，按 `ESC` 即可

点击菜单中的「使用帮助」可查看快捷键和使用说明：

<img src="docs/screenshots/help_pannel.png" width="400" alt="使用帮助">

## 开发

### 环境要求

- macOS 13.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 构建与运行

```bash
# 克隆项目
git clone <repo-url>
cd doubao-murmur

# 生成 Xcode 项目
xcodegen generate

# 构建
./scripts/build.sh

# 运行（构建后直接运行，日志输出到终端）
./scripts/run.sh

# 或者一步完成构建+运行
./scripts/dev.sh
```

### 发布

推送 `v*` 格式的 tag 会自动触发 GitHub Actions 构建并创建 Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE)
