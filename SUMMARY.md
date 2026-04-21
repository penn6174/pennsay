# SUMMARY

## 完成情况
- M1 `7/7`：菜单栏状态、悬浮窗、ASR partial、TextEdit 粘贴、ESC 取消、凭证过期提示、日志路径全部通过，证据在 `evidence/m1/`
- M2 `8/8`：HUD 悬浮窗参数、RMS 波形、宽度动画、多屏定位、快捷键持久化、三种触发模式、热切换触发键、Caps Lock 引导全部通过，证据在 `evidence/m2/`
- M3 `10/10`：Settings 三栏、LLM 配置持久化、Prompt 重置、Keychain、流式 Refining UI、禁用回退、断网回退、超时回退、API Key 清空灰显、日志链路全部通过，证据在 `evidence/m3/`
- M4 `5/6`：发布产物、DMG 视觉引导、GitHub Actions、检查更新、README 卸载清单通过；卸载字面 `find ~/Library ...` 因预存 iCloud Trash 文件未做到空结果，详见 `FAILURES.md` 和 `evidence/m4/`

## 相对原 `doubao-murmur` 的改动摘要
- UI 与交互：重做底部 HUD 悬浮窗，加入 `.hudWindow` 材质、弹性宽度、RMS 驱动 5 柱波形、`Refining…` 旋转态、单行无闪烁文本更新
- 快捷键系统：实现 `Right/Left Option`、`Right/Left Command`、`Right Control`、`Caps Lock`、`Fn` 可配置触发键，以及 `Hold`、`Single Tap Toggle`、`Double Tap Toggle` 三种模式和热重载状态机
- LLM 润色层：新增 `General / Shortcut / LLM 润色` 三栏设置页，`URLSession + AsyncSequence` 流式 `chat/completions` 调用，Keychain 存 API Key，UserDefaults 存可编辑 Prompt/Model/Base URL/Timeout，失败时原文兜底不丢字
- 分发与运维：补齐 `Makefile`、`scripts/release.sh`、`.dmg` 打包、GitHub Release Action、应用内检查更新、完整卸载、`os.Logger + 文件日志`、自动化验收脚本与 `evidence/` 产物

## 已知限制
- 这次是无人值守连续交付，未执行人工豆包网页登录，也未走首次 Microphone / Accessibility 权限弹窗；M1 基线验证使用了自动化 mock 路径而非真人登录链路
- 当前机器只有 Command Line Tools，没有完整 Xcode；构建链使用 `xcodegen + swiftc`，未跑 `xcodebuild`
- 为避开桌面 iCloud 同步目录附带的签名污染，`build/` 是指向 `~/.voiceinput-build` 的符号链接
- 里程碑 tag 会作为本次最终交付快照的标记创建，因为本次任务按用户要求是一次性连续执行，没有中途冻结历史提交

## 用户下一步建议
- 先看 `evidence/`、`SUMMARY.md`、`FAILURES.md`，然后手动跑一次真实豆包登录和首次权限授权
- 如果要接 GitHub 发布，把 `AppEnvironment.githubRepoOwner` / `githubRepoName` 对到你的正式仓库，再推送 `v*` tag 验证 Release Action
- 如果要长期分发，建议下一步补 Developer ID 签名与 notarization；当前仅做 ad-hoc 签名
