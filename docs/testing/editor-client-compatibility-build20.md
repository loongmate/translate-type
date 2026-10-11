# 编辑区上屏：IMK 客户端兼容性 · build 20

日期：2026-10-11。

## 问题与证据

用户实际使用 build 18 后，编辑区仍显示「输入位置已变化」，原文上屏不可用。build 18 的通过记录不能视为外部应用验收通过。

再次检查发现，原测试客户端始终返回固定标识、完整文档长度和有效选区，掩盖了两处实现缺陷：

1. `uniqueClientIdentifierString()` 被反复调用并直接用作稳定的输入框标识。Apple SDK 将它描述为 `NSProcessInfo.globallyUniqueString` 的包装，代码没有验证连续返回值是否稳定。新增每次返回新字符串的客户端后，旧代码立刻复现错误：刚创建目标就报「原输入位置已变化」，同一会话也无法上屏。
2. `selectedRange()`、`length()` 与文本查询可能返回 `NSNotFound` 或 nil。SDK 明确要求输入法处理不支持文档访问的客户端。旧代码将这些结果当作无效光标或文本变化，导致「确认当前位置」重新捕获后依然无效。

依据是本机 Apple SDK 的 `Carbon.framework/Frameworks/HIToolbox.framework/Headers/IMKInputSession.h`：`selectedRange`、`length`、`attributedSubstringFromRange`、`uniqueClientIdentifierString` 和 `insertText:replacementRange:` 的说明。它还说明 `length()` 可能昂贵，应避免频繁查询。

这些是已复现的实现缺陷；尚未取得用户失败现场的真实代理诊断，因此没有把其中某一项武断地写成截图的唯一根因。

## 修正

- 对标识先连续读取验证稳定性；变化的字符串不作目标身份凭证。同一 IMK 控制器的会话 ID 仍用于识别会话；两个不同会话不会因都缺少稳定标识而被合并。
- 区分「查询不支持」与「已确认发生变化」。只比较能获得的选区和附近正文，不把 `NSNotFound` 当成文档长度，也不把 nil 当成正文被清空。
- 能读到的选区变化、正文变化、稳定客户端标识变化，以及不同应用/会话切换，仍然触发目标恢复流程。
- 上屏通过正常 IMK `insertText` 的当前插入点协议，使用 `{NSNotFound, NSNotFound}`，不依赖应用支持任意位置替换，不使用剪贴板或发送键盘事件。
- 不再每 500 毫秒轮询完整文档长度。在捕获位置与提交时检查；提交时若发现长度变化，保留草稿并显示可恢复的原因。
- 即使宿主不提供预编辑范围，也根据自身已有合成状态清除宿主预编辑，再把拼音带入编辑区。空草稿仍不清除宿主原有选中文字。

当宿主不提供任何文档查询时，无法承诺检测到同一输入会话中所有内部光标变化；系统输入会话与前台应用仍必须匹配。这是协议能力边界，不能伪造完整文档校验。

## 验证

- 旧代码新增兼容性用例失败，日志 `.build/build19-compatibility-before.log`。
- 修正后编辑区 **107 项通过**，新增 14 项覆盖动态标识、不可读文档、部分查询能力、查询能力暂时消失、内容长度变化、恢复光标、不可读预编辑范围，以及真实 Rime 选词后的快捷上屏。日志 `.build/build20-editor-tests.log`。
- `Tests/IMKProbe.swift` 创建独立测试宿主，通过自身 `NSTextInputContext` 尝试真实系统连接，不控制用户应用。不具备系统键盘焦点时跳过，不能计为通过；本轮宿主未取得焦点，因此没有完成跨进程上屏验收。
- 常规控制器回归 **33 项通过**，日志 `.build/build20-controller-tests.log`；与编辑区检查共 140 项。构建完成，已安装并启动 build 20；核对版本号、安装二进制与构建产物一致、深度代码签名有效，且仅运行一个输入法进程。构建及安装日志：`.build/build20-build.log`、`.build/build20-install.log`。
- 本次安装保持原先的 ABC 输入源。实际测试编辑区需切到「方寸输入法」。`.build/build20-imk-probe.log` 明确记录系统焦点测试为 SKIP；尚无用户真实失败现场的诊断，不将 140 项检查表述为外部应用上屏已通过。

## 本地诊断

build 19 用于采集状态，build 20 保留同一诊断机制。文件为 `~/Library/Logs/FangCun/editor-focus.jsonl`，限制为当前与前一份各约 128 KiB，权限 0600。只记录版本、应用标识、会话随机 ID、范围和长度、标识是否稳定、拒绝原因与提交调用；不记录输入正文、译文、按键、剪贴板或 API Key。

`commit-dispatched` 只表示已调用 IMK 提交，不能当成目标应用已接收的证明。

后续用户提供了实际复现。日志确认标识不稳定与文档长度不可用，同时暴露了捕获清除前旧选区和隐式带回草稿的问题。详见 [build 21 焦点交接](editor-handoff-build21.md)。
