// FileUtils.cpp
#include "pch.h"
#include "FileUtils.h"
#include <iostream>
#include <string>
#include <algorithm>
#include <shlobj.h>
#include <tchar.h>
#include <fstream>
#include <filesystem>
#include <vector>
#include <windows.h>
#include <libzippp\libzippp.h>
#include <unordered_set>
#include <string_view>
#include <cctype>

#include "Config.h" 
#include "Console.h" 

namespace fs = std::filesystem;
using namespace libzippp;
static std::unordered_set<std::string> g_cachedFolderMods;
static std::unordered_map<std::string, bool> g_modPathCache;
static bool g_cacheBuilt = false;

std::string ConvertWideToNarrow(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), NULL, 0, NULL, NULL);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, NULL, NULL);
    return strTo;
}

std::wstring ConvertNarrowToWide(const std::string& str) {
    if (str.empty()) return std::wstring();
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), NULL, 0);
    std::wstring wstrTo(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
    return wstrTo;
}

std::string GetPathFromHandle(HANDLE hFile) {
    if (hFile == NULL || hFile == INVALID_HANDLE_VALUE) return "";
    wchar_t path[MAX_PATH];
    DWORD result = GetFinalPathNameByHandleW(hFile, path, MAX_PATH, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (result == 0 || result >= MAX_PATH) {
        return "Unknown/Pipe/Console";
    }
    std::wstring ws(path);
    std::string str = ConvertWideToNarrow(ws);

    const std::string prefix = "\\\\?\\";
    if (str.size() >= prefix.size() && str.substr(0, prefix.size()) == prefix) {
        str = str.substr(prefix.size());
    }
    return str;
}

std::string ExtractFilename(const std::string& path) {
    size_t lastSlash = path.find_last_of("\\/");
    if (lastSlash == std::string::npos) {
        return path;
    }
    return path.substr(lastSlash + 1);
}

std::string_view ExtractFileNameNoExtension(std::string_view path) {
    if (path.size() >= 4 && path.substr(0, 4) == "\\\\?\\") {
        path.remove_prefix(4);
    }

    size_t lastSlash = path.find_last_of("/\\");
    std::string_view filename =
        (lastSlash == std::string_view::npos)
        ? path
        : path.substr(lastSlash + 1);

    size_t lastDot = filename.find_last_of('.');
    if (lastDot != std::string_view::npos) {
        return filename.substr(0, lastDot);
    }

    return filename;
}

BOOL IsMainProcessByCmdLine() {
    LPCTSTR cmdLine = GetCommandLine();
    if (_tcsstr(cmdLine, TEXT("--type=")) != NULL) {
        return FALSE;
    }
    return TRUE;
}

std::string GetDllDirectory(HMODULE hModule) {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(hModule, path, MAX_PATH);
    std::wstring ws(path);
    std::string str = ConvertWideToNarrow(ws);
    size_t lastSlash = str.find_last_of("\\/");
    return str.substr(0, lastSlash);
}

static inline char ToLower(char c) {
    return (c >= 'A' && c <= 'Z') ? (c + 32) : c;
}

bool IsPathUnderModsDirectoryCached(std::string_view path) {
    auto it = g_modPathCache.find(std::string(path));
    if (it != g_modPathCache.end())
        return it->second;

    bool result = IsPathUnderModsDirectory(path);
    g_modPathCache.emplace(path, result);
    return result;
}

bool IsPathUnderModsDirectory(std::string_view path) {
    if (path.size() >= 4 && path.substr(0, 4) == "\\\\?\\") {
        path.remove_prefix(4);
    }

    size_t segmentStart = 0;
    bool inMods = false;
    int depthAfterMods = 0;

    for (size_t i = 0; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '\\' || path[i] == '/') {
            size_t len = i - segmentStart;

            if (!inMods) {
                if (len == 4 &&
                    ToLower(path[segmentStart + 0]) == 'm' &&
                    ToLower(path[segmentStart + 1]) == 'o' &&
                    ToLower(path[segmentStart + 2]) == 'd' &&
                    ToLower(path[segmentStart + 3]) == 's')
                {
                    inMods = true;
                    depthAfterMods = 0;
                }
            }
            else {
                if (len > 0) {
                    depthAfterMods++;
                    if (depthAfterMods > 2) {
                        return false;
                    }
                }
            }

            segmentStart = i + 1;
        }
    }

    // Valid only if we found mods AND depth is 1 or 2
    return inMods && (depthAfterMods == 1 || depthAfterMods == 2);
}

// --- ZIP Manipulation Core Functions ---
std::string GenerateRandomTempName(const std::string& baseName) {
    std::string cleanName = baseName;
    size_t lastDot = cleanName.find_last_of('.');
    if (lastDot != std::string::npos) {
        cleanName = cleanName.substr(0, lastDot);
    }

    // Generate 4 random numbers
    srand((unsigned int)time(0));
    int randNum = rand() % 9000 + 1000;

    return "_" + cleanName + std::to_string(randNum) + "cache";
}

bool MergeFolderWithZip(
    const std::string& zipPath,
    const std::string& folderPath,
    const std::string& destFolder)
{
    try {
        // Ensure destination directory exists
        fs::create_directories(destFolder);

        // Destination zip path
        fs::path srcZip(zipPath);
        fs::path destZip = fs::path(destFolder) / srcZip.filename();

        // Copy original zip
        fs::copy_file(srcZip, destZip, fs::copy_options::overwrite_existing);

        // Open copied zip
        ZipArchive zip(destZip.string());
        if (!zip.open(ZipArchive::Write)) {
            return false;
        }

        fs::path inputRoot(folderPath);

        for (auto& entry : fs::recursive_directory_iterator(inputRoot)) {
            if (!entry.is_regular_file())
                continue;

            fs::path relativePath = fs::relative(entry.path(), inputRoot);
            std::string zipEntryPath = relativePath.generic_string();

            // Binary-safe file copy into zip
            zip.addFile(zipEntryPath, entry.path().string());
        }

        zip.close();
        return true;
    }
    catch (...) {
        return false;
    }
}

static fs::path GetDatetimeFilePath(const fs::path& filePath) {
    fs::path redirectRoot(Config::settings.redirectModPath);
    return redirectRoot / (filePath.filename().string() + ".datetime");
}

bool isFileOutdated(std::string_view filePath)
{
    try {
        fs::path targetFile(filePath);
        if (!fs::exists(targetFile))
            return true;

        fs::path datetimeFile = GetDatetimeFilePath(targetFile);

        if (!fs::exists(datetimeFile))
            return true;

        auto currentTime = fs::last_write_time(targetFile);
        auto currentTimeValue = currentTime.time_since_epoch().count();

        std::ifstream in(datetimeFile, std::ios::binary);
        if (!in)
            return true;

        int64_t storedTime = 0;
        in >> storedTime;

        return storedTime != currentTimeValue;
    }
    catch (...) {
        return true;
    }
}

bool updateFiledate(const std::string& filePath)
{
    try {
        fs::path targetFile(filePath);
        if (!fs::exists(targetFile))
            return false;

        fs::create_directories(Config::settings.redirectModPath);
        fs::path datetimeFile = GetDatetimeFilePath(targetFile);

        auto currentTime = fs::last_write_time(targetFile);
        auto currentTimeValue = currentTime.time_since_epoch().count();

        std::ofstream out(datetimeFile, std::ios::binary | std::ios::trunc);
        if (!out)
            return false;

        out << currentTimeValue;
        return true;
    }
    catch (...) {
        return false;
    }
}

std::string NormalizeModName(const fs::path& path)
{
    std::string name = path.stem().string();
    return name;
}

void cacheMods()
{
    g_cachedFolderMods.clear();
    g_cacheBuilt = false;

    try {
        fs::path root(Config::settings.redirectModPath);
        if (!fs::exists(root))
            return;

        for (const auto& entry : fs::directory_iterator(root)) {
            fs::path p = entry.path();

            if (entry.is_directory()) {
                g_cachedFolderMods.insert(NormalizeModName(p));
            }
        }

        g_cacheBuilt = true;
    }
    catch (...) {
        // fail silently
    }
}

bool hasGenMap(const std::string& filePath)
{
    try {
        if (!g_cacheBuilt)
            cacheMods();

        fs::path input(filePath);

        if (input.extension() != ".zip")
            return false;

        std::string modName = NormalizeModName(input);
        bool hasFolder = g_cachedFolderMods.count(modName) > 0;

        return hasFolder;
    }
    catch (...) {
        return false;
    }
}