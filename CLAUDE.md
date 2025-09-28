# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Swift Package Manager project containing three command-line utilities:

- **swbuilder** (`Sources/SwiftBuilder/`) - Build tool for Xcode projects and Swift packages with run/restart/archive capabilities
- **swcompare** (`Sources/SwiftCompare/`) - Interactive tool to compare two lists and find common/unique elements
- **swconfigs** (`Sources/SwiftConfigs/`) - Configuration file downloader for Swift projects

The project uses Swift 6.2+ and targets macOS 26.0+. All executables use ArgumentParser for CLI interfaces and PolyKit utilities for logging/text output.

## Build Commands

- `swift build` - Build all executables
- `swift run swbuilder` - Run the builder tool directly
- `swift run swcompare` - Run the comparison tool directly
- `swift run swconfigs` - Run the config tool directly
- `.build/debug/swbuilder`, `.build/debug/swcompare`, `.build/debug/swconfigs` - Run built executables directly

## Code Quality

- `swiftlint` - Lint Swift code (configured in `.swiftlint.yml`)
- No test suite currently exists (shows "error: no tests found")

## Architecture

### SwiftBuilder (`Sources/SwiftBuilder/SwiftBuilder.swift`)

The builder tool automatically detects project types (Xcode vs Swift Package) and provides:

- Build operations for both Xcode projects and Swift packages
- Run/restart functionality with process management
- Release archiving for Xcode projects with version setting
- Built app discovery in DerivedData and local build directories

Key methods:

- `determineProjectType(at:)` - Auto-detects Xcode vs Swift package
- `buildForDevelopment(projectType:)` - Handles debug builds and running
- `archiveForRelease(projectType:version:)` - Release archiving for Xcode

### SwiftCompare (`Sources/SwiftCompare/SwiftCompare.swift`)

Interactive list comparison tool with:

- Case-sensitive/insensitive comparison options
- Set-based comparison logic for finding common/unique elements
- Color-coded terminal output using PolyText

### SwiftConfigs (`Sources/SwiftConfigs/SwiftConfigs.swift`)

Configuration management tool that downloads standard project files:

- `.gitignore`, `.swiftlint.yml` (live configs - can overwrite)
- `Package.swift`, `project.code-workspace` (templates - never overwrite existing)
- Downloads from GitHub repository templates

## Dependencies

- `swift-argument-parser` (1.6.1+) - CLI argument parsing
- `polykit-swift` (main branch) - Provides PolyLog for logging and PolyText for colored output

## SwiftLint Configuration

The project uses a relaxed SwiftLint configuration (`.swiftlint.yml`):

- Disables line_length, trailing_comma, type_body_length rules
- Excludes `.build/` and `Packages/` directories
- Auto-updates enabled
