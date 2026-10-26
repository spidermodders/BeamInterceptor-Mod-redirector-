#pragma once
#include <string>
#include <string_view>

namespace Console {
    void Create();
    void Destroy();
    bool IsActive();
    void OpenLog(const std::wstring& path);   // also mirror every line into a UTF-8 text file

    // All print functions are no-ops while no console is attached.
    void Print(std::string_view message);
    void Print(std::wstring_view message);

    // Helper to print errors with codes easily
    void PrintError(std::string_view message, unsigned long errorCode);
}
