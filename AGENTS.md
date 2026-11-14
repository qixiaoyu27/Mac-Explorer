# Repository Guidelines

## Branch Layout

`main` maintains the Swift/AppKit application in `native/`. `electron` preserves the Electron implementation. For native builds and checks, follow `native/README.md`: use `python3 -I native/scripts/build.py`, `python3 -I native/scripts/check-core.py`, and `python3 -I native/scripts/smoke.py --validation`. Native outputs in `native/output/` and `native/.build/` are generated and must remain untracked. The Electron directories below remain as legacy code and shared build resources; do not remove them without checking native build dependencies.

Always run native builds and checks in the background. Do not open, raise, or activate app windows or run the smoke test in `--foreground` or `--direct-launch` mode. If a check requires a visible or active window, leave it unrun and report that coverage gap.

## Project Structure & Module Organization (Electron)

Mac Explorer is an Electron application that reproduces Windows 11 File Explorer workflows on macOS. `src/` contains the React interface and CSS tokens; `electron/` owns native integration, filesystem operations, undo history, and the isolated preload bridge. `shared/types.ts` defines the IPC contract. `tests/` contains filesystem tests; `scripts/` contains build, icon, and desktop smoke tooling. Generated application bundles live in `release/`.

## Build, Test, and Development Commands

Use Node.js 22.12+, macOS, and Xcode Command Line Tools. Builds compile the Swift icon service and C libarchive helper; packaging also generates the application icon.

- `npm ci`: install locked dependencies and the Electron runtime.
- `npm run dev`: start Vite and the desktop application.
- `npm run build`: type-check and bundle renderer, main, and preload code.
- `npm test`: run isolated filesystem regression tests.
- `npm run test:ui`: build and exercise the real Electron application with Playwright.
- `npm run test:theme`: verify appearance modes, persistence, and dark contrast in an isolated instance.
- `npm run test:view`: verify View menus, layouts, pane toggles, and persisted display settings.
- `npm run test:compression`: verify ZIP creation, selection, collisions, and source preservation.
- `npm run test:archive`: verify preview, extraction destinations, and archive safety in temporary directories.
- `npm run test:icons`: verify icon scaling, Retina resolution, and address editing.
- `npm run package`: produce an ad-hoc-signed Apple Silicon `.app`.
- `npm run package:release`: create ad-hoc-signed, unnotarized DMG/ZIP artifacts without developer certificates.

## Coding Style & Naming Conventions

Use strict TypeScript, two-space indentation, single quotes, and semicolons. Components use PascalCase; functions and variables use camelCase. CSS uses descriptive kebab-case classes. No formatter or linter is configured; `tsc --noEmit` is the static gate. Follow `DESIGN.md`: Windows 11 familiarity takes priority over visual reinvention.

## Testing Guidelines

Use Node’s built-in test runner through `tsx`, with `*.test.ts` filenames. Test destructive workflows exclusively in temporary directories. Cover collision handling, symlinks, partial failures, and content preservation when changing filesystem code. The Playwright smoke script verifies keyboard workflows and native integration. No numeric coverage threshold is set. Clearly identify fixture screenshots and distinguish source tests from packaged-app verification.

## Commit & Pull Request Guidelines

The repository uses `main` and began with an initial setup commit. Use concise, imperative commit subjects, such as `Add directory navigation`.

Pull requests should explain the change, its purpose, and validation performed. Link relevant issues and include screenshots for visible interface changes. Keep each submission limited to one coherent task.

## Release Notes Guidelines

- Use the project skill `.agents/skills/mac-explorer-release/SKILL.md` for packaging, installation, source push, and GitHub releases.
- From 1.0.0, follow the SemVer policy in [README.md](README.md#版本策略): PATCH for compatible fixes, MINOR for compatible features, MAJOR for incompatible changes. Choose versions from accumulated release scope, not build count; never overwrite published versions.
- Keep public release notes focused on changes, contributor credit, and installation. Do not include a validation section or test inventory; still perform necessary release checks internally.
- Credit contributions inline after each update item: `（#123，@author）`, linking the PR and its author. Credit the actual contributors rather than only the person who merged the PR.
- Verify attribution against the commits and merged PRs included since the previous release; do not present older contributions as new changes.
- For direct commits without a PR, use `（@author，abc1234）` with links to the author and commit. Never invent a PR number or author.
- Add a separate `贡献者` section when needed to acknowledge verified testing, feedback, or other contributions not already credited in the update items.
- Reopen the published GitHub Release and verify the saved notes and attribution links after publishing or editing.

## Security & Configuration

Keep Node access in the main process, validate IPC arguments, and preserve context isolation and CSP. Never overwrite collisions or permanently delete user files. Exclude credentials and generated artifacts. Do not replace Finder or alter system defaults without explicit authorization.

Keep visible app copy limited to labels, data, concise status/error messages and essential operation confirmations. Do not show persistent explanatory paragraphs, tutorials, marketing copy or implementation details. Question-mark help beside headings or controls is allowed when hidden until hover or keyboard focus.
