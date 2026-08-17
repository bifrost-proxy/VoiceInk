# Building VoiceInk

This guide provides detailed instructions for building VoiceInk from source.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- Xcode (latest version recommended)
- Swift (latest version recommended)
- Git (for cloning repositories)

## Quick Start with Makefile (Recommended)

The easiest way to build VoiceInk is using the included Makefile, which automates the entire build process including Whisper, sherpa-onnx, and ONNX Runtime frameworks.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/bifrost-proxy/VoiceInk.git
cd VoiceInk

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

- `make check` or `make healthcheck` - Verify all required tools are installed
- `make whisper` - Clone and build whisper.cpp XCFramework automatically
- `make setup` - Prepare the whisper framework for linking
- `make build` - Build the VoiceInk Xcode project
- `make local` - Build for local use (no Apple Developer certificate needed)
- `make run` - Launch the built VoiceInk app
- `make dev` - Build and run (ideal for development workflow)
- `make all` - Complete build process (default)
- `make clean` - Remove build artifacts and dependencies
- `make help` - Show all available commands

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies**: Creates a dedicated `~/VoiceInk-Dependencies` directory for Whisper and prepares the local sherpa-onnx package
2. **Builds Whisper Framework**: Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking**: Sets up Whisper, sherpa-onnx, and ONNX Runtime frameworks in the locations expected by Xcode
4. **Verifies Prerequisites**: Checks that git, xcodebuild, and swift are installed before building
5. **Streamlines Development**: Provides convenient shortcuts for common development tasks

This approach ensures consistent builds across different machines and eliminates manual framework setup errors.

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/bifrost-proxy/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

This builds VoiceInk with ad-hoc signing using a separate build configuration (`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `VoiceInk.local.entitlements` (stripped-down, no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

Your normal `make all` / `make build` commands are completely unaffected.

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow these steps:

### Building whisper.cpp Framework

1. Clone and build whisper.cpp:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```
This will create the XCFramework at `build-apple/whisper.xcframework`.

### Building VoiceInk

1. Clone the VoiceInk repository:
```bash
git clone https://github.com/bifrost-proxy/VoiceInk.git
cd VoiceInk
```

2. Prepare the verified sherpa-onnx and ONNX Runtime frameworks:

```bash
./scripts/prepare-sherpa-onnx.sh
```

3. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project navigator, or
   - Add it manually in the "Frameworks, Libraries, and Embedded Content" section of project settings

4. Build and Run
   - Build the project using Cmd+B or Product > Build
   - Run the project using Cmd+R or Product > Run

## Development Setup

1. **Xcode Configuration**
   - Ensure you have the latest Xcode version
   - Install any required Xcode Command Line Tools

2. **Dependencies**
   - The project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) for transcription
   - Ensure the whisper.xcframework is properly linked in your Xcode project
   - Test the whisper.cpp installation independently before proceeding

3. **Building for Development**
   - Use the Debug configuration for development
   - Enable relevant debugging options in Xcode

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

## Troubleshooting

If you encounter any build issues:
1. Clean the build folder (Cmd+Shift+K)
2. Clean the build cache (Cmd+Shift+K twice)
3. Check Xcode and macOS versions
4. Verify all dependencies are properly installed
5. Make sure whisper.xcframework is properly built and linked

For more help, check the [issues](https://github.com/bifrost-proxy/VoiceInk/issues) section or create a new issue.

## Publishing a Release

Pushing a `vMAJOR.MINOR.PATCH` tag runs `.github/workflows/release.yml`. The workflow builds and validates the app, publishes the GitHub Release assets, and then updates `Casks/voiceink.rb` in `bifrost-proxy/homebrew-voiceink`.

The repository must define an Actions secret named `HOMEBREW_TAP_TOKEN`. Use a fine-grained personal access token scoped only to `bifrost-proxy/homebrew-voiceink` with repository contents read and write access. The default `GITHUB_TOKEN` cannot update a different repository.

Homebrew tap updates are serialized. Before committing, the workflow compares the published version with the version already in the tap and skips older releases, so overlapping release jobs cannot downgrade the Cask.
