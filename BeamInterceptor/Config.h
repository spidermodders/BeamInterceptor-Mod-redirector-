#pragma once
#include <string>
#include <windows.h>

namespace Config {
    struct Settings {
        bool showConsole = true;
        bool debugInterception = true;
        std::string modDir;
        bool enabled = true;
        std::string dllDirectory;
        std::string redirectModPath;
    };

    extern Settings settings;

    void Initialize();
    void CreateDefault();
    void Load();
    std::string GetConfigPath();
}