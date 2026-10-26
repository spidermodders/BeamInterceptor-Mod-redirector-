#include "pch.h"
#include "Console.h"
#include "FileUtils.h"
#include <atomic>
#include <mutex>
#include <fstream>
#include <filesystem>

namespace Console {
    static HANDLE g_out = nullptr;
    static std::atomic<bool> g_active{ false };
    static std::atomic<bool> g_logging{ false };
    static std::mutex g_logLock;
    static std::ofstream g_log;

    void Create() {
        if (g_active) return;
        if (!AllocConsole()) return;
        g_out = GetStdHandle(STD_OUTPUT_HANDLE);
        g_active = (g_out != nullptr && g_out != INVALID_HANDLE_VALUE);
    }

    void Destroy() {
        if (!g_active.exchange(false)) return;
        FreeConsole();
        g_out = nullptr;
    }

    bool IsActive() {
        return g_active.load(std::memory_order_relaxed) || g_logging.load(std::memory_order_relaxed);
    }

    void OpenLog(const std::wstring& path) {
        std::lock_guard<std::mutex> lock(g_logLock);
        g_log.open(std::filesystem::path(path), std::ios::trunc);
        g_logging = g_log.is_open();
    }

    void Print(std::wstring_view message) {
        if (!IsActive()) return;
        if (g_active) {
            std::wstring line;
            line.reserve(message.size() + 2);
            line.append(message).append(L"\r\n");
            DWORD written = 0;
            WriteConsoleW(g_out, line.data(), (DWORD)line.size(), &written, nullptr);   // one call per line keeps threads from interleaving
        }
        if (g_logging) {
            const std::string utf8 = Narrow(message);
            std::lock_guard<std::mutex> lock(g_logLock);
            g_log << utf8 << std::endl;
        }
    }

    void Print(std::string_view message) {
        if (!IsActive()) return;
        Print(Widen(message));
    }

    void PrintError(std::string_view message, unsigned long errorCode) {
        if (!IsActive()) return;
        std::string text = "[ERROR] ";
        text.append(message).append(" Code: ").append(std::to_string(errorCode));
        Print(text);
    }
}
