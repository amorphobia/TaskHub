# UserTaskManager

UserTaskManager 是一个面向普通 Windows 用户的轻量级计划任务管理器。它使用 Windows PowerShell 5.1、.NET Framework WPF 和 Task Scheduler 2.0 COM API，始终继承启动它的当前用户令牌。

它不会请求管理员权限，不使用 `RunAs`，不修改 UAC、组策略、注册表安全设置或任务 ACL，也不使用 `ExecutionPolicy Bypass` 或兼容性绕过技巧。

## 系统要求

- Windows 10/11，或 Windows Server 2016 及以上
- Windows PowerShell 5.1（系统自带的 `powershell.exe`）
- .NET Framework WPF
- Task Scheduler 服务可用

不需要 `pwsh`、PowerShell Gallery、第三方模块、NuGet 包或外部 DLL。

## 构建与运行

先在 Windows PowerShell 5.1 中运行：

```powershell
.\build.ps1
```

默认输出同目录下的 `UserTaskManager.cmd`。也可以指定路径：

```powershell
.\build.ps1 -SourcePath .\UserTaskManager.ps1 -OutputPath D:\Tools\UserTaskManager.cmd
```

然后双击生成的 `UserTaskManager.cmd`。它是一个 CMD/PowerShell polyglot 文件：开头的批处理包装器读取同一个文件中的 PowerShell 应用代码。包装器明确调用：

```text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -Command "..."
```

构建产物使用无 BOM 的 UTF-8，使 `cmd.exe` 能识别第一行；包装器在 Windows PowerShell 5.1 中显式按 UTF-8 读取完整文件，从而保留中文 UI、中文路径和 Unicode 任务名称。该编码只用于读取应用源代码，不会转换任务路径或 action 字段。

不会出现由本程序发起的 UAC 提示。包装器以及直接运行脚本时的 STA 重启都使用同一个当前用户令牌，不会使用 `-Verb RunAs`。

双击生成的 CMD 后，PowerShell 使用 `-WindowStyle Hidden` 隐藏控制台，WPF 主窗口正常显示。由于 Windows Explorer 必须先通过 `cmd.exe` 打开 `.cmd` 文件，在较慢系统上仍可能看到极短的控制台闪烁；单个 `.cmd` 文件无法从文件关联层面彻底消除这一帧。持续显示的控制台窗口会被隐藏。

如果组织的执行策略阻止脚本，请让 IT 对脚本进行签名，或由 IT 将脚本部署到组织允许的执行策略范围。不要用 `-ExecutionPolicy Bypass` 绕过组织策略。

## 功能

- 左侧枚举当前用户可见的任务文件夹。
- 右侧显示所选文件夹中的任务名称、完整路径、状态、启用状态、运行账户、上次/下次运行时间、上次结果、触发器摘要和操作摘要。
- 详情区显示当前任务的完整摘要。
- 支持刷新、立即运行、停止、启用、禁用、创建、编辑、删除、查看 XML 和导出 XML。
- 创建任务时可自由填写 `TaskPath`、`TaskName` 和 Description。
- `TaskPath` 默认为当前选中的文件夹（根目录为 `\`），也可以从可见文件夹中选择或输入新路径。
- 路径不存在时，程序逐级调用 Task Scheduler COM API 尝试创建。拒绝访问时原样报告，不提升，也不回退到其他目录。
- 支持登录、单次和每日触发器；单次和每日触发器可设置分钟级重复间隔。
- executable、arguments 和 working directory 分别写入 Exec action，不拼接为需要 PowerShell 或 shell 重新解释的命令。
- 同名覆盖、编辑、移动/重命名和删除前均显示完整任务路径并要求确认。
- 对事件触发器、Boot trigger、COM Handler、多操作、多个触发器、最高权限、非 InteractiveToken 或编辑器无法忠实表达的高级结构，编辑器保持只读，避免覆盖原定义。XML 仍可查看或导出。

## 安全模型

Task Scheduler 服务和任务 ACL 是唯一权限依据。程序不根据任务名称、文件夹、Description、Principal.UserId 或自定义标记推测“所有权”。

对选中的任务，程序可以按用户要求尝试运行、停止、启用、禁用、编辑和删除。服务如果返回 Access denied，GUI 会显示：

```text
Access denied（拒绝访问）。当前用户令牌没有此任务或文件夹所需的权限。
```

程序不会因为拒绝访问而请求提升或绕过 ACL。枚举单个文件夹或任务失败时会跳过该对象并写日志，其他可读对象继续显示。

本程序创建或覆盖的定义固定为：

- 当前登录用户 SID
- `TASK_LOGON_INTERACTIVE_TOKEN`
- `TASK_RUNLEVEL_LUA` / LeastPrivilege
- 无密码
- 仅用户登录时具备交互令牌
- 一个 Exec action
- 登录、单次或每日触发器

GUI 不提供 SYSTEM、LocalService、NetworkService、其他用户、HighestAvailable、密码登录、注销后保存密码运行或 Boot trigger 等选项。

## 日志

日志路径：

```text
%LOCALAPPDATA%\UserTaskManager\UserTaskManager.log
```

日志记录连接、刷新、跳过的对象、成功操作及友好错误；不记录密码或敏感环境变量。用户填写的任务路径可能出现在操作和错误日志中。

## 安全测试

从 Windows PowerShell 5.1 运行：

```powershell
.\Test-UserTaskManager.ps1
```

测试脚本会：

1. 使用随机 GUID 和 `UTM.Test.` 前缀在根目录创建三个唯一测试任务；
2. 验证登录、单次、每日触发器；
3. 验证 InteractiveToken、LeastPrivilege 和独立的 action 字段；
4. 仅对唯一测试任务执行启用、禁用、立即运行和停止；
5. 在 `finally` 中清理本次测试创建的所有任务。

测试不修改、禁用或删除任何既有任务，也不创建或删除任务文件夹。如果当前用户无权在根目录注册任务，测试会报告 Access denied 并退出，不请求提升。

## 已知限制

- UI 是当前用户权限的前端，不会使原本无权操作的任务变得可操作。
- 某些受保护系统文件夹可能完全无法枚举；这些拒绝会记入日志。
- Task Scheduler 服务停止、被策略禁用或 COM 注册损坏时，应用只能显示错误。
- 编辑器仅支持一个 Exec action 和一个登录/单次/每日触发器。高级任务保持只读。
- 重命名或移动任务由“在目标注册，再删除原任务”完成。如果第二步被 ACL 拒绝，目标任务会保留，错误会明确说明原任务未删除。
- 导出的任务 XML 使用 UTF-16，与 Task Scheduler COM 返回的 XML 声明一致。
- WPF 界面需要交互式桌面会话；Windows Server Core 不支持此 GUI。

## 截图位置

项目不提交与特定账户、任务名称或公司环境绑定的截图。发布文档需要截图时，建议将经过脱敏的主窗口截图保存为：

```text
docs/UserTaskManager-main.png
```

截图应隐藏用户名、任务路径、程序参数以及可能包含业务信息的 Description。

## 常见错误

### Access denied / 拒绝访问

这是 Task Scheduler 服务依据当前用户令牌和任务 ACL 作出的决定。选择有权操作的任务或联系管理员调整正式授权；本程序不会提升。

### Task Scheduler 服务未运行

联系 IT 按组织策略恢复 Task Scheduler 服务。本程序不会自行改变服务启动方式。

### 脚本被执行策略阻止

请使用 IT 签名版本或由 IT 配置允许策略。不要添加 `ExecutionPolicy Bypass`。

### 任务刚才还存在

任务可能被其他控制台或进程并发删除。刷新后重试。

### 程序路径、中文路径或空格参数

程序使用 .NET Unicode 字符串和 Task Scheduler COM 宽字符接口。程序路径、参数和工作目录为三个独立字段；参数中的引号由目标程序解释，UserTaskManager 不进行 ANSI/GBK/UTF-8 手工转换。
