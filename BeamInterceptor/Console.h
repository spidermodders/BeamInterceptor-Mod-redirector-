#pragma once
#include <string>

// Namespace to keep things organized
namespace Console {
    void Create();
    void Destroy();

    // Basic print functions
    void Print(const std::string& message);
    void Print(const char* message);

    // Helper to print errors with codes easily
    void PrintError(const std::string& message, unsigned long errorCode);
}