#include "pch.h"
#include "Detour.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include <MinHook.h>
#include <map>
#include <algorithm>
#include <vector>

extern "C" {
    CreateFileW_t fpCreateFileW = NULL;
}

typedef BOOL(WINAPI* WriteFile_t)(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
WriteFile_t fpWriteFile = NULL;

BOOL WINAPI DetourWriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite, LPDWORD lpNumberOfBytesWritten, LPOVERLAPPED lpOverlapped) {
    return fpWriteFile(hFile, lpBuffer, nNumberOfBytesToWrite, lpNumberOfBytesWritten, lpOverlapped);
}

HANDLE WINAPI DetourCreateFileW(
    LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
    LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition,
    DWORD dwFlagsAndAttributes, HANDLE hTemplateFile
) {
    std::wstring wsFileName(lpFileName);
    std::string originalPath = ConvertWideToNarrow(wsFileName);
    std::string filenameOnly = ExtractFilename(originalPath);

    if (Config::settings.enabled && IsPathUnderModsDirectoryCached(originalPath)) {

        if (hasGenMap(originalPath)) {
            std::string_view baseNameView = ExtractFileNameNoExtension(filenameOnly);
            std::string baseName(baseNameView);
            const std::string genMapPath = Config::settings.redirectModPath + "\\" + baseName;

            if (isFileOutdated(originalPath) || isFileOutdated(genMapPath)) {
                if (Config::settings.debugInterception) {
                    Console::Print("[MOD INTERCEPTOR] Compiling: " + filenameOnly);
                    Console::Print("[MOD INTERCEPTOR] SOURCE DIR: " + Config::settings.redirectModPath + "\\" + NormalizeModName(originalPath));
                }

                updateFiledate(originalPath);
                updateFiledate(genMapPath);

                MergeFolderWithZip(originalPath, Config::settings.redirectModPath + "\\" + NormalizeModName(originalPath), Config::settings.redirectModPath);

                if (Config::settings.debugInterception) {
                    Console::Print("[MOD INTERCEPTOR] Compiling completed at: " + Config::settings.redirectModPath + "\\" + filenameOnly);
                }
            }
        }

        std::string redirectZipPath = Config::settings.redirectModPath + "\\" + filenameOnly;

        if (filenameOnly.size() > 4 &&
            filenameOnly.substr(filenameOnly.size() - 4) == ".zip" &&
            GetFileAttributesA(redirectZipPath.c_str()) != INVALID_FILE_ATTRIBUTES)
        {
            if (Config::settings.debugInterception) {
                Console::Print("[MOD INTERCEPTOR] Intercepting: " + filenameOnly);
            }

            std::wstring wsRedirectPath(redirectZipPath.begin(), redirectZipPath.end());

            HANDLE hRedirect = fpCreateFileW(
                wsRedirectPath.c_str(), dwDesiredAccess, dwShareMode, lpSecurityAttributes,
                dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile
            );

            if (hRedirect != INVALID_HANDLE_VALUE) {
                if (Config::settings.debugInterception) Console::Print("[MOD INTERCEPTOR] [SUCCESS] Spoofed " + filenameOnly);
                return hRedirect;
            }
            else {
                Console::PrintError("[ERROR] Failed to open redirected file.", GetLastError());
            }
        }
    }

    return fpCreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
}

void SetupDetours() {
    MH_CreateHook(&CreateFileW, &DetourCreateFileW, (LPVOID*)&fpCreateFileW);
    MH_CreateHook(&WriteFile, &DetourWriteFile, (LPVOID*)&fpWriteFile);
    MH_EnableHook(MH_ALL_HOOKS);
    Console::Print("[MOD INTERCEPTOR] Injected into beamng drive");
    cacheMods();
}