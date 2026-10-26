// FileUtils.h
#pragma once

#include <string>
#include <string_view>
#include <windows.h>
#include <filesystem>

namespace fs = std::filesystem;

// Conversion and path manipulation utilities
std::wstring Widen(std::string_view utf8);
std::string Narrow(std::wstring_view wide);
std::wstring_view ExtractFilename(std::wstring_view path);
std::wstring_view ExtractFileNameNoExtension(std::wstring_view path);

// Allocation-free test used on every CreateFileW call: "<...>\mods\[<repo>\]<name>.zip"
bool IsModZipPath(const wchar_t* path, std::wstring_view& fileName);
bool IsPathUnderModsDirectory(std::wstring_view path);

// Process utilities
BOOL IsMainProcessByCmdLine();
std::wstring GetModuleDirectory(HMODULE hModule);

// Mod redirection. Returns true and fills outPath when the open should go to the redirect folder.
// If a "<redirect>\<modname>" source folder exists the redirected zip is (re)built when stale.
bool ResolveModRedirect(std::wstring_view originalPath, std::wstring_view fileName, std::wstring& outPath);
bool MergeFolderWithZip(const fs::path& srcZip, const fs::path& folder, const fs::path& destZip);
