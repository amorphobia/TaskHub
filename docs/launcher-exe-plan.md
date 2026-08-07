# TaskHub.Launcher.exe 方案

## 背景

当前后台应用通过每个任务独立的 `wrapper.ps1`（PowerShell 脚本）启动。Task Scheduler 用 `TASK_LOGON_INTERACTIVE_TOKEN` 启动 `powershell.exe -WindowStyle Hidden -File wrapper.ps1` 时，Windows 不会使用 `CREATE_NO_WINDOW` 标志，因此 PowerShell 控制台窗口仍会短暂出现（一闪而过）。

## 方案概述

用单个预编译的 C# 可执行文件 `TaskHub.Launcher.exe` 替代每个任务独立的 `wrapper.ps1`。

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

### 关键优势

1. **零弹窗**：C# 可直接调用 `CreateProcess(CREATE_NO_WINDOW)`，不经过 `powershell.exe`
2. **共享一份**：所有后台任务指向同一个 `TaskHub.Launcher.exe`，不每个任务拷贝
3. **更新安全**：Launcher 是短命进程（启动目标后等待退出即结束），更新时不会影响已运行的子进程。原子替换（`MoveFileEx`）保证安全
4. **共享安全**：编译后的 exe 固定不变，不会像 `Add-Type` 运行时编译那样有多任务竞态问题

## 实施细节

### 1. C# 源码管理

- 从 `WrapperContent.ps1` 中抽出 C# 源码 → `src/Launcher.cs`
- `BackgroundProcessRunner` 核心逻辑不变（Job Object、stdout/stderr 重定向等）
- 可独立编译、独立做语法检查

### 2. 构建集成（build.ps1）

- 读取 `src/Launcher.cs` 内容
- **压缩**：去掉不影响编译的空白、换行、注释，减小嵌入体积
  - 仅做词法级压缩，不修改标识符名（避免引入 Roslyn 依赖和反射/P/Invoke 兼容性风险）
- 替换 `__TASKHUB_LAUNCHER_SOURCE__` 标记
- 以 PowerSW Here-String 形式嵌入源码：
  ```powershell
  $script:LauncherSource = @'
  // C# 源码内容
  '@
  ```
- 替换前检查源码不包含 `'@`（Here-String 结束符），包含则抛错
- 不需要 Base64 —— C# 是纯文本，直接嵌入更省空间

### 3. 首次运行时编译

- 首次创建后台应用时（或在 `Install-BackgroundRuntime` 中），PowerShell 调用 `csc.exe` 将 `$script:LauncherSource` 编译为 `%LOCALAPPDATA%\TaskHub\TaskHub.Launcher.exe`
- 编译后缓存，后续任务直接复用
- 更新检测：比较 `LauncherVersion`（嵌入源码的语义化版本常量），版本不一致时重新编译替换

### 4. 版本管理

- C# 源码中声明 `LauncherVersion` 常量，语义化版本（如 `0.1.0`）
- 与 config.json 的 schema `Version`（递增整数）独立演进
- 编译后的 exe 通过自身 Manifest 或命令行 `--version` 返回版本号

### 5. 任务注册变更

**Install-BackgroundRuntime 重写：**
- 旧：拷贝 wrapper.ps1 内容 → `WriteAllText(wrapper.ps1)` + 写 config.json
- 新：确保 `TaskHub.Launcher.exe` 存在（不存在则编译） + 写 config.json

**任务 Action 变更：**
- `ActionPath = %LOCALAPPDATA%\TaskHub\TaskHub.Launcher.exe`
- `ActionArguments = "%LOCALAPPDATA%\TaskHub\Tasks\<sha256>\config.json"`
- `WorkingDirectory = %LOCALAPPDATA%\TaskHub\`

### 6. 文件清理

- `WrapperContent.ps1` 整个文件可删除
- `src/Background.ps1` 中移除 `Install-BackgroundRuntime` 中写 `wrapper.ps1` 的逻辑
- `Remove-BackgroundRuntimeFiles` 中移除删除 `wrapper.ps1` 的逻辑

### 7. 向后兼容

- 旧任务（有 wrapper.ps1 + config.json 的）继续用旧方式运行，不受影响
- 编辑旧任务并保存时，自动迁移到新格式：
  - 删除任务的 `wrapper.ps1`
  - 更新 task action 指向 `TaskHub.Launcher.exe`
  - 保持 config.json 不变

## 讨论过但已放弃的方案

### 守护进程（TaskHub Daemon）

- **目标**：统一管理所有后台应用进程，支持应用间依赖
- **问题**：常驻进程更新时会中断所有管理中的子进程
- **缓解**：命名 Job Object 允许新 daemon 实例重新附加，不杀子进程
- **决定**：暂不实施，等后续有实际痛点时再参考此方案

### Launcher 日志轮转

- **问题**：直接重定向文件无法轮转（子进程句柄固定）；daemon 中转账可轮转但崩溃时丢日志
- **决定**：不做轮转，每次启动覆盖 stdout.log / stderr.log（和当前 wrapper 行为一致）

## 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新建 | `src/Launcher.cs` | C# 启动器源码 |
| 删除 | `src/WrapperContent.ps1` | 不再需要嵌入 wrapper |
| 修改 | `src/Background.ps1` | 重写 Install-BackgroundRuntime 等 |
| 修改 | `src/TaskManager.ps1` | 调整 Register-TaskFromData 中的 action 设置 |
| 修改 | `build.ps1` | 移除 WrapperContent.ps1，增加 Launcher.cs 嵌入 |

## 版本演进

| 方案 | config.json Version | LauncherVersion | 说明 |
|------|---------------------|---------------|------|
| 当前 | 1 | — | wrapper.ps1 模式，task action 指向 powershell.exe |
| 新方案 | 1（不变） | 0.1.0 | Launcher.exe 模式，task action 指向 Launcher.exe，config 字段不变 |
