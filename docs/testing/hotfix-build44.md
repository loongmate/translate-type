# build 44：中文标点与设置自动弹窗修复

日期：2026-11-05。环境：Intel / macOS 14.7.4。

## 修复范围

中文标点不再经过将待选拼音转为原文字母的分支，而由 Rime 确认当前高亮候选并提交对应中文标点。补充方括号、书名号及成对双引号；不使用分号编码的双拼方案从 speller 字母表中移除分号，保留搜狗、微软、紫光的分号编码。

后台启动和普通 reopen 回调均不再主动显示设置，也不因输入源发现暂时延迟而弹窗。菜单和显式 `--settings` 入口保留，新增 `fangcun://settings` 供安装器明确打开设置；该入口也可作用于已经运行的输入法服务。AppDelegate 单独成文件，便于直接验证真实生命周期回调。

## 功能回归

以下检查在本次修复代码上通过：

- `./scripts/punctuation-test.sh`：2,304 个待选输入用例、11,699 项断言，覆盖八套方案、三种输入场景、32 种 ASCII 符号，以及高亮移动和翻页后的标点确认。
- `./scripts/test.sh`：913 项核心输入与模拟服务检查。
- `./scripts/double-pinyin-test.sh`：179 项双拼检查。
- `./scripts/controller-test.sh`：116 项检查，使用实际 IMK 控制器、Rime 和 AppKit 测试文本客户端。
- `./scripts/editor-test.sh`：149 项检查，包含选区内拼音接标点及保留前后草稿。
- `FANGCUN_EDITOR_TEST=AppLifecycleTests ./scripts/editor-test.sh`：13 项检查，直接调用生产 AppDelegate 回调，并切换实际 IMK 测试客户端；验证普通 reopen、激活通知、输入源通知不弹设置，显式入口仍可打开设置。
- `./scripts/installer-test.sh`：28 项安装事务与原生界面检查。

生命周期检查不模拟物理键盘或宣称已经在反馈问题的用户电脑上复现全部系统事件；输入法切换和应用切换仍需用户实际复测。上述检查不请求真实模型服务。

## 发布包验证

以 `FANGCUN_ARCHS='x86_64 arm64' ./scripts/build.sh` 构建，再为两个芯片分别打包。输入法、安装器和 DMG 逐层签名、公证并附加票据。最终检查包含：

- DMG 完整性、SHA-256、严格签名验证及 Gatekeeper 评估。
- DMG 内安装器和 payload 的版本均为 build 44，最低系统版本为 macOS 13.0。
- 每个包的安装器、输入法程序及 Rime 动态库均只包含对应单一架构。
- 两个包的 payload 资源与本次构建完全一致，显式设置链接包含在应用声明中。
- 使用生产 InstallTransaction 在临时目录复制、重命名实际发布 payload 后，签名和公证票据仍有效。

结果记录在本机 `.build/build44-dmg-verification.json`、`.build/build44-*-release-copy-test.log` 及 `.build/notary-build44-*.json`，不提交签名或公证凭据。

Apple Silicon 仅完成交叉编译及包检查，尚无真机运行结果；macOS 13 和全新用户账户首次安装也尚待实机验证。本次更新沿用 beta.3 的用户级安装、备份、回滚和输入源发现延迟处理。
