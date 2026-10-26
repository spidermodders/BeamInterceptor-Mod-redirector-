# BeamInterceptor
An ASI plugin that lets BeamNG.drive load mods from a folder outside its normal mod folder, and can merge loose files into a mod zip at runtime.

## How it works
It hooks `CreateFileW` and intercepts opens of mod zips. When BeamNG reads a mod that also exists in `ModifiedMods`, it gets that copy instead. If `ModifiedMods` has a folder with the same name as the zip (for example `ModifiedMods\BeamMP`), its files are merged into a copy of the original zip, and the copy is rebuilt only when something changes.

## Install
1. Download the latest zip from the [Releases](../../releases) page.
2. In Steam, right click BeamNG.drive, choose Manage, then Browse local files, and open `Bin64`.
3. Extract everything from the zip into `Bin64`: `version.dll`, `BeamInterceptor.asi`, `Interceptor.config` and the `ModifiedMods` folder.

## Repository
| Folder | Contents |
| --- | --- |
| `InterceptorSource` | The plugin (C++, MinHook and libzip through vcpkg) |
| `AsiLoader` | Fork of [Ultimate ASI Loader](https://github.com/ThirteenAG/Ultimate-ASI-Loader), built as `version.dll` |
| `BeamMods` | Mods as folders (or zips), each laid over the BeamMP files in `ModifiedMods\BeamMP`: `BeamModMenu` (the menu) and `CoolModUtil` (its shared library) |
| `ReadyPackage` | Build output, not tracked |

## Building
Run `Build.bat`. Option 1 builds the ASI loader, option 2 builds the plugin and assembles `ReadyPackage` plus `out\BeamInterceptor-<version>.zip`.
Needs Visual Studio 2022 (C++ workload) and vcpkg with `minhook` and `libzip` for `x64-windows-static` (set `VCPKG_ROOT`).
`Commit.bat` commits, pushes and publishes a GitHub release.
