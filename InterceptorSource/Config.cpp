#include "pch.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

namespace Config {
    Settings settings;

    static const wchar_t* const kConfigFileName = L"Interceptor.config";
    static const wchar_t* const kDefaultModDir = L"ModifiedMods";

    std::wstring GetConfigPath() {
        return settings.dllDirectory + L"\\" + kConfigFileName;
    }

    static std::string_view Trim(std::string_view s) {
        while (!s.empty() && (s.front() == ' ' || s.front() == '\t' || s.front() == '\r' || s.front() == '\n')) s.remove_prefix(1);
        while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r' || s.back() == '\n')) s.remove_suffix(1);
        return s;
    }

    static bool ParseBool(std::string_view v, bool fallback) {
        if (v.empty()) return fallback;
        const char c = v.front() | 0x20;   // ascii lower-case
        if (c == 'o') return v.size() > 1 && (v[1] | 0x20) == 'n';   // on / off
        if (c == 't' || c == '1' || c == 'y') return true;
        if (c == 'f' || c == '0' || c == 'n') return false;
        return fallback;
    }

    void CreateDefault() {
        const std::filesystem::path configPath = GetConfigPath();
        std::ofstream file(configPath, std::ios::trunc);
        if (!file) {
            Console::Print("[CONFIG] Error: Could not create default config file.");
            return;
        }
        file << "showConsole=" << (settings.showConsole ? "true" : "false") << "\n"
             << "debugInterception=" << (settings.debugInterception ? "true" : "false") << "\n"
             << "modDir=" << Narrow(kDefaultModDir) << "\n"
             << "enabled=" << (settings.enabled ? "true" : "false") << "\n";
    }

    void Load() {
        const std::filesystem::path configPath = GetConfigPath();
        std::ifstream file(configPath);
        if (!file) {
            CreateDefault();
            return;
        }

        std::string line;
        while (std::getline(file, line)) {
            std::string_view view = Trim(line);
            if (view.empty() || view.front() == '#' || view.front() == ';') continue;

            const size_t eq = view.find('=');
            if (eq == std::string_view::npos) continue;

            const std::string_view key = Trim(view.substr(0, eq));
            std::string_view value = Trim(view.substr(eq + 1));

            if (key == "showConsole") settings.showConsole = ParseBool(value, settings.showConsole);
            else if (key == "debugInterception") settings.debugInterception = ParseBool(value, settings.debugInterception);
            else if (key == "enabled") settings.enabled = ParseBool(value, settings.enabled);
            else if (key == "modDir") {
                if (value.size() >= 2 && value.front() == '"' && value.back() == '"') value = Trim(value.substr(1, value.size() - 2));
                if (!value.empty()) settings.modDir = Widen(value);
            }
        }
    }

    void Initialize() {
        // dllDirectory is already set by DllMain from the module handle.
        settings.modDir = kDefaultModDir;
        Load();

        // modDir may be relative to the plugin folder; settings.redirectModPath is always absolute.
        std::filesystem::path redirect(settings.modDir);
        if (redirect.is_relative()) redirect = std::filesystem::path(settings.dllDirectory) / redirect;
        redirect = redirect.lexically_normal();
        settings.redirectModPath = redirect.native();
        while (settings.redirectModPath.size() > 3 && (settings.redirectModPath.back() == L'\\' || settings.redirectModPath.back() == L'/'))
            settings.redirectModPath.pop_back();

        if (!settings.enabled) return;

        if (settings.debugInterception) Console::OpenLog(settings.dllDirectory + L"\\Interceptor.log");
        if (settings.showConsole) {
            Console::Create();
            Console::Print("[CONFIG] Loaded: Console ON");
        }

        // A configured folder that doesn't exist is almost always a stale path (game moved or copied),
        // so use the default one next to the plugin instead of silently redirecting nowhere.
        std::error_code ec;
        const std::filesystem::path fallback = (std::filesystem::path(settings.dllDirectory) / kDefaultModDir).lexically_normal();
        if (redirect != fallback && !std::filesystem::is_directory(redirect, ec)) {
            Console::Print(L"[CONFIG] modDir not found: " + settings.redirectModPath + L" - using " + fallback.native());
            settings.redirectModPath = fallback.native();
        }

        std::filesystem::create_directories(settings.redirectModPath, ec);
    }
}
