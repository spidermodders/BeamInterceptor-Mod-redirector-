#include "pch.h"
#include <windows.h>
#include <tchar.h>
#include "MinHook.h"
#include "Config.h"
#include "Console.h"
#include "FileUtils.h"
#include "Detour.h"

volatile LONG hook_initialized = 0;

DWORD WINAPI SetupHook(LPVOID lpParam) {
    if (InterlockedExchange(&hook_initialized, 1) != 0) return 0;

    Config::Initialize();

    if (!Config::settings.enabled) {
        if (Config::settings.showConsole) Console::Print("Interceptor is disabled in config. Exiting.");
        return 0;
    }

    Console::Print("--- BeamNG I/O Interceptor Loaded ---");
    Console::Print("Redirecting to: " + Config::settings.redirectModPath);

    if (MH_Initialize() != MH_OK) {
        Console::PrintError("MinHook Initialization Failed!", GetLastError());
        return 0;
    }

    SetupDetours();

    Console::Print("Hooks injected...");
    return 0;
}

// --- Entry Point ---
BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
        // Set the HMODULE so Config can find the DLL directory
        if (hModule) Config::settings.dllDirectory = GetDllDirectory(hModule);

        if (IsMainProcessByCmdLine()) {
            CreateThread(NULL, 0, SetupHook, NULL, 0, NULL);
        }
        break;
    case DLL_PROCESS_DETACH:
        if (hook_initialized) {
            MH_DisableHook(MH_ALL_HOOKS);
            MH_Uninitialize();
            if (Config::settings.showConsole) Console::Destroy();
        }
        break;
    }
    return TRUE;
}