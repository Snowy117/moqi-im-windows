#include <windows.h>

#include <shellapi.h>

#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr int kExitSuccess = 0;
constexpr int kExitFailure = 1;
constexpr int kExitRestartRequired = 2;
constexpr int kExitInvalidArgs = 3;
constexpr wchar_t kProgramDirEnvVar[] = L"MOQI_PROGRAM_DIR";
constexpr wchar_t kReregisterTaskName[] = L"MoqiIM-ReRegisterTSF";
constexpr wchar_t kLauncherAutostartTaskName[] = L"MoqiIM-LauncherAutoStart";

enum class Action {
  kHelp,
  kInstall,
  kReregister,
  kUninstall,
};

struct Options {
  Action action = Action::kHelp;
  bool silent = false;
  std::wstring app_dir;
};

bool NeedsCommandLineQuoting(const std::wstring& value) {
  if (value.empty()) {
    return true;
  }
  for (const wchar_t ch : value) {
    if (ch == L' ' || ch == L'\t' || ch == L'"') {
      return true;
    }
  }
  return false;
}

std::wstring QuoteCommandLineArgument(const std::wstring& value) {
  if (!NeedsCommandLineQuoting(value)) {
    return value;
  }

  std::wstring quoted;
  quoted.push_back(L'"');
  size_t backslash_count = 0;
  for (const wchar_t ch : value) {
    if (ch == L'\\') {
      ++backslash_count;
      continue;
    }

    if (ch == L'"') {
      quoted.append(backslash_count * 2 + 1, L'\\');
      quoted.push_back(L'"');
      backslash_count = 0;
      continue;
    }

    quoted.append(backslash_count, L'\\');
    backslash_count = 0;
    quoted.push_back(ch);
  }

  quoted.append(backslash_count * 2, L'\\');
  quoted.push_back(L'"');
  return quoted;
}

std::wstring FormatWindowsErrorMessage(const DWORD error_code) {
  if (error_code == 0) {
    return L"Win32 error 0";
  }

  LPWSTR buffer = nullptr;
  const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER |
                      FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS;
  const DWORD length = FormatMessageW(flags, nullptr, error_code, 0,
                                      reinterpret_cast<LPWSTR>(&buffer), 0,
                                      nullptr);
  std::wstring message = L"Win32 error " + std::to_wstring(error_code);
  if (length > 0 && buffer != nullptr) {
    DWORD trimmed_length = length;
    while (trimmed_length > 0 &&
           (buffer[trimmed_length - 1] == L'\r' ||
            buffer[trimmed_length - 1] == L'\n')) {
      buffer[trimmed_length - 1] = L'\0';
      --trimmed_length;
    }
    if (*buffer != L'\0') {
      message += L": ";
      message += buffer;
    }
  }
  if (buffer != nullptr) {
    LocalFree(buffer);
  }
  return message;
}

std::wstring GetModulePath() {
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const DWORD written = GetModuleFileNameW(nullptr, path.data(),
                                             static_cast<DWORD>(path.size()));
    if (written == 0) {
      return L"";
    }
    if (written < path.size() - 1) {
      path.resize(written);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring GetModuleDirectory() {
  const fs::path module_path(GetModulePath());
  return module_path.parent_path().wstring();
}

std::wstring JoinArguments(const std::vector<std::wstring>& args,
                           const size_t start_index) {
  std::wstring result;
  for (size_t i = start_index; i < args.size(); ++i) {
    if (!result.empty()) {
      result += L' ';
    }
    result += QuoteCommandLineArgument(args[i]);
  }
  return result;
}

void ShowMessage(const std::wstring& text,
                 const std::wstring& caption,
                 const UINT flags,
                 const bool silent) {
  if (!silent) {
    MessageBoxW(nullptr, text.c_str(), caption.c_str(), flags);
  }
}

std::vector<std::wstring> GetCommandLineArguments() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return {};
  }

  std::vector<std::wstring> args;
  args.reserve(argc);
  for (int i = 0; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  LocalFree(argv);
  return args;
}

bool IsRunningAsAdmin() {
  BOOL is_admin = FALSE;
  SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
  PSID admin_group = nullptr;
  if (!AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                &admin_group)) {
    return false;
  }

  if (!CheckTokenMembership(nullptr, admin_group, &is_admin)) {
    is_admin = FALSE;
  }
  FreeSid(admin_group);
  return is_admin == TRUE;
}

int RestartElevated(const std::vector<std::wstring>& args, const bool silent) {
  SHELLEXECUTEINFOW exec_info = {};
  exec_info.cbSize = sizeof(exec_info);
  exec_info.fMask = SEE_MASK_NOCLOSEPROCESS;
  exec_info.lpVerb = L"runas";
  const std::wstring module_path = GetModulePath();
  const std::wstring parameters = JoinArguments(args, 1);
  exec_info.lpFile = module_path.c_str();
  exec_info.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
  exec_info.nShow = silent ? SW_HIDE : SW_SHOWNORMAL;

  if (!ShellExecuteExW(&exec_info)) {
    return kExitFailure;
  }

  WaitForSingleObject(exec_info.hProcess, INFINITE);
  DWORD exit_code = kExitFailure;
  if (!GetExitCodeProcess(exec_info.hProcess, &exit_code)) {
    exit_code = kExitFailure;
  }
  CloseHandle(exec_info.hProcess);
  return static_cast<int>(exit_code);
}

std::wstring GetWindowsDirectoryPath() {
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const UINT written =
        GetWindowsDirectoryW(path.data(), static_cast<UINT>(path.size()));
    if (written == 0) {
      return L"";
    }
    if (written < path.size()) {
      path.resize(written);
      return path;
    }
    path.resize(written + 1);
  }
}

std::wstring GetSyswow64DirectoryPath() {
  std::wstring path(MAX_PATH, L'\0');
  const UINT written =
      GetSystemWow64DirectoryW(path.data(), static_cast<UINT>(path.size()));
  if (written > 0 && written < path.size()) {
    path.resize(written);
    return path;
  }

  const UINT fallback =
      GetSystemDirectoryW(path.data(), static_cast<UINT>(path.size()));
  if (fallback == 0) {
    return L"";
  }
  path.resize(fallback);
  return path;
}

std::wstring GetNativeSystemDirectoryPath() {
  const fs::path sysnative =
      fs::path(GetWindowsDirectoryPath()) / L"Sysnative";
  if (fs::exists(sysnative)) {
    return sysnative.wstring();
  }

  std::wstring path(MAX_PATH, L'\0');
  const UINT written =
      GetSystemDirectoryW(path.data(), static_cast<UINT>(path.size()));
  if (written == 0) {
    return L"";
  }
  path.resize(written);
  return path;
}

std::wstring GetNativeSystemDirectoryForChildProcess() {
  return (fs::path(GetWindowsDirectoryPath()) / L"System32").wstring();
}

std::wstring NormalizePathForPendingOperation(const std::wstring& path) {
  const std::wstring sysnative_prefix =
      fs::path(GetWindowsDirectoryPath() + L"\\Sysnative").wstring() + L"\\";
  if (_wcsnicmp(path.c_str(), sysnative_prefix.c_str(),
                sysnative_prefix.length()) == 0) {
    return (fs::path(GetWindowsDirectoryPath()) / L"System32" /
            path.substr(sysnative_prefix.length()))
        .wstring();
  }
  return path;
}

#ifndef IMAGE_FILE_MACHINE_ARM64
#define IMAGE_FILE_MACHINE_ARM64 0xAA64
#endif

bool IsArm64Machine() {
  using IsWow64Process2Fn = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
  static IsWow64Process2Fn is_wow64_process_2 =
      reinterpret_cast<IsWow64Process2Fn>(::GetProcAddress(
          ::GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2"));
  if (is_wow64_process_2 == nullptr) {
    return false;
  }
  USHORT process_machine = 0;
  USHORT native_machine = 0;
  if (!is_wow64_process_2(::GetCurrentProcess(), &process_machine,
                          &native_machine)) {
    return false;
  }
  return native_machine == IMAGE_FILE_MACHINE_ARM64;
}

std::wstring GetRealSystem32DirectoryPath() {
  return (fs::path(GetWindowsDirectoryPath()) / L"System32").wstring();
}

class Wow64FsRedirectionScope {
 public:
  Wow64FsRedirectionScope() {
    disabled_ = ::Wow64DisableWow64FsRedirection(&previous_value_) == TRUE;
  }

  ~Wow64FsRedirectionScope() {
    if (disabled_) {
      ::Wow64RevertWow64FsRedirection(previous_value_);
    }
  }

  Wow64FsRedirectionScope(const Wow64FsRedirectionScope&) = delete;
  Wow64FsRedirectionScope& operator=(const Wow64FsRedirectionScope&) = delete;

  bool disabled() const { return disabled_; }

 private:
  PVOID previous_value_ = nullptr;
  bool disabled_ = false;
};

struct Arm64SystemTargets {
  fs::path native_dll;   // System32\MoqiTextServiceARM64.dll
  fs::path x64_dll;      // System32\MoqiTextServiceX64.dll
  fs::path forwarder;    // System32\MoqiTextService.dll (ARM64X)
  fs::path regsvr32;     // System32\regsvr32.exe (native ARM64)
};

Arm64SystemTargets GetArm64SystemTargets() {
  const fs::path system32 = fs::path(GetRealSystem32DirectoryPath());
  Arm64SystemTargets targets;
  targets.native_dll = system32 / L"MoqiTextServiceARM64.dll";
  targets.x64_dll = system32 / L"MoqiTextServiceX64.dll";
  targets.forwarder = system32 / L"MoqiTextService.dll";
  targets.regsvr32 = system32 / L"regsvr32.exe";
  return targets;
}

bool RunProcess(const std::wstring& application_path,
                std::wstring command,
                const std::wstring& working_dir,
                DWORD* exit_code,
                DWORD* error_code = nullptr) {
  if (error_code != nullptr) {
    *error_code = 0;
  }
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESHOWWINDOW;
  startup_info.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process_info = {};

  const BOOL created =
      CreateProcessW(application_path.c_str(), command.data(), nullptr, nullptr,
                     FALSE, 0, nullptr,
                     working_dir.empty() ? nullptr : working_dir.c_str(),
                     &startup_info, &process_info);
  if (!created) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    return false;
  }

  WaitForSingleObject(process_info.hProcess, INFINITE);
  DWORD process_exit_code = 0;
  const BOOL got_exit_code =
      GetExitCodeProcess(process_info.hProcess, &process_exit_code);
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);
  if (exit_code != nullptr) {
    *exit_code = got_exit_code ? process_exit_code : static_cast<DWORD>(-1);
  }
  if (!got_exit_code && error_code != nullptr) {
    *error_code = GetLastError();
  }
  return got_exit_code == TRUE;
}

bool RunRegsvr(const fs::path& regsvr_path,
               const fs::path& dll_path_for_process,
               const fs::path& program_dir,
               const bool unregister) {
  if (!fs::exists(dll_path_for_process)) {
    return true;
  }

  std::wstring command = QuoteCommandLineArgument(regsvr_path.wstring());
  if (unregister) {
    command += L" /u";
  }
  command += L" /s " + QuoteCommandLineArgument(dll_path_for_process.wstring());

  std::wstring mutable_command = command;
  std::wstring working_dir = dll_path_for_process.parent_path().wstring();
  std::wstring previous_program_dir;
  const DWORD previous_len = GetEnvironmentVariableW(kProgramDirEnvVar, nullptr, 0);
  if (previous_len > 0) {
    previous_program_dir.resize(previous_len - 1);
    GetEnvironmentVariableW(kProgramDirEnvVar, previous_program_dir.data(), previous_len);
  }
  SetEnvironmentVariableW(kProgramDirEnvVar, program_dir.c_str());

  DWORD exit_code = 0;
  const bool ran =
      RunProcess(regsvr_path.wstring(), mutable_command, working_dir, &exit_code);
  if (previous_len > 0) {
    SetEnvironmentVariableW(kProgramDirEnvVar, previous_program_dir.c_str());
  } else {
    SetEnvironmentVariableW(kProgramDirEnvVar, nullptr);
  }
  if (!ran) {
    return false;
  }
  return exit_code == 0;
}

fs::path BuildOldPath(const fs::path& destination) {
  for (int i = 0; i < 16; ++i) {
    fs::path old_path = destination;
    old_path += L".old." + std::to_wstring(i);
    if (!fs::exists(old_path)) {
      return old_path;
    }
  }
  fs::path old_path = destination;
  old_path += L".old";
  return old_path;
}

fs::path BuildPendingRebootPath(const fs::path& source) {
  for (int i = 0; i < 16; ++i) {
    fs::path pending_path = source;
    pending_path += L".pending.reboot." + std::to_wstring(i);
    if (!fs::exists(pending_path)) {
      return pending_path;
    }
  }
  fs::path pending_path = source;
  pending_path += L".pending.reboot";
  return pending_path;
}

void CleanupStalePendingFiles(const fs::path& destination) {
  std::error_code ec;
  const fs::path directory = destination.parent_path();
  if (!fs::exists(directory, ec)) {
    return;
  }

  const std::wstring prefix = destination.filename().wstring() + L".pending.";
  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec || !entry.is_regular_file(ec)) {
      continue;
    }
    const std::wstring name = entry.path().filename().wstring();
    if (name.rfind(prefix, 0) == 0) {
      fs::remove(entry.path(), ec);
      ec.clear();
    }
  }
}

void CleanupStaleRebootCopies(const fs::path& source) {
  std::error_code ec;
  const fs::path directory = source.parent_path();
  if (!fs::exists(directory, ec)) {
    return;
  }

  const std::wstring prefix = source.filename().wstring() + L".pending.reboot";
  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec || !entry.is_regular_file(ec)) {
      continue;
    }
    const std::wstring name = entry.path().filename().wstring();
    if (name.rfind(prefix, 0) == 0) {
      fs::remove(entry.path(), ec);
      ec.clear();
    }
  }
}

bool RenameFileForDeleteOnReboot(const fs::path& path, bool& reboot_required) {
  if (!fs::exists(path)) {
    return true;
  }

  const fs::path old_path = BuildOldPath(path);
  if (MoveFileExW(path.c_str(), old_path.c_str(), MOVEFILE_REPLACE_EXISTING) ==
      TRUE) {
    const std::wstring pending_delete_path =
        NormalizePathForPendingOperation(old_path.wstring());
    if (MoveFileExW(pending_delete_path.c_str(), nullptr,
                    MOVEFILE_DELAY_UNTIL_REBOOT) ==
        TRUE) {
      reboot_required = true;
      return true;
    }
    MoveFileExW(old_path.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
    return false;
  }
  return false;
}

bool ScheduleReplaceOnReboot(const fs::path& source,
                            const fs::path& destination,
                            bool& reboot_required,
                            std::wstring* error) {
  CleanupStaleRebootCopies(source);

  const fs::path staged_source = BuildPendingRebootPath(source);
  if (CopyFileW(source.c_str(), staged_source.c_str(), FALSE) != TRUE) {
    if (error != nullptr) {
      *error = L"Failed to create staged reboot copy " + staged_source.wstring() +
               L" (" + FormatWindowsErrorMessage(GetLastError()) + L").";
    }
    return false;
  }

  const std::wstring normalized_staged_source =
      NormalizePathForPendingOperation(staged_source.wstring());
  const std::wstring normalized_destination =
      NormalizePathForPendingOperation(destination.wstring());
  if (MoveFileExW(normalized_staged_source.c_str(),
                  normalized_destination.c_str(),
                  MOVEFILE_DELAY_UNTIL_REBOOT | MOVEFILE_REPLACE_EXISTING) !=
      TRUE) {
    const DWORD move_error = GetLastError();
    std::error_code ec;
    fs::remove(staged_source, ec);
    if (error != nullptr) {
      *error = L"Failed to schedule reboot replacement from " +
               staged_source.wstring() + L" to " + destination.wstring() +
               L" (" + FormatWindowsErrorMessage(move_error) + L").";
    }
    return false;
  }

  reboot_required = true;
  if (error != nullptr) {
    error->clear();
  }
  return true;
}

void CleanupStaleOldFiles(const fs::path& destination) {
  std::error_code ec;
  const fs::path directory = destination.parent_path();
  if (!fs::exists(directory, ec)) {
    return;
  }

  const std::wstring prefix = destination.filename().wstring() + L".old";
  for (const auto& entry : fs::directory_iterator(directory, ec)) {
    if (ec || !entry.is_regular_file(ec)) {
      continue;
    }
    const std::wstring name = entry.path().filename().wstring();
    if (name.rfind(prefix, 0) == 0) {
      fs::remove(entry.path(), ec);
      ec.clear();
    }
  }
}

bool DeleteReregisterTask() {
  const fs::path schtasks =
      fs::path(GetNativeSystemDirectoryForChildProcess()) / L"schtasks.exe";
  std::wstring command = QuoteCommandLineArgument(schtasks.wstring()) +
                         L" /Delete /TN " +
                         QuoteCommandLineArgument(kReregisterTaskName) + L" /F";
  DWORD exit_code = 0;
  if (!RunProcess(schtasks.wstring(), command, GetModuleDirectory(), &exit_code)) {
    return false;
  }
  return exit_code == 0 || exit_code == 1;
}

// Create a per-user "at logon" scheduled task that starts MoqiLauncher.exe.
// This is a backup for the HKCU Run key: it runs in the interactive user
// session even if the Run key is disabled/delayed, so by the time the TSF
// framework activates Moqi at logon the launcher pipe is already listening.
// Best-effort only: failure must not fail the install (the Run key remains the
// primary autostart path).
bool ScheduleLauncherAutostartTask(const Options& options, std::wstring* error) {
  const fs::path launcher_path =
      fs::path(options.app_dir) / L"MoqiLauncher.exe";
  if (!fs::exists(launcher_path)) {
    if (error != nullptr) {
      *error = L"MoqiLauncher.exe not found in app dir; skip autostart task.";
    }
    return false;
  }
  const fs::path schtasks =
      fs::path(GetNativeSystemDirectoryForChildProcess()) / L"schtasks.exe";
  const std::wstring task_command = QuoteCommandLineArgument(launcher_path.wstring());
  std::wstring command = QuoteCommandLineArgument(schtasks.wstring()) +
                         L" /Create /TN " +
                         QuoteCommandLineArgument(kLauncherAutostartTaskName) +
                         L" /SC ONLOGON /TR " +
                         QuoteCommandLineArgument(task_command) + L" /F";
  DWORD exit_code = 0;
  DWORD error_code = 0;
  if (!RunProcess(schtasks.wstring(), command, GetModuleDirectory(), &exit_code,
                  &error_code)) {
    if (error != nullptr) {
      *error = L"Failed to launch schtasks.exe (" +
               FormatWindowsErrorMessage(error_code) + L").";
    }
    return false;
  }
  if (exit_code != 0) {
    if (error != nullptr) {
      *error = L"Failed to schedule launcher autostart task (schtasks exit code " +
               std::to_wstring(exit_code) + L").";
    }
    return false;
  }
  return true;
}

bool DeleteLauncherAutostartTask() {
  const fs::path schtasks =
      fs::path(GetNativeSystemDirectoryForChildProcess()) / L"schtasks.exe";
  std::wstring command = QuoteCommandLineArgument(schtasks.wstring()) +
                         L" /Delete /TN " +
                         QuoteCommandLineArgument(kLauncherAutostartTaskName) +
                         L" /F";
  DWORD exit_code = 0;
  if (!RunProcess(schtasks.wstring(), command, GetModuleDirectory(), &exit_code)) {
    return false;
  }
  return exit_code == 0 || exit_code == 1;
}

bool ScheduleReregisterTask(const Options& options, std::wstring& error) {
  const fs::path schtasks =
      fs::path(GetNativeSystemDirectoryForChildProcess()) / L"schtasks.exe";
  const std::wstring task_command =
      QuoteCommandLineArgument(GetModulePath()) + L" /r /s --appdir " +
      QuoteCommandLineArgument(options.app_dir);
  std::wstring command = QuoteCommandLineArgument(schtasks.wstring()) +
                         L" /Create /TN " +
                         QuoteCommandLineArgument(kReregisterTaskName) +
                         L" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR " +
                         QuoteCommandLineArgument(task_command) + L" /F";
  DWORD exit_code = 0;
  DWORD error_code = 0;
  if (!RunProcess(schtasks.wstring(), command, GetModuleDirectory(), &exit_code,
                  &error_code)) {
    error = L"Failed to launch schtasks.exe (" +
            FormatWindowsErrorMessage(error_code) + L").";
    return false;
  }
  if (exit_code != 0) {
    error = L"Failed to schedule TSF re-registration after reboot "
            L"(schtasks exit code " +
            std::to_wstring(exit_code) + L").";
    return false;
  }
  return true;
}

bool DeleteFileWithFallback(const fs::path& path, bool& reboot_required) {
  if (!fs::exists(path)) {
    return true;
  }
  if (DeleteFileW(path.c_str()) == TRUE) {
    return true;
  }
  return RenameFileForDeleteOnReboot(path, reboot_required);
}

bool CopyFileWithFallback(const fs::path& source,
                         const fs::path& destination,
                         bool& reboot_required,
                         std::wstring* error,
                         DWORD* initial_copy_error = nullptr,
                         DWORD* fallback_error = nullptr) {
  if (initial_copy_error != nullptr) {
    *initial_copy_error = 0;
  }
  if (fallback_error != nullptr) {
    *fallback_error = 0;
  }
  if (!fs::exists(source)) {
    if (error != nullptr) {
      *error = L"Source file does not exist: " + source.wstring();
    }
    return false;
  }
  CleanupStalePendingFiles(destination);
  if (CopyFileW(source.c_str(), destination.c_str(), FALSE) == TRUE) {
    if (error != nullptr) {
      error->clear();
    }
    return true;
  }
  const DWORD initial_copy_error_code = GetLastError();
  if (initial_copy_error != nullptr) {
    *initial_copy_error = initial_copy_error_code;
  }
  if (RenameFileForDeleteOnReboot(destination, reboot_required)) {
    if (CopyFileW(source.c_str(), destination.c_str(), FALSE) == TRUE) {
      if (error != nullptr) {
        error->clear();
      }
      CleanupStalePendingFiles(destination);
      return true;
    }
    const DWORD retry_copy_error = GetLastError();
    if (fallback_error != nullptr) {
      *fallback_error = retry_copy_error;
    }
    if (error != nullptr) {
      *error = L"Initial copy failed (" +
               FormatWindowsErrorMessage(initial_copy_error_code) +
               L"); existing destination was scheduled for delete-on-reboot, "
               L"but retry copy also failed (" +
               FormatWindowsErrorMessage(retry_copy_error) + L").";
    }
    return false;
  }
  if (error != nullptr) {
    const DWORD rename_error = GetLastError();
    if (fallback_error != nullptr) {
      *fallback_error = rename_error;
    }
    *error = L"Initial copy failed (" +
             FormatWindowsErrorMessage(initial_copy_error_code) +
             L"); fallback rename/delete-on-reboot also failed (" +
             FormatWindowsErrorMessage(rename_error) + L").";
  }
  return false;
}

bool DeploySystemDll(const fs::path& source,
                     const fs::path& destination,
                     bool& reboot_required,
                     std::wstring* error) {
  DWORD initial_copy_error = 0;
  DWORD fallback_error = 0;
  if (CopyFileWithFallback(source, destination, reboot_required, error,
                           &initial_copy_error, &fallback_error)) {
    return true;
  }
  if ((initial_copy_error == ERROR_SHARING_VIOLATION ||
       initial_copy_error == ERROR_ACCESS_DENIED ||
       fallback_error == ERROR_SHARING_VIOLATION ||
       fallback_error == ERROR_ACCESS_DENIED) &&
      ScheduleReplaceOnReboot(source, destination, reboot_required, error)) {
    return true;
  }
  return false;
}

int ShowFailureAndReturn(const std::wstring& message, const bool silent) {
  ShowMessage(message, L"SetupHelper", MB_ICONERROR | MB_OK, silent);
  return kExitFailure;
}

int RunReregister(const Options& options) {
  const fs::path app_dir(options.app_dir);
  const fs::path source32 = app_dir / L"MoqiTextService.dll";
  const fs::path source64 = app_dir / L"x64" / L"MoqiTextService.dll";
  const fs::path dest32 = fs::path(GetSyswow64DirectoryPath()) / L"MoqiTextService.dll";
  const bool is_arm64 = IsArm64Machine();
  const Arm64SystemTargets arm64_targets = GetArm64SystemTargets();
  const fs::path dest64 = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryPath()) / L"MoqiTextService.dll";
  const fs::path dest64_for_regsvr = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryForChildProcess()) / L"MoqiTextService.dll";
  const fs::path regsvr32 = fs::path(GetSyswow64DirectoryPath()) / L"regsvr32.exe";
  const fs::path regsvr64 = is_arm64
      ? arm64_targets.regsvr32
      : fs::path(GetNativeSystemDirectoryPath()) / L"regsvr32.exe";

  CleanupStaleOldFiles(dest32);
  CleanupStaleRebootCopies(source32);
  CleanupStaleRebootCopies(source64);
  if (!is_arm64) {
    CleanupStaleOldFiles(dest64);
  }

  if (!RunRegsvr(regsvr32, dest32, app_dir, false)) {
    return ShowFailureAndReturn(L"Failed to register Win32 TSF DLL.",
                                options.silent);
  }
  if (is_arm64) {
    Wow64FsRedirectionScope redirection_scope;
    if (!redirection_scope.disabled()) {
      return ShowFailureAndReturn(L"Failed to register ARM64 TSF DLL.",
                                  options.silent);
    }
    CleanupStaleOldFiles(arm64_targets.forwarder);
    CleanupStaleOldFiles(arm64_targets.native_dll);
    CleanupStaleOldFiles(arm64_targets.x64_dll);
    if (!RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, false)) {
      return ShowFailureAndReturn(L"Failed to register ARM64 TSF DLL.",
                                  options.silent);
    }
  } else if (!RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, false)) {
    return ShowFailureAndReturn(L"Failed to register x64 TSF DLL.",
                                options.silent);
  }
  DeleteReregisterTask();
  return kExitSuccess;
}

int RunInstall(const Options& options) {
  const fs::path app_dir(options.app_dir);
  const fs::path source32 = app_dir / L"MoqiTextService.dll";
  const fs::path source64 = app_dir / L"x64" / L"MoqiTextService.dll";
  // TSF DLLs must live in system directories, or IME input will not work in
  // some games such as CS2.
  const bool is_arm64 = IsArm64Machine();
  const Arm64SystemTargets arm64_targets = GetArm64SystemTargets();
  const fs::path source_arm64_native =
      app_dir / L"arm64" / L"MoqiTextService.dll";
  const fs::path source_arm64_forwarder =
      app_dir / L"arm64" / L"MoqiTextServiceARM64X.dll";
  const fs::path dest32 = fs::path(GetSyswow64DirectoryPath()) / L"MoqiTextService.dll";
  const fs::path dest64 = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryPath()) / L"MoqiTextService.dll";
  const fs::path dest64_for_regsvr = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryForChildProcess()) / L"MoqiTextService.dll";
  const fs::path regsvr32 = fs::path(GetSyswow64DirectoryPath()) / L"regsvr32.exe";
  const fs::path regsvr64 = is_arm64
      ? arm64_targets.regsvr32
      : fs::path(GetNativeSystemDirectoryPath()) / L"regsvr32.exe";

  if (!fs::exists(source32)) {
    return ShowFailureAndReturn(L"Missing Win32 payload: " + source32.wstring(),
                                options.silent);
  }
  if (!fs::exists(source64)) {
    return ShowFailureAndReturn(L"Missing x64 payload: " + source64.wstring(),
                                options.silent);
  }
  if (is_arm64 && (!fs::exists(source_arm64_native) ||
                   !fs::exists(source_arm64_forwarder))) {
    return ShowFailureAndReturn(
        L"This ARM64 machine requires the ARM64 payload under "
        + (app_dir / L"arm64").wstring() +
            L", which is missing. Reinstall with a setup built for ARM64.",
        options.silent);
  }

  DeleteReregisterTask();
  // During an in-place reinstall/upgrade, unregistering first removes the TIP
  // from the user's language profile list. Re-registering the DLL does not
  // always restore that list entry reliably, so keep the existing registration
  // in place and overwrite the system DLLs before registering again.

  bool reboot_required = false;
  std::wstring copy_error;
  if (!DeploySystemDll(source32, dest32, reboot_required, &copy_error)) {
    return ShowFailureAndReturn(
        L"Failed to update Win32 TSF DLL in " + dest32.wstring() + L"\n\n" +
            copy_error,
        options.silent);
  }

  if (is_arm64) {
    // System32\MoqiTextService.dll is the ARM64X forwarder; ARM64 native
    // processes load MoqiTextServiceARM64.dll through it and x64 emulation
    // processes load MoqiTextServiceX64.dll. Only the forwarder is registered.
    Wow64FsRedirectionScope redirection_scope;
    if (!redirection_scope.disabled()) {
      return ShowFailureAndReturn(L"Failed to disable WOW64 file system "
                                  L"redirection for ARM64 deployment.",
                                  options.silent);
    }
    if (!DeploySystemDll(source_arm64_native, arm64_targets.native_dll,
                         reboot_required, &copy_error) ||
        !DeploySystemDll(source64, arm64_targets.x64_dll, reboot_required,
                         &copy_error) ||
        !DeploySystemDll(source_arm64_forwarder, arm64_targets.forwarder,
                         reboot_required, &copy_error)) {
      return ShowFailureAndReturn(
          L"Failed to update ARM64 TSF DLLs in System32.\n\n" + copy_error,
          options.silent);
    }
  } else {
    if (!DeploySystemDll(source64, dest64, reboot_required, &copy_error)) {
      return ShowFailureAndReturn(
          L"Failed to update x64 TSF DLL in " + dest64.wstring() + L"\n\n" +
              copy_error,
          options.silent);
    }
  }

  if (reboot_required) {
    std::wstring schedule_error;
    if (!ScheduleReregisterTask(options, schedule_error)) {
      return ShowFailureAndReturn(schedule_error, options.silent);
    }
    return kExitRestartRequired;
  }

  if (!RunRegsvr(regsvr32, dest32, app_dir, false)) {
    return ShowFailureAndReturn(L"Failed to register Win32 TSF DLL.",
                                options.silent);
  }
  if (is_arm64) {
    Wow64FsRedirectionScope redirection_scope;
    if (!redirection_scope.disabled() ||
        !RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, false)) {
      return ShowFailureAndReturn(L"Failed to register ARM64 TSF DLL.",
                                  options.silent);
    }
  } else if (!RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, false)) {
    return ShowFailureAndReturn(L"Failed to register x64 TSF DLL.",
                                options.silent);
  }
  // Backup autostart for the launcher (the HKCU Run key remains primary).
  std::wstring autostart_error;
  ScheduleLauncherAutostartTask(options, &autostart_error);
  return kExitSuccess;
}

int RunUninstall(const Options& options) {
  const fs::path app_dir(options.app_dir);
  const bool is_arm64 = IsArm64Machine();
  const Arm64SystemTargets arm64_targets = GetArm64SystemTargets();
  const fs::path dest32 = fs::path(GetSyswow64DirectoryPath()) / L"MoqiTextService.dll";
  const fs::path dest64 = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryPath()) / L"MoqiTextService.dll";
  const fs::path dest64_for_regsvr = is_arm64
      ? arm64_targets.forwarder
      : fs::path(GetNativeSystemDirectoryForChildProcess()) / L"MoqiTextService.dll";
  const fs::path regsvr32 = fs::path(GetSyswow64DirectoryPath()) / L"regsvr32.exe";
  const fs::path regsvr64 = is_arm64
      ? arm64_targets.regsvr32
      : fs::path(GetNativeSystemDirectoryPath()) / L"regsvr32.exe";

  DeleteReregisterTask();
  DeleteLauncherAutostartTask();
  RunRegsvr(regsvr32, dest32, app_dir, true);
  if (is_arm64) {
    Wow64FsRedirectionScope redirection_scope;
    if (redirection_scope.disabled()) {
      RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, true);
    }
  } else {
    RunRegsvr(regsvr64, dest64_for_regsvr, app_dir, true);
  }

  bool reboot_required = false;
  if (!DeleteFileWithFallback(dest32, reboot_required)) {
    return ShowFailureAndReturn(
        L"Failed to remove Win32 TSF DLL from " + dest32.wstring(), options.silent);
  }
  if (is_arm64) {
    Wow64FsRedirectionScope redirection_scope;
    if (!redirection_scope.disabled()) {
      return ShowFailureAndReturn(L"Failed to disable WOW64 file system "
                                  L"redirection for ARM64 cleanup.",
                                  options.silent);
    }
    if (!DeleteFileWithFallback(arm64_targets.forwarder, reboot_required)) {
      return ShowFailureAndReturn(
          L"Failed to remove ARM64 TSF forwarder from " +
              arm64_targets.forwarder.wstring(),
          options.silent);
    }
    DeleteFileWithFallback(arm64_targets.native_dll, reboot_required);
    DeleteFileWithFallback(arm64_targets.x64_dll, reboot_required);
  } else if (!DeleteFileWithFallback(dest64, reboot_required)) {
    return ShowFailureAndReturn(
        L"Failed to remove x64 TSF DLL from " + dest64.wstring(), options.silent);
  }
  return reboot_required ? kExitRestartRequired : kExitSuccess;
}

void ShowUsage() {
  const std::wstring help_text =
      L"Usage: SetupHelper.exe /i|/r|/u [/s] [--appdir <path>]\n"
      L"  /i       Install or upgrade the TSF DLLs.\n"
      L"  /r       Register the TSF DLLs after a reboot.\n"
      L"  /u       Uninstall the TSF DLLs.\n"
      L"  /s       Silent mode.\n"
      L"  --appdir Explicit application directory.\n";
  MessageBoxW(nullptr, help_text.c_str(), L"SetupHelper",
              MB_ICONINFORMATION | MB_OK);
}

bool ParseOptions(const std::vector<std::wstring>& args,
                  Options& options,
                  std::wstring& error) {
  options.app_dir = GetModuleDirectory();

  for (size_t i = 1; i < args.size(); ++i) {
    const std::wstring& arg = args[i];
    if (arg == L"/i") {
      if (options.action != Action::kHelp) {
        error = L"Only one action may be specified.";
        return false;
      }
      options.action = Action::kInstall;
    } else if (arg == L"/r") {
      if (options.action != Action::kHelp) {
        error = L"Only one action may be specified.";
        return false;
      }
      options.action = Action::kReregister;
    } else if (arg == L"/u") {
      if (options.action != Action::kHelp) {
        error = L"Only one action may be specified.";
        return false;
      }
      options.action = Action::kUninstall;
    } else if (arg == L"/s") {
      options.silent = true;
    } else if (arg == L"/?" || arg == L"/help" || arg == L"--help") {
      options.action = Action::kHelp;
    } else if (arg == L"--appdir") {
      if (i + 1 >= args.size()) {
        error = L"--appdir requires a path.";
        return false;
      }
      options.app_dir = args[++i];
    } else if (arg.rfind(L"--appdir=", 0) == 0) {
      options.app_dir = arg.substr(9);
    } else {
      error = L"Unknown argument: " + arg;
      return false;
    }
  }

  if (options.action == Action::kHelp && args.size() > 1 &&
      options.app_dir == GetModuleDirectory()) {
    error = L"No action specified.";
    return false;
  }
  return true;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  const std::vector<std::wstring> args = GetCommandLineArguments();
  Options options;
  std::wstring error;
  if (!ParseOptions(args, options, error)) {
    ShowMessage(error, L"SetupHelper", MB_ICONERROR | MB_OK, false);
    ShowUsage();
    return kExitInvalidArgs;
  }

  if (options.action == Action::kHelp) {
    ShowUsage();
    return kExitSuccess;
  }

  if (!IsRunningAsAdmin()) {
    return RestartElevated(args, options.silent);
  }

  if (options.action == Action::kInstall) {
    return RunInstall(options);
  }
  if (options.action == Action::kReregister) {
    return RunReregister(options);
  }
  return RunUninstall(options);
}
