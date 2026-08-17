# TaskHub

面向普通用户的轻量级 Windows 计划任务管理器，基于 Windows PowerShell 5.1、.NET Framework WPF 与 Task Scheduler 2.0 COM API，始终以当前用户令牌运行。

**不请求管理员权限、不提升、不绕过 UAC / 执行策略 / 任务 ACL。**

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10/11，或 Windows Server 2016+ |
| Shell | 系统自带 Windows PowerShell 5.1 |
| 运行时 | .NET Framework WPF |
| 服务 | Task Scheduler 可用 |

无需 `pwsh`、Gallery 模块、NuGet 包或外部 DLL。

## 构建与运行

```powershell
.\build.ps1                          # 生成同目录 TaskHub.cmd
.\build.ps1 -OutputPath D:\Tools\TaskHub.cmd
```

双击 `TaskHub.cmd` 即可运行：它是 CMD/PowerShell polyglot，隐藏控制台启动 WPF 主窗口，不出现 UAC 提示。

- 图标由 `assets\TaskHub.svg` 在构建时于内存渲染并注入，不产生 PNG/ICO 中间文件（可用 `-IconPath` 更换母版）。
- 若执行策略拦截脚本，请使用 IT 签名或授权部署；不要使用 `-ExecutionPolicy Bypass`。

## 功能

- 枚举当前用户可见的任务文件夹与任务，展示状态、启用状态、运行账户、上次/下次运行、上次结果、触发器与操作摘要。
- 刷新、立即运行、停止、启用、禁用、创建、编辑、删除、查看/导出 XML、打开后台任务目录。
- 右键菜单：启用的任务显示「运行 / 结束 / 禁用 / 导出 / 删除」，禁用的任务显示「启用 / 导出 / 删除」。
- 创建/编辑：`TaskPath`、`TaskName`、Description；登录/单次/每日触发器（单次与每日支持分钟级重复）。
- `executable`、`arguments`、`working directory` 为独立字段，直接写入 Exec action，不经 shell 二次解析。
- 后台应用模式：隐藏 PowerShell 包装器 + Job Object 守护整个进程树（见下）。
- 高级结构（事件/Boot 触发器、多操作/多触发器、COM Handler、最高权限等）保持只读，避免覆盖原定义。

## 安全模型

- 唯一权限依据是 Task Scheduler 服务与任务 ACL；拒绝访问时如实报告，不提升、不绕过。
- 创建/覆盖固定为：当前用户 SID + `TASK_LOGON_INTERACTIVE_TOKEN` + LeastPrivilege + 一个 Exec action + 登录/单次/每日触发器。
- 不提供 SYSTEM、其他用户、密码登录、最高权限、Boot trigger 等选项。

## 后台应用

勾选「后台应用」后，每个任务获得独立目录：

```text
%LOCALAPPDATA%\TaskHub\Tasks\<完整任务路径的 SHA-256>\
├── wrapper.ps1
├── config.json
└── logs\
    ├── stdout.log
    ├── stderr.log
    └── wrapper-error.log（仅失败时出现）
```

要点：

- 任务 action 指向系统 `powershell.exe -File wrapper.ps1`，Task Scheduler 直接跟踪包装器进程。
- 包装器以挂起状态创建目标程序，先加入设了 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job Object，再恢复；停止任务即关闭 Job 句柄，终止整个进程树。
- 包装器等待**整个 Job 清空**而非最初进程，因此 mihomo 这类 `/restart` 由子进程接棒的程序仍被持续守护；退出码取最初进程。
- stdout/stderr 直写日志文件，不经过 shell 转码；无限执行时间、多实例 IgnoreNew。
- 删除任务时默认保留日志，可勾选一并删除。

## 日志

- 主应用日志：`%LOCALAPPDATA%\TaskHub\TaskHub.log`（操作与错误，不含密码或敏感环境变量）。
- 后台任务日志：各任务 `logs\stdout.log`、`stderr.log`，原始字节、每次启动覆盖。
- 输出及时性取决于目标程序自身缓冲（如 Python 可用 `-u`）。

## 测试

```powershell
.\tests\Test-TaskHub.ps1
```

只创建并操作 `UTM.Test.*` 唯一任务，不动既有任务、不请求提升；覆盖触发器、权限模型、后台目录映射、Job Object 进程树停止、图标注入与日志清理。无权在根目录注册任务时报 Access denied 并退出。

## 已知限制

- 只做当前用户令牌能做的事；受保护系统文件夹可能无法枚举。
- 编辑器仅支持单 Exec action 与登录/单次/每日触发器；高级任务只读。
- 后台模式面向直接可执行程序，参数由目标程序自身解析。
- 重命名/移动 = 先注册新任务再删旧任务；第二步失败时新任务保留并明确提示。
- 导出 XML 为 UTF-16（与 COM 返回一致）。
- 需要交互式桌面会话（Server Core 无 GUI）。

## 常见错误

| 现象 | 处理 |
|---|---|
| Access denied / 拒绝访问 | 选择有权操作的任务或联系管理员授权；本程序不提升。 |
| Task Scheduler 服务未运行 | 联系 IT 恢复服务。 |
| 脚本被执行策略阻止 | 使用 IT 签名版本或授权配置，不用 Bypass。 |
| 任务刚才还存在 | 可能被并发删除，刷新后重试。 |
| 中文路径/空格参数异常 | 参数、路径、工作目录为独立 Unicode 字段，引号由目标程序解释。 |
