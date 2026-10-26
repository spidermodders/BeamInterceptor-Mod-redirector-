// FileUtils.cpp
#include "pch.h"
#include "FileUtils.h"
#include "Config.h"
#include "Console.h"

#define ZIP_STATIC
#include <zip.h>

#include <cwchar>
#include <fstream>
#include <mutex>
#include <system_error>

std::wstring Widen(std::string_view s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
    return out;
}

std::string Narrow(std::wstring_view w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring_view ExtractFilename(std::wstring_view path) {
    const size_t slash = path.find_last_of(L"\\/");
    return slash == std::wstring_view::npos ? path : path.substr(slash + 1);
}

std::wstring_view ExtractFileNameNoExtension(std::wstring_view path) {
    std::wstring_view name = ExtractFilename(path);
    const size_t dot = name.find_last_of(L'.');
    return dot == std::wstring_view::npos ? name : name.substr(0, dot);
}

BOOL IsMainProcessByCmdLine() {
    // CEF helper processes carry --type=...; only the game process gets hooked.
    const wchar_t* cmdLine = GetCommandLineW();
    return !(cmdLine && wcsstr(cmdLine, L"--type="));
}

std::wstring GetModuleDirectory(HMODULE hModule) {
    std::wstring buf(MAX_PATH, L'\0');
    for (;;) {
        const DWORD n = GetModuleFileNameW(hModule, buf.data(), (DWORD)buf.size());
        if (n == 0) return {};
        if (n < buf.size()) { buf.resize(n); break; }
        buf.resize(buf.size() * 2);   // truncated, retry with more room
    }
    const size_t slash = buf.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring() : buf.substr(0, slash);
}

static inline wchar_t ToLower(wchar_t c) {
    return (c >= L'A' && c <= L'Z') ? (wchar_t)(c + 32) : c;
}

// True for a path that ends in ".zip" (any case).
static inline bool HasZipExtension(const wchar_t* p, size_t len) {
    return len >= 5 && p[len - 4] == L'.' &&
        ToLower(p[len - 3]) == L'z' && ToLower(p[len - 2]) == L'i' && ToLower(p[len - 1]) == L'p';
}

// A "mods" folder followed by one or two more path parts: mods\x.zip or mods\<repo>\x.zip
bool IsPathUnderModsDirectory(std::wstring_view path) {
    if (path.size() >= 4 && path.compare(0, 4, L"\\\\?\\") == 0) {
        path.remove_prefix(4);
    }

    size_t segmentStart = 0;
    bool inMods = false;
    int depthAfterMods = 0;

    for (size_t i = 0; i <= path.size(); ++i) {
        if (i != path.size() && path[i] != L'\\' && path[i] != L'/') continue;

        const size_t len = i - segmentStart;
        if (!inMods) {
            if (len == 4 &&
                ToLower(path[segmentStart + 0]) == L'm' &&
                ToLower(path[segmentStart + 1]) == L'o' &&
                ToLower(path[segmentStart + 2]) == L'd' &&
                ToLower(path[segmentStart + 3]) == L's')
            {
                inMods = true;
            }
        }
        else if (len > 0 && ++depthAfterMods > 2) {
            return false;
        }
        segmentStart = i + 1;
    }

    return inMods && (depthAfterMods == 1 || depthAfterMods == 2);
}

bool IsModZipPath(const wchar_t* path, std::wstring_view& fileName) {
    if (!path) return false;
    const size_t len = wcslen(path);
    if (!HasZipExtension(path, len)) return false;   // rejects almost every call without touching the heap

    const std::wstring_view view(path, len);
    if (!IsPathUnderModsDirectory(view)) return false;

    fileName = ExtractFilename(view);
    return true;
}

// --- ZIP manipulation ---

// The game's zip reader needs an explicit entry for every folder ("a/", "a/b/") before the files in it,
// like the original mod zips have. Adds any that are missing for entryName's parents.
static bool AddParentDirectories(zip_t* za, const std::string& entryName) {
    for (size_t slash = entryName.find('/'); slash != std::string::npos; slash = entryName.find('/', slash + 1)) {
        const std::string dir = entryName.substr(0, slash + 1);
        if (zip_name_locate(za, dir.c_str(), 0) >= 0) continue;
        if (zip_dir_add(za, dir.c_str(), 0) < 0) return false;
    }
    return true;
}

static bool AddFolderToZip(zip_t* za, const fs::path& folder) {
    std::error_code ec;
    fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end;
    if (ec) return false;

    for (; it != end; it.increment(ec)) {
        if (ec) return false;
        if (!it->is_regular_file(ec)) continue;

        // No explicit encoding flag: ASCII names stay flag-free (like every zip the game has seen so far),
        // libzip only sets the UTF-8 bit for names that need it.
        const std::string entryName = fs::relative(it->path(), folder, ec).generic_u8string();
        if (ec || entryName.empty()) return false;
        if (!AddParentDirectories(za, entryName)) return false;

        zip_source_t* src = zip_source_win32w_create(it->path().c_str(), 0, -1, nullptr);
        if (!src) return false;
        if (zip_file_add(za, entryName.c_str(), src, ZIP_FL_OVERWRITE) < 0) {
            zip_source_free(src);
            return false;
        }
    }
    return true;
}

bool MergeFolderWithZip(const fs::path& srcZip, const fs::path& folder, const fs::path& destZip) {
    // Build next to the destination, then swap in, so a crash never leaves a half-written zip behind.
    const fs::path tmp = fs::path(destZip) += L".tmp";

    if (!CopyFileW(srcZip.c_str(), tmp.c_str(), FALSE)) return false;
    SetFileAttributesW(tmp.c_str(), FILE_ATTRIBUTE_NORMAL);   // source may be read-only

    bool ok = false;
    zip_error_t err;
    zip_error_init(&err);
    if (zip_source_t* src = zip_source_win32w_create(tmp.c_str(), 0, -1, &err)) {
        if (zip_t* za = zip_open_from_source(src, 0, &err)) {
            if (AddFolderToZip(za, folder) && zip_close(za) == 0) {
                ok = true;
            }
            else {
                zip_discard(za);
            }
        }
        else {
            zip_source_free(src);
        }
    }
    zip_error_fini(&err);

    if (ok) ok = MoveFileExW(tmp.c_str(), destZip.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    if (!ok) DeleteFileW(tmp.c_str());
    return ok;
}

// --- Staleness tracking ---
// A redirected zip is stale when the original zip or anything in the source folder changed.
// The fingerprint is stored in "<redirect>\<name>.zip.datetime" after a successful build.

struct Fingerprint {
    long long zipTime = 0, zipSize = 0, folderNewest = 0, folderCount = 0, folderBytes = 0, outTime = 0, outSize = 0;
    bool operator==(const Fingerprint& o) const {
        return zipTime == o.zipTime && zipSize == o.zipSize && folderNewest == o.folderNewest &&
            folderCount == o.folderCount && folderBytes == o.folderBytes &&
            outTime == o.outTime && outSize == o.outSize;
    }
};

static bool ComputeFingerprint(const std::wstring& zipPath, const fs::path& folder, Fingerprint& fp) {
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExW(zipPath.c_str(), GetFileExInfoStandard, &data)) return false;
    fp.zipTime = ((long long)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
    fp.zipSize = ((long long)data.nFileSizeHigh << 32) | data.nFileSizeLow;

    std::error_code ec;
    fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end;
    for (; !ec && it != end; it.increment(ec)) {
        std::error_code entryEc;
        if (!it->is_regular_file(entryEc)) continue;
        const long long t = it->last_write_time(entryEc).time_since_epoch().count();
        const auto size = it->file_size(entryEc);
        if (entryEc) continue;
        if (t > fp.folderNewest) fp.folderNewest = t;
        ++fp.folderCount;
        fp.folderBytes += (long long)size;
    }
    return true;
}

// The built zip's own size/time: stamp files can be shared (hardlinked game copies) while the zips are not.
static bool StatOutput(const std::wstring& path, Fingerprint& fp) {
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return false;
    fp.outTime = ((long long)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
    fp.outSize = ((long long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
    return true;
}

static constexpr int kStampVersion = 4;   // bump when the way zips are written changes, forces a rebuild

static bool ReadStamp(const fs::path& stampFile, Fingerprint& fp) {
    std::ifstream in(stampFile);
    int version = 0;
    if (!(in >> version) || version != kStampVersion) return false;
    return (bool)(in >> fp.zipTime >> fp.zipSize >> fp.folderNewest >> fp.folderCount >> fp.folderBytes >> fp.outTime >> fp.outSize);
}

static void WriteStamp(const fs::path& stampFile, const Fingerprint& fp) {
    std::ofstream out(stampFile, std::ios::trunc);
    out << kStampVersion << ' ' << fp.zipTime << ' ' << fp.zipSize << ' ' << fp.folderNewest << ' ' << fp.folderCount << ' ' << fp.folderBytes << ' ' << fp.outTime << ' ' << fp.outSize;
}

bool ResolveModRedirect(std::wstring_view originalPath, std::wstring_view fileName, std::wstring& outPath) {
    const std::wstring& root = Config::settings.redirectModPath;
    if (root.empty()) return false;

    outPath.reserve(root.size() + 1 + fileName.size());
    outPath.assign(root).push_back(L'\\');
    outPath.append(fileName);

    // Is there a source folder named like the mod ("<redirect>\<stem>")?
    const std::wstring folder = root + L'\\' + std::wstring(ExtractFileNameNoExtension(fileName));
    const DWORD attrs = GetFileAttributesW(folder.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        return true;   // plain redirect: the caller just tries the zip in the redirect folder
    }

    // One thread builds at a time; the others wait and then find the fresh zip.
    static std::mutex buildLock;
    std::lock_guard<std::mutex> lock(buildLock);

    const std::wstring original(originalPath);
    const fs::path stampFile = outPath + L".datetime";

    Fingerprint current, stored;
    if (!ComputeFingerprint(original, folder, current)) return true;

    Fingerprint built = current;
    const bool upToDate = StatOutput(outPath, built) && ReadStamp(stampFile, stored) && stored == built;
    if (upToDate) return true;

    if (Config::settings.debugInterception) {
        Console::Print(L"[MOD INTERCEPTOR] Compiling: " + std::wstring(fileName));
        Console::Print(L"[MOD INTERCEPTOR] SOURCE DIR: " + folder);
    }

    if (MergeFolderWithZip(original, folder, outPath)) {
        StatOutput(outPath, current);
        WriteStamp(stampFile, current);
        if (Config::settings.debugInterception) Console::Print(L"[MOD INTERCEPTOR] Compiling completed at: " + outPath);
        return true;
    }

    Console::PrintError("Failed to build " + Narrow(fileName) + " (is the game holding the old copy open?)", GetLastError());
    // Fall back to the previously built zip if there is one, otherwise the original.
    return GetFileAttributesW(outPath.c_str()) != INVALID_FILE_ATTRIBUTES;
}
