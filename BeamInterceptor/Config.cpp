#include "pch.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include <fstream>
#include <sstream>

namespace Config {
    Settings settings;
    const std::string configFileName = "Interceptor.config";

    std::string GetConfigPath() {
        return settings.dllDirectory + "\\" + configFileName;
    }

    void CreateDefault() {
        std::string path = GetConfigPath();
        std::ofstream file(path);
        if (file.is_open()) {
            file << "showConsole=" << (settings.showConsole ? "true" : "false") << "\n";
            file << "debugInterception=" << (settings.debugInterception ? "true" : "false") << "\n";
            file << "modDir=" << settings.modDir << "\n";
            file << "enabled=" << (settings.enabled ? "true" : "false") << "\n";
            file.close();
        }
        else {
            Console::Print("[CONFIG] Error: Could not create default config file.");
        }
    }

    void Load() {
        std::string path = GetConfigPath();
        std::ifstream file(path);
        if (!file.is_open()) {
            CreateDefault();
            return;
        }

        std::string line;
        while (std::getline(file, line)) {
            std::istringstream is_line(line);
            std::string key;
            if (std::getline(is_line, key, '=')) {
                std::string value;
                if (std::getline(is_line, value)) {
                    if (key == "showConsole") settings.showConsole = (value == "true");
                    else if (key == "debugInterception") settings.debugInterception = (value == "true");
                    else if (key == "modDir") settings.modDir = value;
                    else if (key == "enabled") settings.enabled = (value == "true");
                }
            }
        }
        file.close();
    }

    void Initialize() {
        // Set default mod directory relative to DLL
        settings.dllDirectory = GetDllDirectory(NULL);
        settings.modDir = settings.dllDirectory + "\\ModifiedMods";
        settings.redirectModPath = settings.modDir;

        Load();

        if (settings.enabled && settings.showConsole) {
            Console::Create();
            Console::Print("[CONFIG] Loaded: Console " + std::string(settings.showConsole ? "ON" : "OFF"));
            // Create the redirect directory if it doesn't exist
            CreateDirectoryA(settings.redirectModPath.c_str(), NULL);
        }
    }
}