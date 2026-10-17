#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
void RegisterQingzhouRuntime(flutter::BinaryMessenger* messenger, HWND window);
bool HandleQingzhouResult(UINT message, LPARAM value);
