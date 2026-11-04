# build 41：问问 AI 通用 agent

问 AI 使用顺序消息流，同一个输入框可连续提问；显示用户、AI 和工具执行消息。保留改文字的编辑、版本与原输入框交接逻辑。紫色中／英菜单里的「问问 AI…」仍可直接打开。

## 工具对照

参考 `~/dev/code/loongmate/rust/crates/tools/src/agent_policy.rs`、`tool_manifest/schema_base.rs`、`file_tool.rs`、`shell_tool.rs` 与 `web_tool.rs`。当前对齐通才核心本机能力，不依赖或启动 LoongMate。

| 能力 | 方寸工具 |
| --- | --- |
| 读取、创建和覆盖文本文件 | `read_file`、`write_file` |
| 精确修改 | `edit_file`，多处匹配需 `replace_all` |
| 文件及内容搜索 | `glob_search`、`grep_search` |
| 命令执行、后台状态、stdin、停止 | `shell_exec`、`shell_io`、`shell_manage` |
| 网页读取和搜索 | `WebFetch`、`WebSearch`（DuckDuckGo HTML） |

平台专属任务编排、子 agent、插件注册、Notebook/REPL 工具未移植。模型可通过 shell 使用已安装的本机程序。文件工具以 UTF-8 文本为主，无图片视觉消息或 PTY。

目录默认用户主目录，可在问 AI 页面选择。相对路径按该目录解析；绝对路径和 `~` 可访问其他用户有权限的目录。目录是路径基准，不是沙箱。停止和新建对话会终止当前对话的命令组，已经完成的文件修改保留。

## 协议与生命周期

使用现有兼容接口的 `stream: true`、`tools`、`tool_choice: auto`。逐个 SSE 帧合并文本及按 index 分片的工具 ID、名称和参数；只有完整且明确结束的模型响应才可执行工具。同轮多个调用按顺序执行，每个结果以 `role: tool` / `tool_call_id` 回传。随后继续调用模型，直至回答完成或达到 16 轮 / 48 次工具上限。上限或错误后可点击继续。

未知工具、无效参数、文件或网络错误作为失败工具消息返回，模型可修复。停止时取消网络、终止命令组、标记未完成消息；下一轮先检查中断操作的实际状态。模型和服务切换要求新建对话；归档保存原服务身份，避免无意发送旧会话到另一服务。模型认证接口不跟随重定向；网页工具不携带模型 Key。

生成期间可以输入下一条草稿，输入不会取消当前 agent。切换编辑模式、隐藏窗口或配置变化会停止当前请求。新建对话清除消息，输入草稿保留。「上次内容」归档含消息与工作目录。只有完成的 AI 回答或其中选区可上屏；用户消息、工具结果和部分回答不会误上屏。

## 验证

离线：`FANGCUN_EDITOR_TEST=AgentTests ./scripts/editor-test.sh`，40 项通过，使用本机假服务及临时目录。覆盖 SSE 多字节分片、多轮/多工具、真实文件修改和 Shell stdin、工具错误恢复、上限、取消、接口重定向、消息界面与归档。AIActionTests 44 项通过，验证原生消息输入及改文字的修改、撤销、版本、归档和选区上屏。EditorTests 160 项通过。测试应用按 suite 使用独立 bundle ID；EditorTests 明确初始化英语动作，并按请求完成状态等待，避免跨 suite 首选项污染及固定 500ms 等待导致的偶发失败。StatusAIEntryTests 14 项通过，包括状态菜单打开、未确认拼音保护、独立会话显式绑定及宿主上屏；焦点交接同样按完成状态等待。CoreTests 1059 项通过。

真实模型探针需显式启用：`FANGCUN_AGENT_LIVE=1 ./scripts/agent-live-test.sh`。仅在独立临时目录进行文件写入、读取和 `printf`，不输出 Key 或请求内容。2026-10-24，已配置的 `api.deepseek.com / deepseek-flash` 通过流式回答、3 个工具调用和最终回答验证。

本机已安装 build 41，签名校验通过，安装二进制与构建二进制 SHA-256 一致。重新选中方寸后，系统仅有 `.Hans` 一个可选入口。
