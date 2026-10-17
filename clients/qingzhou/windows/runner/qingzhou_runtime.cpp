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
};
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
};
bool VerifyService(HANDLE pipe) {
  ULONG pid = 0;
  if (!GetNamedPipeServerProcessId(pipe, &pid)) return false;
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return false;
  SC_HANDLE service = OpenServiceW(manager, L"QingzhouProxy", SERVICE_QUERY_STATUS);
  if (!service) { CloseServiceHandle(manager); return false; }
  SERVICE_STATUS_PROCESS status{}; DWORD bytes = 0;
  bool valid = QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes) &&
      status.dwCurrentState == SERVICE_RUNNING && status.dwProcessId == pid;
  CloseServiceHandle(service); CloseServiceHandle(manager);
  return valid;
}
bool Transfer(HANDLE pipe, void* buffer, DWORD size, bool writing) {
  auto* cursor = static_cast<BYTE*>(buffer);
  while (size > 0) {
    Handle event; event.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event.value) return false;
    OVERLAPPED operation{}; operation.hEvent = event.value;
    DWORD done = 0;
    BOOL ok = writing ? WriteFile(pipe, cursor, size, &done, &operation)
                      : ReadFile(pipe, cursor, size, &done, &operation);
    if (!ok) {
      if (GetLastError() != ERROR_IO_PENDING) return false;
      if (WaitForSingleObject(event.value, 40000) != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &operation);
        GetOverlappedResult(pipe, &operation, &done, TRUE);
        return false;
      }
      if (!GetOverlappedResult(pipe, &operation, &done, FALSE)) return false;
    }
    if (done == 0) return false;
    cursor += done; size -= done;
  }
  return true;
}
std::string Request(const std::string& request) {
  if (request.size() > 4 * 1024 * 1024) throw std::runtime_error("请求过大");
  if (!WaitNamedPipeW(L"\\\\.\\pipe\\cn.qingzhou.proxy.v1", 5000)) throw std::runtime_error("服务未安装或未启动");
  Handle pipe;
  pipe.value = CreateFileW(L"\\\\.\\pipe\\cn.qingzhou.proxy.v1", GENERIC_READ | GENERIC_WRITE,
      0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
  if (pipe.value == INVALID_HANDLE_VALUE || !VerifyService(pipe.value)) throw std::runtime_error("服务身份校验失败");
  DWORD size = static_cast<DWORD>(request.size());
  if (!Transfer(pipe.value, &size, 4, true) || !Transfer(pipe.value, const_cast<char*>(request.data()), size, true)) throw std::runtime_error("服务写入失败");
  if (!Transfer(pipe.value, &size, 4, false) || size > 4 * 1024 * 1024) throw std::runtime_error("服务响应无效");
  std::string reply(size, '\0');
  if (!Transfer(pipe.value, reply.data(), size, false)) throw std::runtime_error("服务读取失败");
  return reply;
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
      InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
      DWORD_PTR ignored = 0;
      SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0,
          reinterpret_cast<LPARAM>(L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"),
          SMTO_ABORTIFHUNG, 1000, &ignored);
      result->Success(); return;
    }
    if (call.method_name() != "rpc") { result->NotImplemented(); return; }
    auto* raw = std::get_if<std::string>(call.arguments());
    if (!raw) { result->Error("request", "运行请求无效"); return; }
    auto completion = std::make_unique<Completion>(); completion->result = std::move(result);
    std::thread([window, request = *raw, completion = std::move(completion)]() mutable {
      try { completion->value = Request(request); } catch (...) { completion->failed = true; }
      auto* payload = completion.release();
      if (!PostMessageW(window, kCompleted, 0, reinterpret_cast<LPARAM>(payload))) delete payload;
    }).detach();
  });
}
bool HandleQingzhouResult(UINT message, LPARAM value) {
  if (message != kCompleted) return false;
  std::unique_ptr<Completion> completion(reinterpret_cast<Completion*>(value));
  if (completion->failed) completion->result->Error("service", "服务未就绪、身份校验失败或通信超时");
  else completion->result->Success(flutter::EncodableValue(completion->value));
  return true;
}
