#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p 'CrossPlay.app/Contents/MacOS' 'CrossPlay.app/Contents/Resources'
cp Sources/Info.plist 'CrossPlay.app/Contents/Info.plist'
swiftc -module-cache-path Build/CrossPlayModuleCache -target arm64-apple-macos15.0 Sources/ExecutionHost.swift Sources/Wrapper.swift Sources/PEIcon.swift Sources/GameArtwork.swift Sources/RuntimeRegistry.swift Sources/GameDependencyManager.swift Sources/CrossPlayUI.swift Sources/main.swift -o 'CrossPlay.app/Contents/MacOS/CrossPlay'
swiftc -module-cache-path Build/CrossPlayModuleCache -target arm64-apple-macos15.0 Sources/Bootstrap.swift -o CrossPlay.app/Contents/Resources/CrossPlayBootstrap
if [[ -d Runtime/wine && ${SKIP_RUNTIME:-0} != 1 ]]; then
  ditto Runtime/wine 'CrossPlay.app/Contents/Resources/Runtime'
fi
mkdir -p 'CrossPlay.app/Contents/Resources/Licenses'
cp Evidence/Apple-License.txt 'CrossPlay.app/Contents/Resources/Licenses/'
cp 'RuntimeMedia/Extracted/Evaluation environment for Windows games 4.0 beta 1/License.rtf' 'CrossPlay.app/Contents/Resources/Licenses/Apple-License.rtf'
cp 'RuntimeMedia/Extracted/Evaluation environment for Windows games 4.0 beta 1/Acknowledgements.rtf' 'CrossPlay.app/Contents/Resources/Licenses/Apple-Acknowledgements.rtf'
cp ThirdParty/wine-wine-11.0/COPYING.LIB 'CrossPlay.app/Contents/Resources/Licenses/Wine-LGPL-2.1.txt'
cp ThirdParty/wine-wine-11.0/AUTHORS 'CrossPlay.app/Contents/Resources/Licenses/Wine-AUTHORS.txt'
cp ThirdParty/Patches/wine11-apple-macdrv-interface.patch 'CrossPlay.app/Contents/Resources/Licenses/'

# CROSSPLAY_PERMANENT_ICON
echo "Embedding CrossPlay icon..."
mkdir -p 'CrossPlay.app/Contents/Resources'
cp 'Resources/CrossPlay.icns' 'CrossPlay.app/Contents/Resources/CrossPlay.icns'
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" 'CrossPlay.app/Contents/Info.plist' 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string CrossPlay.icns" 'CrossPlay.app/Contents/Info.plist'

codesign --force --sign - 'CrossPlay.app'


codesign --verify --deep --strict 'CrossPlay.app'
