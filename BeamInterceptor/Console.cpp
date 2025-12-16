#include "pch.h"
#include "Console.h"
#include <windows.h>
#include <iostream>
#include <cstdio>

namespace Console {
    FILE* fp = nullptr;

    void Create() {
        AllocConsole();
        // Redirect stdout to the new console
        freopen_s(&fp, "CONOUT$", "w", stdout);

        // Optional: Redirect stderr too if you want error logging
        // freopen_s(&fp, "CONOUT$", "w", stderr); 

        std::cout.clear(); // Reset error state flags
    }

    void Destroy() {
        if (fp) {
            fclose(fp);
            fp = nullptr;
        }
        FreeConsole();
    }

    void Print(const std::string& message) {
        std::cout << message << std::endl;
    }

    void Print(const char* message) {
        std::cout << message << std::endl;
    }

    void PrintError(const std::string& message, unsigned long errorCode) {
        std::cout << "[ERROR] " << message << " Code: " << errorCode << std::endl;
    }
}