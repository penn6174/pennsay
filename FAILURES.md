# FAILURES

## M4 卸载并退出：字面 `find ~/Library ...` 结果仍非空
- 项目：`find ~/Library -iname "*doubaomurmur*" -o -iname "voiceinput*"` 为空
- 状态：非阻塞
- 实际结果：`evidence/m4/uninstall-find.txt` 仍命中 `~/Library/Mobile Documents/.Trash/doubao-murmur/DoubaoMurmurApp.swift`
- 已确认清理完成：`/Applications/VoiceInput.app`、`~/Library/Application Support/DoubaoMurmur/`、`~/Library/Preferences/com.voiceinput.app.plist`、`~/Library/Logs/DoubaoMurmur/`，以及由应用自身写入的 `DoubaoMurmur / VoiceInputLLMAPIKey` Keychain 项
- 尝试过的修复 1：移除 `AppEnvironment` 在读取路径时自动创建目录的副作用，避免卸载后重建日志目录
- 尝试过的修复 2：将构建输出从 `~/Library/Caches/VoiceInputBuild` 改到 `~/.voiceinput-build`，避免 `find ~/Library ...` 把构建缓存误判为残留
- 尝试过的修复 3：新增 `VOICEINPUT_AUTOMATION_AUTO_UNINSTALL=1` 自动化入口，重跑应用自身的卸载与 Keychain 删除链路
- 残留问题：iCloud Trash 中的旧 `doubao-murmur` 文件不属于当前应用安装路径，但会被该字面 `find` 命中
- 是否阻塞后续 milestone：否
