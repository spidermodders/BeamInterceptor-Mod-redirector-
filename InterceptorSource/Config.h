#pragma once
#include <string>
#include <windows.h>

namespace Config {
    struct Settings {
        bool showConsole = false;
        bool debugInterception = false;
        bool enabled = true;
        std::wstring dllDirectory;
        std::wstring modDir;            // as configured (absolute, or relative to dllDirectory)
        std::wstring redirectModPath;   // resolved absolute folder, no trailing slash
    };

    extern Settings settings;

    void Initialize();
    void CreateDefault();
    void Load();
    std::wstring GetConfigPath();
}
