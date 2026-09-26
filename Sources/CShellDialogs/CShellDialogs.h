// The shell's file dialog, which Swift's WinSDK module leaves out: IFileOpenDialog, for choosing a
// folder in the Explorer-style panel Windows' own programs use. Only the declarations; every call is
// made from Swift.
#pragma once
#ifdef _WIN32
#pragma clang module import WinSDK
#include <windows.h>
#include <shobjidl.h>
#endif
