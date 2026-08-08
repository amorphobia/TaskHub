# TaskHub.Launcher.exe 方案

> 状态：设计修订中。本文档描述实现约束、迁移策略和验收标准；在下列关键决策落实前，不进入代码实现。

## 背景

当前后台应用通过每个任务独立的 `wrapper.ps1`（PowerShell 脚本）启动。Task Scheduler 用 `TASK_LOGON_INTERACTIVE_TOKEN` 启动 `powershell.exe -WindowStyle Hidden -File wrapper.ps1` 时，Windows 不会使用 `CREATE_NO_WINDOW` 标志，因此 PowerShell 控制台窗口仍会短暂出现（一闪而过）。

## 方案概述

用单个预编译的 C# Windows 子系统可执行文件 `TaskHub.Launcher.exe` 替代每个任务独立的 `wrapper.ps1`。

### 架构对比

**当前（wrapper.ps1）：**
```
Task Scheduler Action:
  Path:      %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
  Arguments: -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "...\wrapper.ps1"
  WorkingDirectory: %LOCALAPPDATA%\TaskHub\Tasks\<sha256>\

wrapper.ps1 → Add-Type 编译 C# BackgroundProcessRunner → CreateProcess(目标程序) → Job Object
```

**新方案（Launcher.exe）：**
```
Task Scheduler Action:
  Path:      %LOCALAPPDATA%\TaskHub\TaskHub.Launcher.exe
  Arguments: "%LOCALAPPDATA%\TaskHub\Tasks\<sha256>\config.json"
  WorkingDirectory: %LOCALAPPDATA%\TaskHub\

TaskHub.Launcher.exe → 读 config.json → CreateProcess(目标程序, CREATE_NO_WINDOW) → Job Object
```

Launcher 本身必须编译为 Windows 子系统（`csc.exe /target:winexe`），不能使用默认的
`/target:exe`。`CREATE_NO_WINDOW` 只抑制 Launcher 创建的目标进程，不能抑制 Launcher
自身的控制台；这是“零弹窗”成立的必要条件。

### 关键优势

1. **零弹窗**：C# 可直接调用 `CreateProcess(CREATE_NO_WINDOW)`，不经过 `powershell.exe`
2. **共享一份**：所有后台任务指向同一个 `TaskHub.Launcher.exe`，不每个任务拷贝
3. **进程隔离**：Launcher 为每个目标创建独立 Job Object，并等待目标退出；停止任务时关闭 Job Object 会终止目标及其后代
4. **共享安全**：编译后的 exe 固定不变，不会像 `Add-Type` 运行时编译那样有多任务竞态问题

## 实施细节

### 1. C# 源码管理

- 从 `WrapperContent.ps1` 中抽出 C# 源码 → `src/Launcher.cs`
- `BackgroundProcessRunner` 核心逻辑保持不变（Job Object、stdout/stderr 重定向等）
- `Launcher.cs` 必须包含独立入口 `Main`，不能依赖 PowerShell 执行配置解析或异常处理
- 配置使用 .NET Framework 自带的 `DataContractJsonSerializer`，避免引入第三方 DLL
- `LauncherConfig` 至少包含：`Version`、`TaskFullPath`、`Executable`、`Arguments`、
  `WorkingDirectory`、`LogDirectory`、`LogDirectoryIsDefault`、`Environment`
- 读取配置时接受 UTF-8 和 UTF-8 BOM；未知字段忽略；缺少必需字段或 JSON 无效时写入
  `wrapper-error.log` 并返回非零退出码
- 目标程序退出后，Launcher 返回目标程序的退出码；Launcher 自身启动失败返回非零值
- `--version` 只输出版本并返回 0，不读取任务配置、不创建日志、不启动目标程序

### 2. 构建集成（build.ps1）

- 读取 `src/Launcher.cs` 内容
- 不做源码压缩。Launcher 源码体积相对整个 CMD 构建产物很小，保留原始换行更利于诊断和审查
- 替换 `__TASKHUB_LAUNCHER_SOURCE__` 标记
- 以 PowerShell Here-String 形式嵌入源码：
  ```powershell
  $script:LauncherSource = @'
  // C# 源码内容
  '@
  ```
- 替换前检查源码不包含 `'@`（Here-String 结束符），包含则抛错
- 不需要 Base64 —— C# 是纯文本，直接嵌入更省空间
- `src/Launcher.cs` 不能直接加入 `$sourceFiles`，否则会被当作 PowerShell 解析；应在
  `Background.ps1` 或独立的 PowerShell 源文件中保留占位 Here-String，再由构建器替换
- 构建器必须检查占位符恰好出现一次，并在注入后再次执行 PowerShell 语法检查
- 构建器应使用 `csc.exe /target:winexe /optimize+ /nologo` 做一次独立编译检查，输出到临时目录

### 3. 首次运行时编译

- 首次创建后台应用时（或在 `Install-BackgroundRuntime` 中），PowerShell 调用 `csc.exe` 将
  `$script:LauncherSource` 编译为 `%LOCALAPPDATA%\TaskHub\TaskHub.Launcher.exe`
- 编译器按以下顺序发现：与当前 PowerShell 位数匹配的
  `%WINDIR%\Microsoft.NET\Framework*\v4.0.30319\csc.exe`，并验证文件存在
- 编译参数必须显式指定 `/target:winexe`；若使用 `DataContractJsonSerializer`，显式引用
  `System.Runtime.Serialization.dll`
- 所有编译参数使用安全的参数转义，支持用户名、TaskHub 路径和临时目录中的空格及 Unicode
- 编译失败时保留旧 Launcher（若存在），删除临时产物，并将 csc 输出写入主应用日志；首次安装
  无可用旧版本时，任务不得注册成功
- 编译后缓存，后续任务直接复用
- 多个 TaskHub 实例或并发创建任务时，使用当前用户范围的命名 Mutex 串行化编译和替换
- 编译到随机临时文件，校验退出码和文件存在后再安装；不得直接覆盖正在使用的正式文件

### 4. 版本管理

- C# 源码中声明 `LauncherVersion` 常量，语义化版本（如 `0.1.0`）
- 与 config.json 的 schema `Version`（递增整数）独立演进
- 构建产物中的 PowerShell 代码同时嵌入 `LauncherSourceVersion`，用于和现有 EXE 比较；不能
  依赖运行时临时解析 C# 源码来取得版本
- C# 程序将同一个版本写入 AssemblyInformationalVersion
- PowerShell 使用 `FileVersionInfo` 读取现有 EXE 版本；不通过启动 Launcher 来探测版本
- 当前源码版本与现有 EXE 版本不一致时编译新文件
- 第一版采用“单一稳定路径 + 临时文件 + 原子替换 + 失败保留旧版本”：替换失败不得删除
  或破坏旧版本；若旧版本仍能读取当前 config schema，则记录“更新延后”并继续使用旧版本，
  否则本次任务注册失败
- 原子替换失败时最多重试 20 次、每次间隔 250ms；重试结束仍失败则按上一条处理，不删除正式 EXE

### 5. 任务注册变更

**Install-BackgroundRuntime 重写：**
- 旧：拷贝 wrapper.ps1 内容 → `WriteAllText(wrapper.ps1)` + 写 config.json
- 新：确保 `TaskHub.Launcher.exe` 存在且版本可用（不存在则编译）+ 写 config.json

**任务 Action 变更：**
- `ActionPath` 使用解析后的绝对路径：`<LocalApplicationData>\TaskHub\TaskHub.Launcher.exe`
- `ActionArguments` 为经过 Windows 命令行规则转义的绝对 config 路径，不能依赖环境变量展开
- `WorkingDirectory` 使用解析后的 `<LocalApplicationData>\TaskHub\`
- 目标程序的真实工作目录仍只从 config.json 的 `WorkingDirectory` 读取，不能误用 Launcher 的工作目录

### 6. 文件清理

- `WrapperContent.ps1` 整个文件可删除
- `src/Background.ps1` 中移除 `Install-BackgroundRuntime` 中写 `wrapper.ps1` 的逻辑
- 新任务的 `Remove-BackgroundRuntimeFiles` 删除 `config.json` 和任务专属日志；不能删除共享 Launcher
- 旧任务迁移期间仍允许删除旧任务目录中的 `wrapper.ps1`
- 共享 Launcher 的生命周期独立于单个任务删除；本方案暂不因删除最后一个任务而删除它

### 7. 向后兼容

- 旧任务（有 wrapper.ps1 + config.json 的）继续用旧方式运行，不受影响
- `Get-BackgroundActionCandidates`、`Get-BackgroundRuntimeInfo` 和
  `Test-ActionTargetsBackgroundRunner` 必须同时识别旧 wrapper action 和新 Launcher action
- 识别仍必须校验任务专属目录中的 config.json、`Version` 和 `TaskFullPath`，不能只按 EXE 路径
  把任意任务标记为后台任务
- 编辑旧任务并保存时，自动迁移到新格式：
  - 先确保共享 Launcher 可用
  - 先写入或更新 config.json，再注册新 task action
  - 注册成功后才删除旧任务的 `wrapper.ps1`
  - 保持 config.json 的 `Version = 1` 和字段语义不变
  - 任一步失败时恢复原 wrapper/config；不能留下指向不存在 Launcher 的任务 action
- 旧任务的运行中进程必须先按现有停止流程结束，再删除旧日志或旧 wrapper；文件清理失败
  不得回滚已经成功注册的新任务，但必须明确记录并提示残留路径

## 讨论过但已放弃的方案

### 守护进程（TaskHub Daemon）

- **目标**：统一管理所有后台应用进程，支持应用间依赖
- **问题**：常驻进程更新时会中断所有管理中的子进程
- **缓解**：命名 Job Object 允许新 daemon 实例重新附加，不杀子进程
- **决定**：暂不实施，等后续有实际痛点时再参考此方案

### Launcher 日志轮转

- **问题**：直接重定向文件无法轮转（子进程句柄固定）；daemon 中转账可轮转但崩溃时丢日志
- **决定**：不做轮转，每次启动覆盖 stdout.log / stderr.log（和当前 wrapper 行为一致）

### 运行时失败处理

- 配置不存在、JSON 无效、日志目录不可创建、目标程序不存在、工作目录无效和 Win32 API
  失败均写入任务日志目录的 `wrapper-error.log`
- 日志目录优先使用 config.json 的 `LogDirectory`；无法读取配置或无法解析日志目录时，退回
  任务运行目录下的 `logs`，若连该目录也无法创建则仅返回非零退出码
- 不把异常文本写到 stdout/stderr，避免污染目标程序日志
- Launcher 不请求提升、不调用 PowerShell、cmd.exe 或 shell 重新解析目标参数

## 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新建 | `src/Launcher.cs` | C# 启动器源码 |
| 删除 | `src/WrapperContent.ps1` | 不再需要嵌入 wrapper |
| 修改 | `src/Background.ps1` | 重写 Install-BackgroundRuntime 等 |
| 修改 | `src/TaskManager.ps1` | 调整 Register-TaskFromData 中的 action 设置 |
| 修改 | `build.ps1` | 移除 WrapperContent.ps1，增加 Launcher.cs 嵌入 |
| 修改 | `README.md` | 更新运行目录、任务 action、迁移和限制说明 |
| 修改 | `tests/Test-TaskHub.ps1` | 更新 wrapper 断言并增加 Launcher、迁移和并发测试 |

## 版本演进

| 方案 | config.json Version | LauncherVersion | 说明 |
|------|---------------------|---------------|------|
| 当前 | 1 | — | wrapper.ps1 模式，task action 指向 powershell.exe |
| 新方案 | 1（不变） | 0.1.0 | Launcher.exe 模式，task action 指向 Launcher.exe，config 字段不变 |

## 验收标准

### 构建与安装

- Windows PowerShell 5.1、Windows 10/11、中文用户名和带空格路径下构建成功
- `src/Launcher.cs` 可被独立编译为 `/target:winexe`，且构建产物不包含未替换占位符
- 首次安装、重复安装、两个 TaskHub 实例并发安装均不会产生损坏或半写入的 EXE/config
- csc 不存在或被策略阻止时，显示明确错误；没有旧 Launcher 时不注册任务

### 运行行为

- Task Scheduler 直接启动的进程和目标进程都不出现可见控制台窗口
- 中文 executable、参数、工作目录、日志目录和环境变量均保持不变
- 目标 stdout/stderr 仍直接写入对应日志，Launcher 返回目标退出码
- 停止任务会终止 Launcher、目标进程和目标创建的孙进程
- 无效配置、目标不存在和日志目录不可用时生成错误日志且任务不会静默成功

### 兼容与更新

- 旧 wrapper 任务可以继续运行、查看、打开日志和删除
- 编辑旧 wrapper 任务后迁移到 Launcher；迁移失败时旧任务仍可运行
- 新旧任务同时存在时，后台任务识别不会误报普通任务
- 一个 Launcher 正在等待长期运行目标时，另一个任务的创建/编辑不会破坏正在运行的进程
- Launcher 版本更新失败时旧版本仍可运行，且不会留下指向不存在文件的 task action

### 必须覆盖的回归测试

- 无窗口测试不能只检查 `MainWindowHandle`，还应确认 Launcher 的 PE 子系统为 Windows
- 覆盖旧 wrapper action、新 Launcher action、同名不同目录任务和任务重命名/移动
- 覆盖 config.json UTF-8 BOM、引号参数、空工作目录、Unicode 和未知字段
- 覆盖编译并发、原子替换失败、运行中 Launcher、停止进程树和清理残留文件

## 实施前验证记录

以下验证在 2026-08-08 的 Windows 11 x64 环境执行，使用唯一临时 Task Scheduler 任务和临时
Launcher 探针，不涉及现有任务：

- `Framework` 和 `Framework64` 下的 .NET Framework 4.0.30319 `csc.exe` 均存在；最小程序可用
  `/target:winexe` 编译，PE Subsystem 为 Windows GUI（值 2），不是控制台（值 3）
- 直接把 UTF-8 BOM 文件交给 .NET Framework `DataContractJsonSerializer.ReadObject(Stream)`
  会失败；必须先按 UTF-8 解码、剥离 BOM，再交给序列化器
- `Environment` JSON 对象必须使用 `DataContractJsonSerializerSettings.UseSimpleDictionaryFormat`
  才能反序列化为 `Dictionary<string,string>`；否则环境变量会丢失
- Task Scheduler 直接启动 `winexe` 探针时，Launcher 无可见窗口；停止任务可以终止 Launcher、
  Job Object 中的目标 `PING.EXE` 以及目标进程树
- Launcher 长时间运行时，使用 `MoveFileEx` 替换正在执行的 EXE 实测返回
  `ERROR_ACCESS_DENIED (5)`。因此第一版更新策略确定为：运行中不强制替换；若旧版本仍兼容
  当前 config schema，则延后更新并继续注册任务；若旧版本不兼容，则明确失败并保留旧文件。

这些结果已转化为上文的实现约束和验收标准；实现时不得把 BOM 处理、字典设置或运行中 EXE
替换当作默认行为。
