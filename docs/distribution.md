# 方寸输入法发布方案

调查日期：2026-10-11。第一版按预览版发布到 GitHub Releases，分别提供 **Apple Silicon 版（M 系列芯片）** 和 **Intel 版**，版本为 `0.1.0-beta.1`。本版保留开发签名，Developer ID 和 Apple 公证后续补齐；用户在系统设置中为该应用确认“仍要打开”。下载与安装说明见 [预览版发布说明](releases/v0.1.0-beta.1.md)。

## 当前具备什么

- 源码、原型、测试和说明已推送至 `loongmate/translate-type` 的 `main` 分支。
- 产品版本为 `0.1.0`，应用 build 为 `22`。已有功能回归 489 项通过，真实宿主上屏也已经过用户确认。
- 构建脚本支持 `x86_64 arm64` 双架构，Rime 官方动态库本身已包含两种架构。最低系统版本从 `Info.plist` 读取，传递给 C 和 Swift 编译器，避免声明 macOS 13、实际却默认编译到 macOS 14。
- 双架构应用仅作为构建中间产物。预览打包脚本分别提取 `arm64` 与 `x86_64`，应用主程序和 Rime 库都裁剪为对应的单一架构，重新签名、验证，生成两个 ZIP 和各自的 SHA-256；不安装、不上传、不公证。
- 本机没有可用的代码签名证书。现有签名为 ad hoc 开发签名，不是 Developer ID。

```sh
./scripts/bootstrap.sh
FANGCUN_ARCHS='x86_64 arm64' ./scripts/build.sh
./scripts/package-preview.sh
```

输出如下，每个 ZIP 包含对应架构的应用与安装说明：

| 下载版本 | 架构 | 本轮大小 | 本地文件 |
| --- | --- | --- | --- |
| Apple Silicon 版 · M 系列 | arm64 | 9,075,718 字节 | `dist/FangCun-0.1.0-build22-AppleSilicon-preview.zip` |
| Intel 版 | x86_64 | 9,208,235 字节 | `dist/FangCun-0.1.0-build22-Intel-preview.zip` |

单架构应用同时保留在 `build/releases/AppleSilicon/FangCun.app` 和 `build/releases/Intel/FangCun.app`，供之后分别正式签名、打包。旧通用预览包移至 `.build/retired-distributions/`，下载目录只提供本版本的两种芯片包。

这些是需手动安装的预览 ZIP，**没有一键安装器和正式签名、公证**。构建和 ZIP 校验通过不等于新机器安装通过，Apple Silicon 和 macOS 13 还需实机验收。本轮两份包均通过压缩包 CRC、解压签名、主程序及动态库单一架构、最低系统版本、可执行权限、文件一致性和 SHA-256 校验；重新打包可能因时间戳不同改变摘要，以同次生成的 `.sha256` 为准。

## 给普通用户的安装体验

推荐最终下载物为分别签名、公证的 `FangCun-0.1.0-beta.1-AppleSilicon.pkg` 和 `FangCun-0.1.0-beta.1-Intel.pkg`，必要时分别装入 `.dmg`。下载页显示“Apple Silicon 版（M 系列）”和“Intel 版”两个按钮，并提供版本、系统要求、文件大小、SHA-256、更新说明和模型配置说明。用户不需要安装 Xcode、Python、Homebrew 或克隆代码。用户可通过苹果菜单 → 关于本机查看芯片或处理器型号；安装器也需拒绝不匹配的架构并提示下载正确版本。

正式安装器还需要实施，目标流程如下：

1. 显示安装位置和版本；检测同一产品是否已在用户或系统输入法目录中安装。
2. 全新安装采用 `/Library/Input Methods/FangCun.app`，由 macOS Installer 请求管理员权限。现有开发版位于 `~/Library/Input Methods/FangCun.app`，需要明确迁移流程，不能留下两个相同标识的副本。
3. 更新前切换到可用备用输入源，只停止方寸进程，备份旧版本；失败能恢复旧应用。保留偏好、用户词库和钥匙串。
4. 在实际登录用户的会话内注册、启用输入源，并检查它确实可选。不能在以 root 运行的安装脚本中把输入法添加给 root 后报告成功。
5. 展示“开始使用 / 配置 AI”入口。如果系统会话尚未发现输入源，清楚提示重新登录或手动添加，保留失败原因。
6. 提供卸载入口：先移除输入源，再移除本产品；是否删除词库、偏好和密钥由用户明确选择。

目前 `scripts/install.sh` 已实现本机开发安装的备份、注册和启用检查，但依赖源码与编译环境，不能原样交给普通用户。正式安装器应复用同样的状态判断，由签名的原生辅助程序完成用户会话内操作。Rime 官方 macOS 前端也使用独立的安装包与签名流程，可参考其 [构建安装说明](https://github.com/rime/squirrel/blob/master/INSTALL.md)。

应用内部标识保持 `com.translatetype.inputmethod.TranslateType`，输入模式保持 `.Hans`。显示名为方寸输入法；不要为了发布再次更换内部标识或安装文件名。

## Apple 签名与公证

需要 Apple Developer Program 的 Developer ID 证书。Apple 当前列出的会员费是每年 99 美元，地区价格以注册页面为准。[Apple 会员说明](https://developer.apple.com/programs/enroll/)

| 用途 | 凭据 |
| --- | --- |
| 应用、动态库、原生安装辅助程序 | Developer ID Application |
| `.pkg` 安装包 | Developer ID Installer |
| Apple 公证服务 | `notarytool` 钥匙串凭据配置或受支持的 API 凭据 |

证书私钥留在钥匙串，公证凭据不写进仓库。仅下载 `.cer`、却没有对应私钥，不能完成签名。Apple 对应用与安装包签名的要求见 [Developer ID](https://developer.apple.com/developer-id/) 和 [证书说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)。

以下为拿到证书后，对两份单架构应用分别签名、公证的 ZIP 流程示例，尚未在本机执行。最终两份 `.pkg` 也需各自签名、公证及验证。

```sh
set -e
# 替换成钥匙串中的真实证书名。
FANGCUN_SIGN_ID='Developer ID Application: Your Name (TEAMID)'
# 交互输入凭据并保存到钥匙串，不把密码放入脚本或聊天。
xcrun notarytool store-credentials FangCun-notary
# 在发布副本上操作。两种架构分别处理，不再从通用应用生成下载包。
for FANGCUN_CHIP in AppleSilicon Intel; do
  mkdir -p "dist/signing/$FANGCUN_CHIP"
  FANGCUN_APP="dist/signing/$FANGCUN_CHIP/FangCun.app"
  ditto "build/releases/$FANGCUN_CHIP/FangCun.app" "$FANGCUN_APP"
  codesign --force --options runtime --timestamp --sign "$FANGCUN_SIGN_ID" \
    "$FANGCUN_APP/Contents/Frameworks/librime.1.dylib"
  codesign --force --options runtime --timestamp --sign "$FANGCUN_SIGN_ID" "$FANGCUN_APP"
  codesign --verify --deep --strict --verbose=2 "$FANGCUN_APP"
  ditto -c -k --keepParent "$FANGCUN_APP" "dist/FangCun-$FANGCUN_CHIP-notary.zip"
  xcrun notarytool submit "dist/FangCun-$FANGCUN_CHIP-notary.zip" \
    --keychain-profile FangCun-notary --wait --output-format json \
    > "dist/signing/$FANGCUN_CHIP/notary-result.json"
  # 只有状态 Accepted 才继续；失败时停止并读取本次 notarytool log。
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Accepted" else 1)' \
    "dist/signing/$FANGCUN_CHIP/notary-result.json"
  xcrun stapler staple "$FANGCUN_APP"
  xcrun stapler validate "$FANGCUN_APP"
  spctl --assess --type execute --verbose=4 "$FANGCUN_APP"
  ditto -c -k --keepParent "$FANGCUN_APP" "dist/FangCun-$FANGCUN_CHIP-notarized.zip"
done
```

启用 Hardened Runtime 后需要重新验证输入会话、候选窗、临时编辑区、钥匙串访问和宿主上屏。动态库先签、外层应用后签；不要用 `codesign --deep` 代替逐层签名。以上 `--deep` 只用于验证。公证不会代替产品测试。依据：[Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[常见公证问题](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)。

## 正式发布前仍需完成

- **安装器**：全新安装、开发版迁移、升级回滚、按用户启用、卸载；不能只把 `.app` 放到下载页就宣称一键安装。
- **新机器测试**：至少一台 Apple Silicon；macOS 13 最低版本及计划支持的其他版本。实测浏览器、原生文本框和聊天应用，包含首次安装、重启、唤起编辑区、复制部分回答、直接上屏。
- **正式签名验证**：从浏览器下载最终包，让 Gatekeeper 走真实下载验证；在未安装开发版的账户里检查首次启动和钥匙串。不得通过关闭系统保护来冒充通过。
- **许可文件**：项目根目录尚未选择主许可证；先确定自己的代码如何授权。Rime 许可证和 Rime Ice 的 GPL-3.0 已保留，但仍要核对 Rime 二进制中打包的第三方依赖声明、简体词库来源声明，并随发布提供对应资源与生成脚本。不能假定给整个仓库补一份 MIT 就能改变词库许可。GPL 的独立聚合与衍生作品需要按实际集成方式区分，参见 [GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)。
- **隐私说明**：离线拼音不发送内容；执行 AI 时发送本次原文、指令，或提问、参考文字和必要对话给用户配置的服务。密钥在本机钥匙串，费用与服务由用户自行配置。说明哪些草稿仅存在内存，以及目前没有自动更新机制。
- **测试边界**：既有自动检查主要使用模拟模型服务；build 22 新增动作的真实服务验证曾停在钥匙串授权，正式发布前补测实际配置的服务。历史输入审计中的已知缺口需逐项复核，不能用总通过数覆盖未验收项。

## 发版操作

本次使用 `v0.1.0-beta.1` 标签，创建标记为 Pre-release 的 GitHub Release，上传两份预览 ZIP 和各自 SHA-256。发布说明明确未正式签名、公证，包含“仍要打开”的系统操作指引，不等待正式签名完成。两份包保持相同产品版本与 build；先核对草稿资产与本机验证文件的摘要，再发布供下载。

正式版继续按上文完成独立安装器、签名公证、第三方材料和新机器验收。自动更新可在后续版本加入，更新时必须按本机架构选择。发布不更改仓库可见性。
