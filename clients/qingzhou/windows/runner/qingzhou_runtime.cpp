#include "qingzhou_runtime.h"
#include <wininet.h>
#include <wincrypt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr UINT kCompleted = WM_APP + 44;
struct Completion {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::string value;
  bool failed = false;
  std::string stage;
  DWORD error = ERROR_SUCCESS;
};
struct ServiceError : std::runtime_error {
  std::string stage;
  DWORD error;
  ServiceError(const char* step, DWORD code)
      : std::runtime_error("Windows 服务通信失败"), stage(step), error(code) {}
};
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
};
void VerifyService(HANDLE pipe) {
  ULONG pid = 0;
  if (!GetNamedPipeServerProcessId(pipe, &pid)) throw ServiceError("verify_pipe_pid", GetLastError());
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) throw ServiceError("verify_scm", GetLastError());
  SC_HANDLE service = OpenServiceW(manager, L"QingzhouProxy", SERVICE_QUERY_STATUS);
  if (!service) {
    DWORD error = GetLastError(); CloseServiceHandle(manager);
    throw ServiceError("verify_service", error);
  }
  SERVICE_STATUS_PROCESS status{}; DWORD bytes = 0;
  BOOL queried = QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes);
  DWORD error = queried ? ERROR_SUCCESS : GetLastError();
  CloseServiceHandle(service); CloseServiceHandle(manager);
  if (!queried) throw ServiceError("verify_status", error);
  if (status.dwCurrentState != SERVICE_RUNNING || status.dwProcessId != pid)
    throw ServiceError("verify_identity", ERROR_ACCESS_DENIED);
}
void Transfer(HANDLE pipe, void* buffer, DWORD size, bool writing, const char* stage) {
  auto* cursor = static_cast<BYTE*>(buffer);
  while (size > 0) {
    Handle event; event.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event.value) throw ServiceError(stage, GetLastError());
    OVERLAPPED operation{}; operation.hEvent = event.value;
    DWORD done = 0;
    BOOL ok = writing ? WriteFile(pipe, cursor, size, &done, &operation)
                      : ReadFile(pipe, cursor, size, &done, &operation);
    if (!ok) {
      DWORD error = GetLastError();
      if (error != ERROR_IO_PENDING) throw ServiceError(stage, error);
      DWORD wait = WaitForSingleObject(event.value, 40000);
      if (wait != WAIT_OBJECT_0) {
        error = wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
        CancelIoEx(pipe, &operation);
        GetOverlappedResult(pipe, &operation, &done, TRUE);
        throw ServiceError(stage, error);
      }
      if (!GetOverlappedResult(pipe, &operation, &done, FALSE)) throw ServiceError(stage, GetLastError());
    }
    if (done == 0) throw ServiceError(stage, ERROR_BROKEN_PIPE);
    cursor += done; size -= done;
  }
}
std::string Request(const std::string& request) {
  if (request.size() > 4 * 1024 * 1024) throw ServiceError("request_size", ERROR_INVALID_DATA);
  if (!WaitNamedPipeW(L"\\\\.\\pipe\\cn.qingzhou.proxy.v1", 5000)) throw ServiceError("wait_pipe", GetLastError());
  Handle pipe;
  pipe.value = CreateFileW(L"\\\\.\\pipe\\cn.qingzhou.proxy.v1", GENERIC_READ | GENERIC_WRITE,
      0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe.value == INVALID_HANDLE_VALUE) throw ServiceError("open_pipe", GetLastError());
  VerifyService(pipe.value);
  DWORD size = static_cast<DWORD>(request.size());
  Transfer(pipe.value, &size, 4, true, "write_header");
  Transfer(pipe.value, const_cast<char*>(request.data()), size, true, "write_body");
  Transfer(pipe.value, &size, 4, false, "read_header");
  if (size > 4 * 1024 * 1024) throw ServiceError("response_size", ERROR_INVALID_DATA);
  std::string reply(size, '\0');
  Transfer(pipe.value, reply.data(), size, false, "read_body");
  return reply;
}
flutter::EncodableValue CheckResult(const char* state, const std::string& code) {
  const char* message = "Windows 代理检测未完成";
  if (code == "invalid_listen_port") message = "尚无有效的本地代理端口";
  else if (code == "proxy_disabled") message = "当前用户未启用 Windows 系统代理";
  else if (code == "automatic_proxy_enabled") message = "已启用自动代理，尚不能确认应用实际采用的代理";
  else if (code == "proxy_endpoint_mismatch") message = "Windows 系统代理未指向轻舟本地端口";
  else if (code == "wininet_proxy_verified") message = "当前用户的 Windows 系统代理已指向轻舟";
  else if (code == "proxy_notified") message = "已通知 Windows 刷新代理设置";
  else if (code.find("wininet_query_") == 0) message = "读取当前用户的 Windows 代理设置失败";
  else if (code.find("proxy_notify_") == 0) message = "Windows 代理设置刷新失败";
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("state"), flutter::EncodableValue(state)},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
      {flutter::EncodableValue("code"), flutter::EncodableValue(code)}});
}
flutter::EncodableValue ProxyStatus(int32_t port) {
  if (port <= 0 || port > 65535) return CheckResult("unverified", "invalid_listen_port");
  INTERNET_PER_CONN_OPTIONW options[3]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 3;
  list.pOptions = options;
  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
    DWORD error = GetLastError();
    // WinINET 返回的字符串由调用方释放，且绝不跨桥接传递代理地址。
    if (options[1].Value.pszValue) GlobalFree(options[1].Value.pszValue);
    if (options[2].Value.pszValue) GlobalFree(options[2].Value.pszValue);
    return CheckResult("failed", "wininet_query_" + std::to_string(error));
  }
  DWORD flags = options[0].Value.dwValue;
  std::wstring server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  if (options[1].Value.pszValue) GlobalFree(options[1].Value.pszValue);
  if (options[2].Value.pszValue) GlobalFree(options[2].Value.pszValue);
  if (flags & (PROXY_TYPE_AUTO_PROXY_URL | PROXY_TYPE_AUTO_DETECT))
    return CheckResult("unverified", "automatic_proxy_enabled");
  if (!(flags & PROXY_TYPE_PROXY)) return CheckResult("failed", "proxy_disabled");
  if (server != L"127.0.0.1:" + std::to_wstring(port))
    return CheckResult("failed", "proxy_endpoint_mismatch");
  return CheckResult("passed", "wininet_proxy_verified");
}
}
void RegisterQingzhouRuntime(flutter::BinaryMessenger* messenger, HWND window) {
  flutter::MethodChannel<flutter::EncodableValue> channel(messenger, "cn.qingzhou/runtime", &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() == "protectSecret" || call.method_name() == "unprotectSecret") {
      const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
      if (!bytes || bytes->empty() || bytes->size() > 65536) {
        result->Error("storage", "凭据密钥格式无效"); return;
      }
      DATA_BLOB input{static_cast<DWORD>(bytes->size()), const_cast<BYTE*>(bytes->data())};
      DATA_BLOB output{};
      BOOL ok = call.method_name() == "protectSecret"
          ? CryptProtectData(&input, L"Qingzhou snapshot key", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)
          : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output);
      if (!ok) { result->Error("storage", "Windows DPAPI 操作失败"); return; }
      std::vector<uint8_t> value(output.pbData, output.pbData + output.cbData);
      SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
      result->Success(flutter::EncodableValue(value)); return;
    }
    if (call.method_name() == "notifyProxy") {
      DWORD error = ERROR_SUCCESS;
      if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0)) error = GetLastError();
      if (!InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) && error == ERROR_SUCCESS) error = GetLastError();
      DWORD_PTR ignored = 0;
      SetLastError(ERROR_SUCCESS);
      if (!SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
          reinterpret_cast<LPARAM>(L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"),
          SMTO_ABORTIFHUNG, 1000, &ignored) && error == ERROR_SUCCESS) {
        error = GetLastError();
        if (error == ERROR_SUCCESS) error = ERROR_TIMEOUT;
      }
      result->Success(CheckResult(error == ERROR_SUCCESS ? "passed" : "failed",
          error == ERROR_SUCCESS ? "proxy_notified" : "proxy_notify_" + std::to_string(error))); return;
    }
    if (call.method_name() == "proxyStatus") {
      const auto* port = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
      result->Success(port ? ProxyStatus(*port) : CheckResult("unverified", "invalid_listen_port")); return;
    }
    if (call.method_name() != "rpc") { result->NotImplemented(); return; }
    auto* raw = std::get_if<std::string>(call.arguments());
    if (!raw) { result->Error("request", "运行请求无效"); return; }
    auto completion = std::make_unique<Completion>(); completion->result = std::move(result);
    std::thread([window, request = *raw, completion = std::move(completion)]() mutable {
      try { completion->value = Request(request); }
      catch (const ServiceError& error) {
        completion->failed = true;
        completion->stage = error.stage;
        completion->error = error.error;
      } catch (const std::exception&) {
        completion->failed = true;
        completion->stage = "bridge_internal";
        completion->error = ERROR_UNHANDLED_EXCEPTION;
      }
      auto* payload = completion.release();
      if (!PostMessageW(window, kCompleted, 0, reinterpret_cast<LPARAM>(payload))) delete payload;
    }).detach();
  });
}
bool HandleQingzhouResult(UINT message, LPARAM value) {
  if (message != kCompleted) return false;
  std::unique_ptr<Completion> completion(reinterpret_cast<Completion*>(value));
  if (completion->failed) {
    completion->result->Error("service", "Windows 服务通信失败 (" + completion->stage +
        ", Win32 " + std::to_string(completion->error) + ")",
        flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("stage"), flutter::EncodableValue(completion->stage)},
          {flutter::EncodableValue("win32Error"), flutter::EncodableValue(static_cast<int64_t>(completion->error))}}));
  }
  else completion->result->Success(flutter::EncodableValue(completion->value));
  return true;
}
