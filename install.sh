#!/bin/zsh
# Patch Nova.app to load the injection dylib on every launch.
# Re-run after Nova updates.

SCRIPT_DIR="${0:a:h}"
SRC_DYLIB="$SCRIPT_DIR/nova_extension_claude.dylib"
DST_DYLIB="/Applications/Nova.app/Contents/Frameworks/nova_extension_claude.dylib"
PLIST="/Applications/Nova.app/Contents/Info.plist"

if [[ ! -f "$SRC_DYLIB" ]]; then
    echo "Error: $SRC_DYLIB not found"
    exit 1
fi

if [[ ! -f "$PLIST" ]]; then
    echo "Error: $PLIST not found"
    exit 1
fi

# Copy dylib into the app bundle
cp "$SRC_DYLIB" "$DST_DYLIB"

# Remove existing LSEnvironment if present, then add fresh
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null
/usr/libexec/PlistBuddy \
    -c "Add :LSEnvironment dict" \
    -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $DST_DYLIB" \
    "$PLIST"

# Re-sign the dylib and app (plist change invalidates the signature)
codesign -f -s - "$DST_DYLIB"
codesign -f -s - /Applications/Nova.app

# Rebuild launch services database
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Nova.app

echo "Done. Restart Nova to apply."
