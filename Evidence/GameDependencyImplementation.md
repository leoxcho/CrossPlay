# CrossPlay game dependency implementation — October 6, 2026

Source checkpoint: `Build/Checkpoints/20261006-084240-BeforeGameDependencies`. It includes the pre-edit Sources, Scripts, Tests, README and copies/hashes of Library.json and Runtimes.json. No prefix or runtime payload was copied into the checkpoint. Existing untracked work was preserved.

## Files changed

- [Sources/GameDependencyManager.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Sources/GameDependencyManager.swift)
- [Sources/ExecutionHost.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Sources/ExecutionHost.swift)
- [Sources/main.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Sources/main.swift)
- [Sources/CrossPlayUI.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Sources/CrossPlayUI.swift)
- [Sources/RuntimeRegistry.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Sources/RuntimeRegistry.swift)
- [Scripts/build-app.sh](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Scripts/build-app.sh)
- [Tests/DependencyValidation.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Tests/DependencyValidation.swift)
- [Tests/DependencyRepairValidation.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Tests/DependencyRepairValidation.swift)
- [Tests/LiveMetadataValidation.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Tests/LiveMetadataValidation.swift)
- [Tests/RuntimeManagerValidation.swift](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/Tests/RuntimeManagerValidation.swift)
- [README.md](/Volumes/M2/Users/leoxcho/Documents/ChatGPT/CrossPlay/README.md)

Generated outputs include the rebuilt/signature-verified `CrossPlay.app`, disposable validation binaries under Build, and the dependency evidence logs/results under Evidence. No redistributable executable was added to source or the app. Test installers and test prefixes remain in the temporary fixture directory identified in `dependency-all-install.log`.

## Architecture and behavior

The runtime engine, game prefix, game requirements and per-prefix installations remain separate. Requirements come from PE/import inspection and optional LibraryGame.dependencyRequirements. Installations are recorded in DependencyState.json using executable path + immutable runtime ID + exact prefix path. Records include status, installation/verification dates, installer hash and diagnostics. Selecting another runtime does not transfer installation state or erase successfulRuntime.

The dependency worker uses a separate ExecutionHost with the selected game's runtime ID, exact prefix, registry, AVX setting, coherent Wine environment, prefix lock and existing bottle bootstrap. It invokes the registered Wine host, never an arbitrary system Wine. Required installer success is followed by live DLL verification; only then is metadata marked installed and the captured original launch resumed. Cancel returns before download, installation or dependency metadata changes. Installation and inspection run asynchronously.

Supported and actually installed in a disposable test prefix: modern Microsoft VC++ v14, 2013 (12.0.40664.0), 2012 (11.0.61030.0), and 2010 (10.0.40219.325), each in x64 and x86. They coexist. Catalog links were verified against [Microsoft's download documentation](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist/). Definitions can supply another product, identifier, installer options and library evidence; DirectX and .NET packages are not yet included.

Detection retains the previous bounded EXE/UnityPlayer samples, adds all requested VC++ DLL indicators and follows normal/delay-import RVAs. PE header position, section count, import descriptors and name lengths have fixed bounds. The dependency inspection cache uses EXE/UnityPlayer size and modification date plus an inspection schema stamp. Old metadata refreshes at launch rather than slowing ordinary game selection. Manual management explicitly refreshes inspection on a worker.

Native PE DLLs are checked in the selected prefix's system32 (x64) or syswow64 (x86). Machine architecture must match and Wine builtin DLLs are rejected. vcruntime140_1.dll is additionally required when referenced. Actual prefix state overrides saved status; missing files with installed metadata produce Needs repair. Repair uses the installer's repair arguments.

Production cache: `~/Library/Caches/CrossPlay/DependencyInstallers`. Downloads and each redirect must use HTTPS on the exact approved Microsoft hosts. HTTP success, plausible bounded size and MZ header are required. SHA-256 receipts verify cached bytes before reuse. No global installation, Gcenx, runtime deletion, prefix deletion, original-game-directory writes or runtime migration was introduced.

Game Profiles includes Windows Dependencies status and Manage Dependencies. The native manager lists every supported architecture/family, detected requirements, live installed/missing/repair status, selected runtime and prefix; it offers Install Missing, Repair Selected and Cancel. A Game didn't start? recovery button opens the same manager. No dialog scraping or OCR is used.

## Validation results

- Final native ARM64 app build and ad-hoc deep/strict signature verification passed: `dependency-build.log` (runtime payload copying skipped, preserving the existing bundle's runtime).
- 15 fixture checks passed: `dependency-fixture-tests.log`; family/architecture detection, sparse PE import beyond the sampled 8 MiB, persistence, second preflight skip, independent prefix state, stale metadata, builtin/wrong-architecture rejection and failure-state handling.
- Shared native required-component prompt observed through AppKit accessibility; clicked Cancel. 17 checks including unchanged metadata/cache/prefix passed: `dependency-prompt-test.log`.
- All eight official Microsoft installers exited successfully and native DLL verification passed in a disposable prefix: `dependency-all-install.log`. x86 and x64 were installed side by side. 27 assertions passed, including a harmless post-install cmd.exe command under the original test runtime/prefix, persistence and skipping a second v14 install.
- Real repair test deliberately removed msvcp140.dll only from the disposable prefix. Needs repair was reported, the cached official installer ran with /repair, the native DLL was restored and verified installation persisted: `dependency-repair-test.log`.
- 21 existing runtime-manager regression checks passed: `dependency-runtime-tests.log`. Its throwing assertion helper, directory-URL comparisons and missing legacy identity fixture were corrected. Production compiler fixes also resolved an existing duplicate retainGameResources method and overlapping runtimePrefixes access; the retained method preserves the broader resource tracking behavior.
- Existing live Library.json and Runtimes.json decode, selected engine paths and all original game runtime/prefix/successfulRuntime associations verified read-only: `dependency-live-tests.log`.
- Library.json and Runtimes.json SHA-256 hashes match the source checkpoint. Five KH3/Crash prefix trees have identical file paths, sizes, nanosecond mtimes and modes to the pre-test snapshot: `dependency-preservation-results.json`. No production game was launched. The verified GPTK runtime was neither overwritten nor deleted.

## Evidence boundaries and limitations

Static references indicate likely requirements, not complete loader behavior. Uninspected child executables, dynamic plugins and app-local dependency resolution can require manual selection; x86 can be explicitly selected alongside x64. Runtime support for x86 execution is still required. DLL checks establish native component presence and architecture, not minimum version, publisher identity, complete runtime compatibility or gameplay. Exact minimum-version analysis and Authenticode verification are not implemented; HTTPS provenance and cache SHA-256 are the current download checks. DirectX/.NET require future catalog/detection support.

The shared native prompt/cancellation and installer/verification/post-install launch backend were exercised. The entire production GUI Install & Relaunch interaction was not driven end-to-end against a real game. No KH3/Crash launch or gameplay claim is made. Their prefixes and runtime assignments remain untouched.
