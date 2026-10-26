#include "pch.h"
#include "Detour.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include <MinHook.h>
#include <mutex>
#include <unordered_map>

CreateFileW_t fpCreateFileW = nullptr;

typedef BOOL(WINAPI* GetFileAttributesExW_t)(LPCWSTR, GET_FILEEX_INFO_LEVELS, LPVOID);
typedef HANDLE(WINAPI* FindFirstFileExW_t)(LPCWSTR, FINDEX_INFO_LEVELS, LPVOID, FINDEX_SEARCH_OPS, LPVOID, DWORD);
typedef HANDLE(WINAPI* FindFirstFileW_t)(LPCWSTR, LPWIN32_FIND_DATAW);
typedef BOOL(WINAPI* FindNextFileW_t)(HANDLE, LPWIN32_FIND_DATAW);
typedef BOOL(WINAPI* FindClose_t)(HANDLE);
static GetFileAttributesExW_t fpGetFileAttributesExW = nullptr;
static FindFirstFileExW_t fpFindFirstFileExW = nullptr;
static FindFirstFileW_t fpFindFirstFileW = nullptr;
static FindNextFileW_t fpFindNextFileW = nullptr;
static FindClose_t fpFindClose = nullptr;

// Our own work (copying, zipping, stat-ing) calls these APIs again; those calls must pass straight through.
static thread_local bool t_inHook = false;

struct HookScope {
    HookScope() { t_inHook = true; }
    ~HookScope() { t_inHook = false; }
};

// Mod zips are only redirected for plain reads. Writes, deletes and creates keep hitting the real file.
static constexpr DWORD kWriteAccess = GENERIC_WRITE | GENERIC_ALL | FILE_WRITE_DATA | FILE_APPEND_DATA | DELETE;

HANDLE WINAPI DetourCreateFileW(
    LPCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
    LPSECURITY_ATTRIBUTES lpSecurityAttributes, DWORD dwCreationDisposition,
    DWORD dwFlagsAndAttributes, HANDLE hTemplateFile
) {
    std::wstring_view fileName;
    if (!t_inHook && Config::settings.enabled && IsModZipPath(lpFileName, fileName))
    {
        const bool readOnly = dwCreationDisposition == OPEN_EXISTING && !(dwDesiredAccess & kWriteAccess);
        if (Config::settings.debugInterception) {
            Console::Print(L"[MOD INTERCEPTOR] Open " + std::wstring(lpFileName) + L" access=0x" + std::to_wstring(dwDesiredAccess) +
                L" disposition=" + std::to_wstring(dwCreationDisposition) + (readOnly ? L"" : L" (not redirected: write/create)"));
        }

        if (readOnly) {
            HookScope scope;

            std::wstring redirected;
            if (ResolveModRedirect(lpFileName, fileName, redirected)) {
                HANDLE hRedirect = fpCreateFileW(redirected.c_str(), dwDesiredAccess, dwShareMode, lpSecurityAttributes,
                    dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);

                if (hRedirect != INVALID_HANDLE_VALUE) {
                    if (Config::settings.debugInterception) Console::Print(L"[MOD INTERCEPTOR] [SUCCESS] Spoofed " + std::wstring(fileName) + L" -> " + redirected);
                    return hRedirect;
                }

                const DWORD error = GetLastError();
                if (Config::settings.debugInterception && error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) {
                    Console::PrintError("Failed to open redirected file " + Narrow(redirected), error);
                }
            }
        }
    }

    return fpCreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
}

// --- Size / time lookups ---
// The game learns a mod zip's size and dates from directory listings and attribute queries on the original path,
// then reads the redirected file. Those must describe the redirected file, or a built zip that is bigger than the
// original gets read as if it were cut short.

// Attributes of the redirected zip for a mod zip path, if there is one.
static bool GetRedirectedAttributes(const wchar_t* path, WIN32_FILE_ATTRIBUTE_DATA& data) {
    std::wstring_view fileName;
    if (!IsModZipPath(path, fileName)) return false;

    HookScope scope;
    std::wstring redirected;
    if (!ResolveModRedirect(path, fileName, redirected)) return false;
    return GetFileAttributesExW(redirected.c_str(), GetFileExInfoStandard, &data) != FALSE;   // passes through: scope is set
}

static void PatchFindData(const std::wstring& directory, WIN32_FIND_DATAW& fd) {
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) return;
    const std::wstring full = directory + fd.cFileName;
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetRedirectedAttributes(full.c_str(), data)) return;

    if (Config::settings.debugInterception) {
        const unsigned long long before = ((unsigned long long)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        const unsigned long long after = ((unsigned long long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
        Console::Print(L"[MOD INTERCEPTOR] Listing " + full + L" size " + std::to_wstring(before) + L" -> " + std::to_wstring(after));
    }
    fd.nFileSizeHigh = data.nFileSizeHigh;
    fd.nFileSizeLow = data.nFileSizeLow;
    fd.ftLastWriteTime = data.ftLastWriteTime;
    fd.ftCreationTime = data.ftCreationTime;
}

BOOL WINAPI DetourGetFileAttributesExW(LPCWSTR lpFileName, GET_FILEEX_INFO_LEVELS fInfoLevelId, LPVOID lpFileInformation) {
    const BOOL ok = fpGetFileAttributesExW(lpFileName, fInfoLevelId, lpFileInformation);
    if (!ok || t_inHook || !Config::settings.enabled || fInfoLevelId != GetFileExInfoStandard) return ok;

    WIN32_FILE_ATTRIBUTE_DATA data;
    if (GetRedirectedAttributes(lpFileName, data)) {
        auto* out = static_cast<WIN32_FILE_ATTRIBUTE_DATA*>(lpFileInformation);
        if (Config::settings.debugInterception) {
            Console::Print(L"[MOD INTERCEPTOR] Stat " + std::wstring(lpFileName) + L" size " + std::to_wstring(out->nFileSizeLow) + L" -> " + std::to_wstring(data.nFileSizeLow));
        }
        out->nFileSizeHigh = data.nFileSizeHigh;
        out->nFileSizeLow = data.nFileSizeLow;
        out->ftLastWriteTime = data.ftLastWriteTime;
        out->ftCreationTime = data.ftCreationTime;
    }
    return ok;
}

// Directory of each open search handle, so FindNextFileW results can be resolved to full paths.
static std::mutex g_findLock;
static std::unordered_map<HANDLE, std::wstring> g_findDirs;

// Remembers searches inside a mods folder ("<...>\mods\*", "<...>\mods\<repo>\*") and fixes their first result.
static void TrackSearch(HANDLE h, LPCWSTR pattern, WIN32_FIND_DATAW& first) {
    if (h == INVALID_HANDLE_VALUE || t_inHook || !Config::settings.enabled || !pattern) return;

    const std::wstring_view view(pattern);
    const size_t slash = view.find_last_of(L"\\/");
    if (slash == std::wstring_view::npos) return;
    std::wstring directory(view.substr(0, slash + 1));
    if (!IsPathUnderModsDirectory(directory + L"x.zip")) return;

    PatchFindData(directory, first);
    std::lock_guard<std::mutex> lock(g_findLock);
    g_findDirs[h] = std::move(directory);
}

HANDLE WINAPI DetourFindFirstFileExW(LPCWSTR lpFileName, FINDEX_INFO_LEVELS fInfoLevelId, LPVOID lpFindFileData,
    FINDEX_SEARCH_OPS fSearchOp, LPVOID lpSearchFilter, DWORD dwAdditionalFlags) {
    HANDLE h = fpFindFirstFileExW(lpFileName, fInfoLevelId, lpFindFileData, fSearchOp, lpSearchFilter, dwAdditionalFlags);
    TrackSearch(h, lpFileName, *static_cast<WIN32_FIND_DATAW*>(lpFindFileData));
    return h;
}

HANDLE WINAPI DetourFindFirstFileW(LPCWSTR lpFileName, LPWIN32_FIND_DATAW lpFindFileData) {
    HANDLE h = fpFindFirstFileW(lpFileName, lpFindFileData);
    TrackSearch(h, lpFileName, *lpFindFileData);
    return h;
}

BOOL WINAPI DetourFindNextFileW(HANDLE hFindFile, LPWIN32_FIND_DATAW lpFindFileData) {
    const BOOL ok = fpFindNextFileW(hFindFile, lpFindFileData);
    if (!ok || t_inHook) return ok;

    std::wstring directory;
    {
        std::lock_guard<std::mutex> lock(g_findLock);
        auto it = g_findDirs.find(hFindFile);
        if (it == g_findDirs.end()) return ok;
        directory = it->second;
    }
    PatchFindData(directory, *lpFindFileData);
    return ok;
}

BOOL WINAPI DetourFindClose(HANDLE hFindFile) {
    {
        std::lock_guard<std::mutex> lock(g_findLock);
        g_findDirs.erase(hFindFile);
    }
    return fpFindClose(hFindFile);
}

static bool Hook(LPVOID target, LPVOID detour, LPVOID* original) {
    return MH_CreateHook(target, detour, original) == MH_OK && MH_EnableHook(target) == MH_OK;
}

bool SetupDetours() {
    if (!Hook(&CreateFileW, &DetourCreateFileW, (LPVOID*)&fpCreateFileW)) return false;

    // Size/time spoofing is best effort: the redirect itself works without it.
    if (!Hook(&GetFileAttributesExW, &DetourGetFileAttributesExW, (LPVOID*)&fpGetFileAttributesExW) ||
        !Hook(&FindFirstFileExW, &DetourFindFirstFileExW, (LPVOID*)&fpFindFirstFileExW) ||
        !Hook(&FindFirstFileW, &DetourFindFirstFileW, (LPVOID*)&fpFindFirstFileW) ||
        !Hook(&FindNextFileW, &DetourFindNextFileW, (LPVOID*)&fpFindNextFileW) ||
        !Hook(&FindClose, &DetourFindClose, (LPVOID*)&fpFindClose)) {
        Console::Print("[MOD INTERCEPTOR] Warning: could not hook file attribute APIs, sizes of redirected zips may be wrong");
    }

    Console::Print("[MOD INTERCEPTOR] Injected into beamng drive");
    return true;
}
