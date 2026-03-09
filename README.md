# Nebula Client

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?logo=Flutter&logoColor=white)](https://flutter.dev)

Nebula is a decentralized, end-to-end encrypted (E2EE) cloud storage solution that leverages Telegram as a secure infrastructure. It transforms your Telegram account into a private, zero-knowledge vault for files and media.

## ⚠️ WARNING: EARLY BETA SOFTWARE ⚠️

- **This application is currently in a Closed Beta testing phase.** > Do NOT use Nebula as the sole storage for important data. Bugs, sync conflicts, or architectural changes may result in permanent data loss. Use it at your own risk for testing and evaluation purposes only.

- **If you just want to test Nebula without building it from source**:

- **Download the latest installer**: Go to the [Releases page](https://github.com/kaabdulaal/nebula-client/releases).

    - **Windows**: Download nebula-windows-v0.1.0-alpha.exe and run the installer.
  
    - **Android**: Download the nebula-android-v0.1.0-alpha.apk directly to your device and install it.

    - **Linux**: Download the nebula-linux-v0.1.0-alpha.tar.gz, extract it, and run the nebula_client binary.
      
## Key Features

- **Zero-Knowledge Architecture**: Encryption happens exclusively on your device. Only you hold the keys to your data.
- **Telegram Infrastructure**: Uses Telegram's reliable distributed servers for storage, requiring no additional cloud subscriptions.
- **Cross-Platform**: Built with Flutter for a consistent experience across Linux and Android (additional platforms coming soon).
- **Local Vault Anchor**: Secure local caching and metadata management ensures your vault remains accessible and responsive.
- **BYOK (Bring Your Own Keys)**: Fully customizable API credentials for advanced users who want total control over their Telegram connection.

## Getting Started

### Prerequisites

- **Flutter SDK**: Stable channel (3.22+ recommended).
- **Core Dependencies**: Nebula requires the `nebula_core` native library. Follow the build instructions in the `nebula_core` repository.
- **Telegram API Credentials**: Obtain your `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org).

### Build & Run

1. Clone the repository and its submodules:
   ```bash
   git clone --recursive https://github.com/nebula-storage/nebula-project.git
   ```
2. Navigate to the client directory:
   ```bash
   cd nebula_client
   ```
3. Install dependencies:
   ```bash
   flutter pub get
   ```
4. Run the application:
   ```bash
   flutter run
   ```

### 🪟 Windows

- **Building on Windows requires specific C++ environments and DLL management to avoid memory heap collisions.**

    <ol type="1">
      <li>Install Visual Studio 2022 with the "Desktop development with C++" workload.</li>
      <li>Build the project in release mode:
        <pre><code>flutter build windows --release</code></pre>
      </li>
    </ol>

- **CRITICAL**: Ensure the required native libraries (jsoncpp.dll, libcrypto-1_1-x64.dll, libssl-1_1-x64.dll, and TDLib dependencies) are placed directly in the build\windows\x64\runner\Release\ directory alongside nebula_client.exe.

- **Note**: Always run the Windows client in --release mode (flutter run -d windows --release) to prevent MSVC CRT (Debug/Release) mismatch crashes when parsing JSON.

## Architecture Overview

- **State Management**: Uses **Riverpod** for predictable, reactive state handling and dependency injection.
- **Cryptography**: High-performance AES-256-GCM streaming via **Dart FFI** to the OpenSSL-powered `nebula_core` engine.
- **Storage Layer**: Local SQLite database for rapid metadata indexing and file state tracking.
- **Navigation**: Structured routing managed by **go_router**.

## Contributing

We welcome community contributions. To contribute:
1. Fork the repository.
2. Create a feature branch.
3. Submit a Pull Request following our internal coding guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
