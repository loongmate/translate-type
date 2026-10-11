# 编辑区焦点与上屏恢复 · build 18

日期：2026-10-11。

## 用户可见问题

原文已经完成选词，仍显示「已切换输入框」，原文与英文上屏都变灰；点击「确认当前光标」只让用户再点原输入框，不能恢复。这个提示由程序自己的目标校验产生，不能据此断定 macOS 禁止浮窗上屏。

macOS 提供 `NSPanel.nonactivatingPanel`，允许浮窗取得键盘焦点而不激活所属应用；本工程在 build 16 已使用该窗口类型。编辑器需要键盘焦点，原输入框仍要通过 IMK 客户端维持独立的提交目标。参考 [Apple 非激活面板](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)、[面板键盘焦点](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)、[每个输入会话对应一个 IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)。

## 本轮修复

- 排除输入法自身设置窗口和内部客户端的激活通知，过滤不相关的后台应用通知，避免将原目标标成另一个输入框。
- 每个 IMK 控制器持有稳定的会话 ID。对于没有唯一客户端标识的代理更新，按会话识别并更新代理，仍检查选区和邻近正文；不再仅依赖代理对象的内存地址。
- 不同会话即使内容与选区完全相同，也不会自动成为新的提交目标。显式点击「使用当前输入位置」，才将目标切到最近观察到的外部输入框，并真正重建光标锚点。
- 原输入框只移动了光标时，「确认当前光标」同样更新锚点并恢复按钮；不再陷入只显示提示的循环。
- 编辑区独立持有合成会话。重新绑定、缩回候选窗时，将该会话交给新输入控制器；旧控制器继续打字不会共用或改变编辑草稿。
- 处理没有选词内容时的零长度预编辑范围。某些 AppKit 客户端返回有效位置加长度 0；旧实现会发送空预编辑更新，误删已有选中文字。现在只有存在实际预编辑内容时才清空，打开编辑区保留原选区，直到明确上屏时替换。
- 完成上屏后即使系统没有重新发送激活回调，首次 Shift 轻按仍可切换英文。

快捷键保持：Ctrl + Shift + Enter 打开；Ctrl + Enter 翻译；Cmd + Enter 上屏译文或原文；Cmd + Shift + Enter 明确上屏原文。

## 验证

`./scripts/editor-test.sh` **93 项通过**，在 build 17 的 71 项基础上新增 22 项。使用真实 Rime、AppKit 文本视图和 IMK 控制器，模拟代理替换、内部客户端激活、跨会话切换、标识变化、重新绑定后的缩放，以及原选区保持；同时检查原生面板的非激活属性与打开前后前台应用未被主动切换。

新增测试曾复现「零长度预编辑清空选区」失败，修正后回归通过。测试不将文本内容恰好相同的两个输入会话视为同一个输入框。

`./scripts/controller-test.sh` 另外 **33 项通过**，覆盖常规中文上屏、Shift、混输、候选导航以及八种方案的翻页。`./scripts/build.sh` 构建完成，产物版本号为 18，深度代码签名检查通过。

日志：`.build/build18-editor-tests.log`、`.build/build18-controller-tests.log`、`.build/build18-build.log`。

本轮自动检查不等于外部应用完整验收：测试通过程序调用原生控件，不向用户应用发送自动键盘事件。需在实际输入框验证打开、确认目标和上屏；如果按钮恢复后客户端仍拒绝接收，需要继续调查该应用的 IMK 会话，不应把构建成功当作已经解决。

## 本机状态

用户明确要求重新安装后，已通过 `scripts/install.sh` 安装并启动 build 18。已核验安装版本号、已安装二进制与构建产物完全一致、深度代码签名有效，且仅运行一个输入法进程。系统注册结果显示「方寸输入法」已启用并可选择。安装保留了用户当前选择的系统简体双拼，未强制切换输入法。

安装日志：`.build/build18-install.log`。用户随后实际反馈仍无法上屏，截图仍出现目标位置变化提示。本版的模拟客户端测试未覆盖 IMK 文档访问缺失和不稳定标识，不能认为已解决。后续调查与修正见 [build 20 客户端兼容性](editor-client-compatibility-build20.md)。
