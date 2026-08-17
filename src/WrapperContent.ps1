# The wrapper is embedded so the project does not depend on standalone helper
# files. Background tasks receive a private wrapper.ps1 copy under
# %LOCALAPPDATA%\TaskHub\Tasks\<full-task-path-sha256>\.
$script:BackgroundWrapperContent = @'
#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'config.json'
$logDirectory = Join-Path $PSScriptRoot 'logs'
$wrapperErrorPath = Join-Path $logDirectory 'wrapper-error.log'
$exitCode = 1

$jobRunnerSource = @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections;
using System.Collections.Generic;

namespace TaskHub
{
    public static class BackgroundProcessRunner
    {
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const int JobObjectExtendedLimitInformation = 9;
        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint STARTF_USESHOWWINDOW = 0x00000001;
        const uint STARTF_USESTDHANDLES = 0x00000100;
        const short SW_HIDE = 0;
        const uint HANDLE_FLAG_INHERIT = 0x00000001;
        const uint GENERIC_READ = 0x80000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint WAIT_OBJECT_0 = 0x00000000;
        const uint WAIT_FAILED = 0xFFFFFFFF;
        const uint INFINITE = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SECURITY_ATTRIBUTES securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        static void ThrowLastWin32Error(string operation)
        {
            int error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, operation + " failed");
        }

        static string QuoteCommandLineArgument(string value)
        {
            if (value == null) value = String.Empty;
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int slashCount = 0;
            foreach (char current in value)
            {
                if (current == '\\')
                {
                    slashCount++;
                }
                else if (current == '"')
                {
                    result.Append('\\', slashCount * 2 + 1);
                    result.Append('"');
                    slashCount = 0;
                }
                else
                {
                    result.Append('\\', slashCount);
                    result.Append(current);
                    slashCount = 0;
                }
            }
            result.Append('\\', slashCount * 2);
            result.Append('"');
            return result.ToString();
        }

        static void ConfigureKillOnClose(IntPtr job)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(
                    job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                    ThrowLastWin32Error("SetInformationJobObject");
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        static string BuildEnvironmentBlock(string[] extras)
        {
            var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                env[(string)entry.Key] = (string)entry.Value;
            }
            if (extras != null)
            {
                foreach (string extra in extras)
                {
                    if (string.IsNullOrEmpty(extra)) continue;
                    int eq = extra.IndexOf('=');
                    if (eq <= 0) continue;
                    string key = extra.Substring(0, eq);
                    string value = extra.Substring(eq + 1);
                    env[key] = value;
                }
            }
            var sb = new StringBuilder();
            foreach (var kvp in env)
            {
                sb.Append(kvp.Key);
                sb.Append('=');
                sb.Append(kvp.Value);
                sb.Append('\0');
            }
            sb.Append('\0');
            return sb.ToString();
        }

        public static int Run(
            string executable,
            string arguments,
            string workingDirectory,
            string stdoutPath,
            string stderrPath,
            string[] extraEnvironment)
        {
            if (String.IsNullOrWhiteSpace(executable))
                throw new ArgumentException("Executable is empty.", "executable");

            IntPtr job = IntPtr.Zero;
            IntPtr nullInput = IntPtr.Zero;
            FileStream stdoutFile = null;
            FileStream stderrFile = null;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            bool processCreated = false;
            bool processAssigned = false;
            bool stdoutInheritable = false;
            bool stderrInheritable = false;

            try
            {
                stdoutFile = new FileStream(
                    stdoutPath, FileMode.Create, FileAccess.Write, FileShare.Read);
                stderrFile = new FileStream(
                    stderrPath, FileMode.Create, FileAccess.Write, FileShare.Read);

                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) ThrowLastWin32Error("CreateJobObject");
                ConfigureKillOnClose(job);

                SECURITY_ATTRIBUTES inheritable = new SECURITY_ATTRIBUTES();
                inheritable.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                inheritable.bInheritHandle = 1;
                nullInput = CreateFile(
                    "NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    ref inheritable, OPEN_EXISTING, 0, IntPtr.Zero);
                if (nullInput == new IntPtr(-1)) ThrowLastWin32Error("CreateFile(NUL)");

                IntPtr stdoutHandle = stdoutFile.SafeFileHandle.DangerousGetHandle();
                IntPtr stderrHandle = stderrFile.SafeFileHandle.DangerousGetHandle();
                if (!SetHandleInformation(
                    stdoutHandle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT))
                    ThrowLastWin32Error("SetHandleInformation(stdout)");
                stdoutInheritable = true;
                if (!SetHandleInformation(
                    stderrHandle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT))
                    ThrowLastWin32Error("SetHandleInformation(stderr)");
                stderrInheritable = true;

                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
                startup.wShowWindow = SW_HIDE;
                startup.hStdInput = nullInput;
                startup.hStdOutput = stdoutHandle;
                startup.hStdError = stderrHandle;

                // The executable path is quoted per CommandLineToArgvW rules.
                // Arguments originate from this application's own config.json and
                // are already formatted as a command-line argument string by the
                // task editor. They are NOT quoted here because they may contain
                // multiple pre-quoted arguments (e.g. -NoLogo -File "path").
                string commandText = QuoteCommandLineArgument(executable);
                if (!String.IsNullOrWhiteSpace(arguments))
                    commandText += " " + arguments;
                StringBuilder commandLine = new StringBuilder(commandText);
                string currentDirectory = String.IsNullOrWhiteSpace(workingDirectory)
                    ? null
                    : workingDirectory;

                string envBlock = BuildEnvironmentBlock(extraEnvironment);
                IntPtr envPtr = Marshal.StringToHGlobalUni(envBlock);
                try
                {
                    if (!CreateProcess(
                        executable,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                        envPtr,
                        currentDirectory,
                        ref startup,
                        out process))
                        ThrowLastWin32Error("CreateProcess");
                }
                finally
                {
                    Marshal.FreeHGlobal(envPtr);
                }
                processCreated = true;

                SetHandleInformation(stdoutHandle, HANDLE_FLAG_INHERIT, 0);
                stdoutInheritable = false;
                SetHandleInformation(stderrHandle, HANDLE_FLAG_INHERIT, 0);
                stderrInheritable = false;

                if (!AssignProcessToJobObject(job, process.hProcess))
                    ThrowLastWin32Error("AssignProcessToJobObject");
                processAssigned = true;

                if (ResumeThread(process.hThread) == UInt32.MaxValue)
                    ThrowLastWin32Error("ResumeThread");

                // Wait for the whole job to empty rather than only the initial
                // process. A target such as mihomo may hand off to a child process
                // (e.g. an API /restart) and then exit; waiting on the initial
                // process would return at that handoff and the finally block would
                // close the job handle, killing the successor via KILL_ON_JOB_CLOSE.
                // The job handle becomes signaled only once the last process in the
                // job has terminated (job objects are waitable since Windows 8).
                uint waitResult = WaitForSingleObject(job, INFINITE);
                if (waitResult == WAIT_FAILED)
                    ThrowLastWin32Error("WaitForSingleObject");
                if (waitResult != WAIT_OBJECT_0)
                    throw new InvalidOperationException(
                        "Unexpected job wait result: " + waitResult.ToString());

                uint exitCode;
                if (!GetExitCodeProcess(process.hProcess, out exitCode))
                    ThrowLastWin32Error("GetExitCodeProcess");
                return unchecked((int)exitCode);
            }
            finally
            {
                if (stdoutInheritable && stdoutFile != null)
                    SetHandleInformation(
                        stdoutFile.SafeFileHandle.DangerousGetHandle(),
                        HANDLE_FLAG_INHERIT,
                        0);
                if (stderrInheritable && stderrFile != null)
                    SetHandleInformation(
                        stderrFile.SafeFileHandle.DangerousGetHandle(),
                        HANDLE_FLAG_INHERIT,
                        0);
                if (processCreated && !processAssigned && process.hProcess != IntPtr.Zero)
                    TerminateProcess(process.hProcess, 1);
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
                if (stdoutFile != null) stdoutFile.Dispose();
                if (stderrFile != null) stderrFile.Dispose();
                if (nullInput != IntPtr.Zero && nullInput != new IntPtr(-1))
                    CloseHandle(nullInput);
                // Closing the last non-inheritable job handle terminates every
                // still-running target process in the job, including descendants.
                if (job != IntPtr.Zero) CloseHandle(job);
            }
        }
    }
}
"@
try {
    Add-Type -TypeDefinition $jobRunnerSource -Language CSharp
    if (-not [IO.File]::Exists($configPath)) {
        throw ('Background configuration does not exist: {0}' -f $configPath)
    }
    # Accept both legacy UTF-8-with-BOM and canonical UTF-8-without-BOM config files.
    $utf8Strict = New-Object -TypeName Text.UTF8Encoding -ArgumentList @($false, $true)
    $configJson = $utf8Strict.GetString([IO.File]::ReadAllBytes($configPath))
    if ($configJson.Length -gt 0 -and $configJson[0] -eq [char]0xFEFF) {
        $configJson = $configJson.Substring(1)
    }
    $config = $configJson | ConvertFrom-Json
    if ($null -ne $config.PSObject.Properties['LogDirectory'] -and
        -not [string]::IsNullOrWhiteSpace([string]$config.LogDirectory)) {
        $logDirectory = [IO.Path]::GetFullPath([string]$config.LogDirectory)
        $wrapperErrorPath = Join-Path $logDirectory 'wrapper-error.log'
    }
    if (-not [IO.Directory]::Exists($logDirectory)) {
        [void][IO.Directory]::CreateDirectory($logDirectory)
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.Executable)) {
        throw 'Executable is empty in config.json.'
    }

    $extraEnv = @()
    if ($null -ne $config.PSObject.Properties['Environment']) {
        foreach ($prop in $config.Environment.PSObject.Properties) {
            $extraEnv += "$($prop.Name)=$($prop.Value)"
        }
    }

    # The executable and raw Windows argument string are passed directly to
    # CreateProcessW. No PowerShell or cmd.exe reparsing is introduced.
    $exitCode = [TaskHub.BackgroundProcessRunner]::Run(
        [string]$config.Executable,
        [string]$config.Arguments,
        [string]$config.WorkingDirectory,
        (Join-Path $logDirectory 'stdout.log'),
        (Join-Path $logDirectory 'stderr.log'),
        $extraEnv
    )
}
catch {
    try {
        if (-not [IO.Directory]::Exists($logDirectory)) {
            [void][IO.Directory]::CreateDirectory($logDirectory)
        }
        $message = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message
        [IO.File]::AppendAllText($wrapperErrorPath, $message + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch {}
    $exitCode = 1
}
exit $exitCode
'@

