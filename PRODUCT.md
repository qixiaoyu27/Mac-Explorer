# Product

<!-- impeccable:product-schema 1 -->

## Platform
web

Desktop application for macOS, rendered inside Electron with native filesystem integration.

## Users and Purpose
A Windows user who finds Finder difficult wants the Windows 11 File Explorer interface and file-management habits on their Mac.

## Commitments
Windows 11 File Explorer is the explicit visual and interaction reference. Preserve its tab strip, breadcrumb address bar, command bar, navigation pane, details list, icon view, and familiar keyboard workflows. Use real Mac files and real filesystem operations.

## Implementation Assumptions
Chinese labels and a light appearance follow the user's language and the Windows 11 reference. Support both Control and Command shortcuts. Electron/React/TypeScript is the implementation choice for layout fidelity and local file access. These are implementation defaults, not additional user-confirmed requirements.

## Constraints
macOS permissions, volumes, application launching, and Trash remain macOS capabilities. This app does not replace Finder or implement Windows-only services such as the registry, drive-letter mapping, Explorer extensions, or OneDrive integration. Never fabricate files, recent history, storage values, or successful operations.
