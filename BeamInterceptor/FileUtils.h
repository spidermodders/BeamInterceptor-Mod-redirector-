// FileUtils.h
#pragma once

#include <string>
#include <windows.h>
#include <vector>
#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

// Conversion and path manipulation utilities
std::string ConvertWideToNarrow(const std::wstring& wstr);
std::string GetPathFromHandle(HANDLE hFile);
std::string ExtractFilename(const std::string& path);
bool IsPathUnderModsDirectory(const std::string& path);

// Process utilities
BOOL IsMainProcessByCmdLine();
std::string GetDllDirectory(HMODULE hModule);
bool MergeFolderWithZip(const std::string& zipPath, const std::string& folderPath, const std::string& destFolder);
bool isFileOutdated(const std::string& filePath);
bool updateFiledate(const std::string& filePath);
bool hasGenMap(const std::string& filePath);
void cacheMods();
std::string NormalizeModName(const fs::path& path);