#include "pch.h"
#include <windows.h>
#include <atomic>
#include "MinHook.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include "Detour.h"

static std::atomic<bool> g_setupStarted{ false };
static std::atomic<bool> g_hooksInstalled{ false };

DWORD WINAPI SetupHook(LPVOID) {
    if (g_setupStarted.exchange(true)) return 0;

    Config::Initialize();

    if (!Config::settings.enabled) {
        Console::Print("Interceptor is disabled in config. Exiting.");
        return 0;
    }

    Console::Print("--- BeamNG I/O Interceptor Loaded ---");
    Console::Print(L"Redirecting to: " + Config::settings.redirectModPath);

    if (MH_Initialize() != MH_OK) {
        Console::PrintError("MinHook Initialization Failed!", GetLastError());
        return 0;
    }

    if (!SetupDetours()) {
        Console::PrintError("Failed to hook CreateFileW!", GetLastError());
        MH_Uninitialize();
        return 0;
    }

    g_hooksInstalled = true;
    return 0;
}

// --- Entry Point ---
BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(hModule);
        // Config finds its files next to the DLL
        Config::settings.dllDirectory = GetModuleDirectory(hModule);

        if (IsMainProcessByCmdLine()) {
            if (HANDLE thread = CreateThread(nullptr, 0, SetupHook, nullptr, 0, nullptr)) {
                CloseHandle(thread);
            }
        }
        break;
    case DLL_PROCESS_DETACH:
        // lpReserved != null: the process is exiting, the OS reclaims everything and unhooking is just risk.
        if (!lpReserved && g_hooksInstalled) {
            MH_DisableHook(MH_ALL_HOOKS);
            MH_Uninitialize();
            Console::Destroy();
        }
        break;
    }
    return TRUE;
}
