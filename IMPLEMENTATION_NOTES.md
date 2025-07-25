# Window Scale Persistence Implementation

## Overview
This implementation adds window size persistence for both main and compact windows in the PVPHUB addon. Previously, window scales would reset to default (Medium/1.0) every time the user logged in, requiring them to re-select their preferred scale.

## Changes Made

### 1. Settings Structure Enhancement
- Added `mainWindowScale = 1.0` to `PVPHUB_SETTINGS` for main window scale persistence
- Added `compactWindowScale = 1.0` to `PVPHUB_SETTINGS` for compact window scale persistence

### 2. Main Window Scale Persistence
- Modified main window creation to load saved scale: `f.currentScale = PVPHUB_SETTINGS.mainWindowScale or 1.0`
- Added immediate scale application: `f:SetScale(f.currentScale)`
- Updated scale button onClick handlers to save scale: `PVPHUB_SETTINGS.mainWindowScale = self.scaleValue`

### 3. Compact Window Scale Persistence  
- Modified compact window creation to load saved scale: `PVPHUB.compactWindow.currentScale = PVPHUB_SETTINGS.compactWindowScale or 1.0`
- Added immediate scale application: `PVPHUB.compactWindow:SetScale(PVPHUB.compactWindow.currentScale)`
- Updated scale button onClick handlers to save scale: `PVPHUB_SETTINGS.compactWindowScale = self.scaleValue`

### 4. Settings Initialization
- Added backwards compatibility checks in ADDON_LOADED handler:
  ```lua
  if not PVPHUB_SETTINGS.mainWindowScale then
      PVPHUB_SETTINGS.mainWindowScale = 1.0
  end
  if not PVPHUB_SETTINGS.compactWindowScale then
      PVPHUB_SETTINGS.compactWindowScale = 1.0
  end
  ```

### 5. Code Quality Improvements
- Fixed syntax errors in original code (missing parentheses and braces)
- Removed duplicate ADDON_LOADED event handlers that would have caused conflicts
- Verified Lua syntax validity

## Testing
Comprehensive testing was performed to verify:
- Settings initialization with defaults for new users
- Settings preservation for existing users  
- Scale loading and application on window creation
- Scale saving when users click scale buttons
- Full logout/login persistence cycle

## Usage
Users can now:
1. Set main window to any scale (S/M/L/XL) - it will persist across sessions
2. Set compact window to any scale (S/M/L/XL) - it will persist across sessions  
3. Use different scales for each window type
4. Have their preferences automatically restored on login

## Files Modified
- `PVPHUB_core.lua` - Main addon file containing all functionality

## Backwards Compatibility
- Existing users will see no change in behavior initially (defaults to Medium)
- New scale settings are automatically initialized for existing users
- No saved variable corruption or data loss