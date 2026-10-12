# 方寸输入法 · FangCun

macOS 原生输入法：离线中文拼音 + 用户主动触发的整句中英翻译。使用 Swift、AppKit、InputMethodKit 与 Rime；没有网页主界面。

## 下载预览版

[0.1.0-beta.1（build 22）](https://github.com/loongmate/translate-type/releases/tag/v0.1.0-beta.1) 分别提供 Apple Silicon（M 系列）和 Intel 版本，目标系统为 macOS 13+。下载页包含安装方法、校验值和已知限制。

此预览版尚无 Developer ID 签名或 Apple 公证，首次打开可能需要在「系统设置 → 隐私与安全性」中点击「仍要打开」。本版采用手动安装；实测环境为 Intel / macOS 14.7.4，Apple Silicon 尚待真机验收。详见 [安装与发布说明](docs/releases/v0.1.0-beta.1.md)。

## 本机构建和安装

需要 macOS 13+、Xcode Command Line Tools 和 Python 3。当前开发验证机器为 macOS 14.7.4 / Intel。

```sh
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
./scripts/install.sh
```

安装到 `~/Library/Input Methods/FangCun.app`。安装程序注册并尝试启用输入源；若菜单中暂未显示，请在「系统设置 → 键盘 → 文本输入 → 编辑 → ＋ → 简体中文」中添加「方寸输入法」。首次安装可能需要重新登录；应用启动或注册接口成功不代表系统文本会话验证已通过。

安装程序只停止本工程已安装的输入法进程，更新时将旧应用保存在 `.build/*-previous-*.snapshot`，不移除其他输入法。安装时会注销工程构建副本在 Launch Services 中的登记，避免系统启动错误路径。

## 使用

- 默认中文模式：全拼打字，空格或数字选词，中文直接上屏。支持连续整句全拼、`nv/lv` 和隔音符号。
- **双拼**：设置 → 输入 → 拼音输入方式选「双拼」，再选方案。支持搜狗、小鹤、自然码、微软、智能 ABC、拼音加加、紫光；也可从系统输入法菜单的「拼音方案」切换。自动保存，不需要填写模型配置。若有未选完的拼音，会在这段选完后切换，已确认的译英草稿保留。详细键位样例和验收见 [双拼使用与验收](docs/testing/double-pinyin-build13.md)。
- 拼音中可以直接夹英文：`tuopanlidelogo` → `托盘里的logo`，`woyaoxiugaibug` → `我要修改bug`。中英重码时提供候选，例如 `women` 优先显示「我们」，也可选择英文。
- **Shift** 单独轻按切换中英文直输；长按、配合字母、快捷键或鼠标操作不会切换。切换到其他输入法再返回方寸时默认中文，保留所选拼音方案。系统输入菜单图标随普通输入框的模式显示「方」或「英」。候选窗显示当前方案简称或「EN」，点击也可切换中英文。英文直输保留半角标点。
- 有未选词的拼音时 **Enter** 原样输入字母，不将 `logo` 改为中文或添加显示用的分隔空格。
- 开启候选窗中的「译英」，或按 **Ctrl + Shift + E**：中文选词后暂存在预编辑区。
- **Ctrl + Enter** /「翻译整句」：选词全部完成后，主动翻译整段草稿一次。只要还有未确认的输入，快捷键不执行翻译，按钮显示「先完成选词」并禁用；拼音、候选和光标位置全部保留。
- 翻译完成后 **Enter** / 空格：确认英文上屏。数字 **2** 可选择中文原文。
- **Esc**：从翻译结果返回中文修改；再次按 Esc 清空预编辑区。
- 译英模式没有未选词拼音、尚未有英文结果时，**Enter** 可直接原文上屏。需要多段换行时，使用临时编辑区。
- **Ctrl + Shift + Enter**：打开原生临时编辑区，也可点击候选窗的放大按钮或系统输入法菜单「临时编辑区…」。在「设置 → 输入」中点击快捷键可修改。快捷键在方寸输入法处于当前输入源时生效。
- **临时编辑区**：支持全拼、七种双拼、英文混输、选区替换、粘贴、撤销和长文滚动；空格继续选词，选词完成后 Enter 换行，Ctrl + Enter 主动执行动作。未选完的拼音会随放大保留，仍需完成选词才能翻译或上屏。译文可直接修改，通过「原文上屏」或「英文上屏」一次写回原输入框。
- 编辑区默认「改文字 → 翻译成英语」，支持德语、提取约定、自然改写和自定义动作；第二页「问 AI」支持参考文字、追问和回答版本。动作可以设置名称、`/key` 和特殊指令；详见 [原生 AI 动作使用与验收](docs/testing/ai-actions-build22.md)。
- 编辑区内 **Cmd + Enter 快捷上屏**：提交修改后的结果，有选区时仅提交选中部分。改文字模式在尚未生成结果时可直接提交原文；旧结果失效时不会误提交。**Cmd + Shift + Enter** 在改文字模式明确上屏原文。问 AI 不会把问题自动插回输入框。未完成选词时不提交；请求期间等待结果。
- 编辑区内 **Esc** 优先取消当前未确认拼音；无待选输入时保留并收起。关闭窗口或 **Cmd + W** 只收起草稿，再次用快捷键继续；上屏后可点「上次内容」再次取用回答；草稿暂存在本次输入法进程内。原应用、输入框或光标发生变化时先保留草稿，需要返回原输入框或确认新光标，再上屏。
- 拼音末尾按右键选择下一个候选，按左键回到上一个候选，可连续跨页。回到全局第一项后再按左键，才进入拼音编辑；此时左右键逐字移动光标，移回末尾后再按右键继续选词。空格确认当前高亮项；上下键仍可选择候选。
- 有拼音候选时，**`-` 上一页，`=` 或 `+` 下一页**，也支持 Page Up / Page Down 和数字键盘加减号；首末页停住，不循环、不确认文字。无候选、已选完的译英草稿或英文直输时，这些符号正常输入。全拼、双拼均支持。
- 长候选完整显示并自动换行。超长拼音、中文草稿和译文可在窗口内滚动查看；拼音光标和高亮候选自动保持可见。
- 从候选窗齿轮或系统输入源菜单打开「设置」。输入方案在「输入」页，模型、API Key、英语翻译偏好在「AI」页。也可打开已安装应用。

菜单栏只使用 macOS 系统输入法菜单；方寸中文模式显示「方」，英文直输显示「英」，应用不再创建独立的托盘图标。可从系统输入法菜单或候选窗齿轮打开设置，也可直接打开已安装应用。设置窗口打开时，方寸输入法会出现在 Dock 和 Cmd + Tab 应用切换器；关闭设置窗口后回到菜单栏运行。重新打开已有窗口会保留尚未保存的输入内容。设置顶部展示系统实际可选的输入源状态；注册接口返回成功不代表已启用。

打字、选词、输入标点或停顿均不调用模型。请求期间阻止重复触发；修改中文、切换输入源或离开文本会话会取消请求，过期响应无法上屏。失败保留原文，不自动重试。当前会话中相同句子和配置可复用最近译文。

## 模型配置

支持 OpenAI-compatible Chat Completions 接口（`POST /chat/completions`，非流式文本返回）。填写基础地址和服务中的模型 ID，例如本地 Ollama 的 `http://localhost:11434/v1`。远程服务使用 HTTPS，本机地址可用 HTTP。

DeepSeek 官方接口明确发送 `thinking: {type: "disabled"}` 关闭思考模式，通用兼容服务不附带这个专属参数。连接可复用，减少重复建立连接的等待；测试翻译显示实际耗时。

API Key 按服务地址分别保存在 macOS 钥匙串，普通配置存入应用偏好。切换服务地址会清空设置窗中的旧密钥，避免误将旧服务的凭据发送到新地址。请求禁止重定向。

「特殊指令」为空或仅空白时使用默认翻译规则：保留原意、人名及术语，只返回一条自然英文，不带解释。提供自然口语、商务礼貌、简洁直译预设，选择后可以继续修改。特殊指令附加在默认翻译规则后，随下一次整句请求发送；修改指令本身不调用模型。

「测试翻译（调用 1 次）」会真实请求所填服务，用一条示例验证连通性；保存和选择预设不会产生请求。当前没有内置付费密钥或内置大模型，真实翻译需要用户配置可用的服务。

## 验证

build 26 加入已上屏上下文的读取与验证工具，尚未启用候选重排。原生 AppKit / WebKit 固定场景的跨进程读取 19 项匹配，读取边界检查 24 项通过；正式构建不包含诊断监听器。宿主兼容性边界和「上 + hai」的排序设计见 [上下文候选能力验证](docs/context-aware-candidates.md)。

build 25 修正 build 24 将英文模式对系统界面隐藏的配置；中文和英文使用同一输入法的两个可见模式及各自图标，仍只有一个系统菜单栏位置。`./scripts/mode-icon-test.sh` 检查模式、图标文件和菜单栏的辅助功能描述；没有辅助功能权限时明确跳过界面检查。它不检查菜单栏像素。详见 [中英文图标验收更正](docs/testing/mode-icon-build25.md)。

build 23 修复临时编辑区保留草稿时，回到原输入框先按 Shift 无法切英文的问题，并兼容重复的 Shift 修饰键通知。详见 [Shift 切换回归](docs/testing/shift-switch-build23.md)。

build 22 将原型的「改文字 / 问 AI」接入原生编辑区，复用已修复的宿主上屏流程。详见 [原生 AI 动作与问答](docs/testing/ai-actions-build22.md)。

完整输入规则、各种输入形式、易用性任务和失败记录见 [输入行为与易用性验收](docs/input-behavior-and-usability.md)。build 11 存在失焦丢掉未选尾部、部分选词被还原成拼音、草稿光标编辑不正确等问题，尚未通过日常使用验收。下面的既有回归测试通过，不代表这些缺口也已通过。

build 12 按用户确认的规则修正左右键候选导航，覆盖跨页、首项后编辑拼音、回到末尾继续选词、空格确认高亮项和未选完时禁止翻译，详见 [候选导航专项验收](docs/testing/candidate-navigation-build12.md)。

build 13 加入七种双拼。`./scripts/double-pinyin-test.sh` 使用真实 Rime 验证键位、零声母、分号韵母、英文混输、两种输出模式和方案切换；`./scripts/controller-test.sh --capture-settings .build/build13-settings` 还验证设置表单的真实操作并生成两页预览。完整全拼和模拟翻译回归仍使用 `./scripts/test.sh`。

build 14 补齐 `-` / `=` / `+` 候选翻页。`./scripts/paging-test.sh` 覆盖八种拼音方案、首末页和分段选词，控制器测试同时覆盖主键盘与数字键盘，见 [候选翻页验收](docs/testing/candidate-paging-build14.md)。

build 15 修复长候选被截断和超长内容不可完整查看的问题。`./scripts/panel-test.sh` 检查原生窗口换行、滚动、光标跟随及完整上屏，并生成渲染图，见 [长候选与窗口显示验收](docs/testing/long-candidates-build15.md)。

build 16 加入原生临时编辑区、可修改的打开快捷键、共享 Rime 草稿和原输入位置校验。`./scripts/editor-test.sh` 验证原生编辑、候选迁移、段落选区、粘贴撤销、七种双拼、译文修改、取消请求以及上屏；本轮 56 项编辑区检查和 333 项既有回归通过。详见 [临时编辑区使用与验收](docs/testing/temporary-editor-build16.md)。整段翻译最多 20,000 字，超过 4,000 字的请求等待时间提高至 90 秒；实际容量和速度仍取决于配置的模型服务。

build 17 增加编辑区快捷上屏和可见的按钮快捷键提示，原生编辑区与 HTML 原型同步。编辑区测试共 71 项通过，其中新增 15 项检查覆盖快捷上屏、重复事件、翻译中保护和剪贴板保持，见 [快捷上屏验收](docs/testing/editor-commit-build17.md)。

build 18 修复编辑区目标被自身窗口或客户端代理变化误判、确认按钮不能真正恢复目标的问题，并补齐重新绑定后的草稿归属及零长度预编辑对选区的保护。编辑区测试共 93 项通过；安装状态与真实应用验收边界见 [编辑区焦点与上屏恢复](docs/testing/editor-focus-build18.md)。

build 18 的真实使用仍未通过。后续 build 20 处理 IMK 客户端标识不稳定、文档访问返回 `NSNotFound` / nil，以及不可读预编辑范围；编辑区测试扩充为 107 项，包含先复现失败再修正的回归。诊断依据、安装状态和真实应用验收边界见 [客户端兼容性调查](docs/testing/editor-client-compatibility-build20.md)。

build 21 根据真实客户端日志调整编辑区焦点交接：等宿主清除预编辑后再显示编辑区，先收起编辑区再上屏；重新绑定光标只更新目标，普通打字不再自动带出草稿。124 项编辑区检查通过，新增 17 项异步客户端回归。详见 [焦点交接调查与回归](docs/testing/editor-handoff-build21.md)。

`./scripts/audit-input.sh` 和 `./scripts/audit-client.sh` 跑完整输入审计并输出 JSON。已知缺陷仍按失败返回非零状态，不将现有错误行为当作正确结果；本轮记录见 [逐项结果](docs/testing/input-audit-results.md)。

`./scripts/test.sh` 使用真实 Rime 引擎与钥匙串，并启动只监听本机的测试 HTTP 服务。覆盖中文上屏、译英暂存、调用次数、重复触发、缓存、特殊指令、取消陈旧结果、失败回退、响应错误及重定向。测试服务不属于产品翻译功能。

`./scripts/native-test.sh` 是系统会话验证工具：选择方寸输入法输入源，在它自己的 AppKit 文本窗口输入 `nihao` 并确认，检查真实客户端输出是否为 `你好`，随后恢复原输入源。系统启用成功后才能通过该检查；测试普通拼音功能不需要 API Key。

当前本机验证：构建、安装、离线全拼、中英混输与模拟服务的翻译流程测试已通过；用户已确认安装修复版后，`nihao` 加空格可以正常出现中文。控制器与实际 AppKit 文本视图的集成测试已通过，覆盖中文确认上屏、Shift 切换与组合操作、中英混输、切换输入源后恢复中文和译英草稿。本机已合并重复安装，保留系统已有且已启用的注册记录，名称为「方寸输入法」；只有一个安装目录和进程。真实 DeepSeek 短句翻译成功，响应没有思考内容，本机单次测试总耗时约 14.7 秒；这不是稳定延迟保证。系统级文本探针需要 macOS 自动按键权限；本机缺少权限，已明确跳过，不能将程序内合成事件输出的字母当作真实按键测试结果。

`swift Tests/IconProbe.swift` 检查系统注册的名称与图标 URL，并通过 AppKit 实际绘制图标。它验证注册信息和资源，不能代替系统菜单的实际显示验收。`scripts/input-sources.sh` 展示新旧输入源状态，`current` 展示当前输入源。

## 代码

- `Sources/RimeBridge.m`、`PinyinEngine.swift`：真实拼音引擎与独立会话。
- `Sources/CompositionSession.swift`：组句、请求、取消及上屏状态。
- `Sources/InputController.swift`、`CandidatePanel.swift`：系统文本客户端与原生浮动候选窗。
- `Sources/DraftEditor.swift`、`InputKey.swift`：原生临时编辑区、目标输入框校验及快捷键。
- `Sources/TranslationClient.swift`：兼容接口、超时及错误处理。
- `Sources/Configuration.swift`、`SettingsWindow.swift`：配置、特殊指令与钥匙串。
- `design/index.html`：保留的静态设计稿。

更名保留系统已启用的稳定标识 `com.translatetype.inputmethod.TranslateType` 及其 `.Hans` 模式，只更新展示名称；内部标识不显示为产品名。升级备份原安装，在启用验证成功后清理误创建的第二套安装，验证失败时恢复原安装。

模型配置、特殊指令与译英开关统一使用 `com.fangcun.inputmethod.FangCun` 偏好域，缺省值从原偏好迁移；钥匙串服务和词库路径保持兼容。

`./scripts/controller-test.sh` 使用实际 IMK 控制器、Rime 和 AppKit 文本视图，验证中文上屏、中英切换、Shift 组合键、切换输入源后的中文恢复和译英草稿。它与系统事件投递测试分别验证不同环节。

Rime 数据保存在 `~/Library/Application Support/TranslateType/Rime/`。日志不主动记录待翻译原文、译文或密钥。

## 依赖与许可

Rime 1.17.0 从官方 release 下载，校验 SHA-256；其许可证随应用资源保留。简体拼音词库来自 rime/rime-pinyin-simp，固定 Git blob `6f2e996d2792416cb7f41bb49967a1dec7060c92`，保留原文件声明。候选窗使用 macOS 系统图标。中文基础词库及英文词汇来自 iDvel/rime-ice，固定中文 Git blob `f1e253ea14ad035198f66b449c83217131184775` 与英文 Git blob `54b596853133044a02216f7131f628c55797b604`。英文编码归一化为小写以用于全拼混输；原始说明和 GPL-3.0 许可证随资源保留。`scripts/prepare-vocabulary.py` 可重建并校验词库。

双拼键位采用 iDvel/rime-ice 的七种方案，固定提交 `da1fbe602e38f26db846fa10120ee64c2b0324c0`，保留 GPL-3.0 许可证。来源文件、校验摘要和拼写规则见 `scripts/double-pinyin-layouts.json`；`scripts/prepare-double-pinyin.py` 离线生成适配方寸的方案。各双拼方案使用独立的键位索引，共享双拼词库；英文编码在双拼转换后恢复原码，避免被当作中文韵母转换。

参考：[Apple InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)、[Rime API](https://github.com/rime/librime/blob/master/src/rime_api.h)、[简体拼音词库](https://github.com/rime/rime-pinyin-simp)。

当前使用本机临时代码签名，适用于开发验证；外部分发时需正式签名和公证。

## 发布准备

先编译两种架构：`FANGCUN_ARCHS='x86_64 arm64' ./scripts/build.sh`，随后运行 `./scripts/package-preview.sh`，分别生成 **Apple Silicon 版（M 系列，arm64）** 和 **Intel 版（x86_64）** 两个预览 ZIP，各自带安装说明和 SHA-256。每个包的应用与 Rime 引擎均只保留对应架构。预览包尚未正式签名、公证，Apple Silicon 仍需实机验收。

安装器、Developer ID、公证、升级和首次发版步骤见 [发布方案](docs/distribution.md)。
