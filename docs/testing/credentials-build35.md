# build 35：密钥授权与输入卡死修复

## 原因

- 旧版将 `SecItemCopyMatching` 放在 `Task { @MainActor … }` 中同步执行。设置页首次打开也同步读取钥匙串。
- 系统等待钥匙串授权时，输入法无法响应 IMK 按键请求；授权窗口如果也要通过这个输入法接收按键，就会发生长时间等待。
- 开发构建使用临时签名，每次重建可能改变系统识别的代码身份，使之前保存的钥匙串访问授权失效。这里是根据构建方式和代码路径作出的判断，未读取或更改用户的钥匙串 ACL。

## 修改

- 新 Key 按服务地址存入 `~/Library/Application Support/TranslateType/Credentials/api-keys.json`。目录 0700，文件 0600；文件未额外加密，不写入偏好、日志、测试报告或仓库。
- 所有凭据读写使用后台串行队列。设置页异步加载、保存；候选框及编辑区异步等待 Key，输入法主线程继续处理按键。
- 完全删除钥匙串访问、迁移、回退和相关框架导入。读取路径只有本机文件；文件不存在或没有对应服务的 Key 时直接返回空值，不访问任何其他存储。
- 明确清空 Key 会保存空记录，重启后保持为空。
- 读取期间输入、切换动作或取消请求后，迟到的 Key 不会启动旧 HTTP 请求，也不会覆盖草稿。
- 设置页加载期间粘贴新 Key 或切换服务，迟到的读取结果不能覆盖当前字段；尚未完成加载或加载失败时，保存按钮不会误用空字段覆盖原 Key。

## 验证命令

```sh
./scripts/credential-test.sh
./scripts/test.sh
FANGCUN_EDITOR_TEST=CredentialSettingsTests ./scripts/editor-test.sh
FANGCUN_EDITOR_TEST=CandidateActionTests ./scripts/editor-test.sh
FANGCUN_EDITOR_TEST=AIActionTests ./scripts/editor-test.sh
./scripts/build.sh
```

存储测试使用隔离临时目录、虚构 Key 和可控的文件读取器。阻塞测试在后台等待受控信号，检查主线程仍然响应；核心测试结合真实 Rime 与本机 HTTP 服务，检查取消后请求数不增加，并验证新的请求可以继续执行。

原生设置表单测试覆盖加载中保存、粘贴覆盖、服务切换和失败恢复。候选动作及编辑区动作回归继续检查模型请求、缓存、取消、独立动作、版本和上屏。

应用的 `--credential-probe <report.json>` 仅检查当前配置的 Key 是否可从本机文件读取、是否存在；报告只包含布尔值、耗时和错误提示，不包含 Key，不发送模型请求。这不能代替用户在具体宿主中的最终打字体验验收。

## 本轮结果

- 本机存储检查 13 项、原生设置页检查 7 项、核心输入与请求回归 1,059 项通过。
- 生产源码中没有钥匙串 API、迁移器或相关框架导入；`nm -u` 检查最终可执行文件，没有 `SecItem`、`SecKeychain` 或 `LAContext` 引用。
- 真实配置的 Key 已存在于本机文件，读取探针返回成功且 `hasKey=true`，耗时约 0.005 秒；没有发送模型请求。
- 已安装 build 35 并重启输入法进程，安装文件与检查过的构建逐字节相同。密钥文件和目录权限分别核对为 0600、0700；保留用户当时选择的输入源。
