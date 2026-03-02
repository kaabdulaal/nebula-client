import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import '../settings/dialogs/proxy_settings_dialog.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen>
    with SingleTickerProviderStateMixin {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();

  late final AnimationController _shimmerController;
  late final Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _phoneController.text = '+';

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _shimmerAnimation = Tween<double>(begin: -1.5, end: 1.5).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authProvider.select((s) => s.errorMessage), (_, errorMsg) {
      if (errorMsg != null && errorMsg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(errorMsg),
            backgroundColor: Colors.redAccent,
          ));
      }
    });

    ref.listen(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.initial ||
          next.status == AuthStateStatus.waitingForPhone) {
        if (previous?.status != next.status) {
          _phoneController.text = '+';
          _codeController.clear();
          _passwordController.clear();
        }
      }
    });

    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Telegram Login'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_ethernet, color: Colors.white70),
            tooltip: 'Proxy Settings',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => const ProxySettingsDialog(),
              );
            },
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: _buildBody(context, authState),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AuthState state) {
    switch (state.status) {
      case AuthStateStatus.initializing:
      case AuthStateStatus.initial:
      case AuthStateStatus.waitingForParams:
        return _buildInitializingScreen();

      case AuthStateStatus.loading:
        return _buildProcessingScreen();

      case AuthStateStatus.waitingForPhone:
        return _buildPhoneInput(state);

      case AuthStateStatus.waitingForCode:
        return _buildCodeInput(state);

      case AuthStateStatus.waitingForPassword:
        return _buildPasswordInput(state);

      case AuthStateStatus.waitingForOtherDevice:
        return _buildQrCodeScreen(state);

      case AuthStateStatus.ready:
        return const Center(
          key: ValueKey('ready'),
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0088CC)),
          ),
        );

      case AuthStateStatus.error:
        return _buildErrorScreen(state);

      case AuthStateStatus.rekeyRequired:
        return _buildRekeyInput(state);

      default:
        return _buildInitializingScreen();
    }
  }

  Widget _buildRekeyInput(AuthState state) {
    return SingleChildScrollView(
      key: const ValueKey('rekey'),
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Password Changed',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            state.errorMessage ??
                'The vault password was changed on another device. Please enter the NEW password to update this device.',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'New Password',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (val) {
              if (val.isNotEmpty) {
                ref.read(authProvider.notifier).submitRekeyPassword(val);
              }
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                final pass = _passwordController.text;
                if (pass.isNotEmpty) {
                  ref.read(authProvider.notifier).submitRekeyPassword(pass);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Update & Unlock'),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildInitializingScreen() {
    return const Center(
      key: ValueKey('initializing'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0088CC)),
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Initializing Nebula...',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessingScreen() {
    return const Center(
      key: ValueKey('processing'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0088CC)),
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Processing...',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorScreen(AuthState state) {
    return Center(
      key: const ValueKey('error'),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              state.errorMessage ?? 'Unknown Error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (state.errorMessage?.contains('Connection') ?? false) ...[
              const SizedBox(height: 12),
              const Text(
                'Trouble connecting? Try adjusting Proxy settings in the top right menu.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const ProxySettingsDialog(),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  child: const Text('Proxy Settings'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () => ref.read(authProvider.notifier).resetError(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0088CC),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildPhoneInput(AuthState state) {
    return SingleChildScrollView(
      key: const ValueKey('phone'),
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your Phone',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please confirm your country code and enter your phone number.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Phone Number',
              hintText: '+1234567890',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) {
                ref.read(authProvider.notifier).sendPhoneNumber(val.trim());
              }
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                final phone = _phoneController.text.trim();
                if (phone.isNotEmpty) {
                  ref.read(authProvider.notifier).sendPhoneNumber(phone);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Next'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeInput(AuthState state) {
    final displayPhone = state.phoneNumber ?? _phoneController.text;

    return SingleChildScrollView(
      key: const ValueKey('code'),
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter Code',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'We sent a code to $displayPhone',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Code',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (val) {
              if (val.isNotEmpty) {
                ref.read(authProvider.notifier).checkCode(val);
              }
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                final code = _codeController.text.trim();
                if (code.isNotEmpty) {
                  ref.read(authProvider.notifier).checkCode(code);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Verify'),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton(
              onPressed: () {
                _codeController.clear();
                ref.read(authProvider.notifier).cancelLogin();
              },
              child: const Text(
                'Change Number',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordInput(AuthState state) {
    return SingleChildScrollView(
      key: const ValueKey('password'),
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Two-Step Verification',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your account is protected with an additional password.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Password',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (val) {
              if (val.isNotEmpty) {
                ref.read(authProvider.notifier).submitTelegram2FAPassword(val);
              }
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                final pass = _passwordController.text;
                if (pass.isNotEmpty) {
                  ref.read(authProvider.notifier).submitTelegram2FAPassword(pass);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Unlock'),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildQrCodeScreen(AuthState state) {
    final qrLink = state.qrLink;
    final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    final showPhoneInput = state.preferPhoneNumber;

    return SingleChildScrollView(
      key: const ValueKey('qr'),
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Scan QR Code',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Open Telegram on your phone and go to\nSettings > Devices > Link Desktop Device',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 32),

          Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: qrLink != null
                  ? _buildQrImage(qrLink)
                  : _buildQrShimmer(),
            ),
          ),

          const SizedBox(height: 12),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: qrLink != null
                ? const SizedBox(
                    key: ValueKey('qr-ready'),
                    height: 20,
                    child: Text(
                      'QR code ready — scan with Telegram',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  )
                : const SizedBox(
                    key: ValueKey('qr-loading'),
                    height: 20,
                    child: Text(
                      'Generating secure QR code...',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
          ),

          const SizedBox(height: 40),

          if (isDesktop) _buildPhoneToggleSection(showPhoneInput),
        ],
      ),
    );
  }

  Widget _buildQrImage(String qrLink) {
    return Container(
      key: const ValueKey('qr-image'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0088CC).withValues(alpha: 0.25),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: QrImageView(
        data: qrLink,
        version: QrVersions.auto,
        size: 200.0,
        backgroundColor: Colors.white,
      ),
    );
  }

  Widget _buildQrShimmer() {
    return AnimatedBuilder(
      key: const ValueKey('qr-shimmer'),
      animation: _shimmerAnimation,
      builder: (context, _) {
        return Container(
          width: 232,
          height: 232,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [
                math.max(0.0, _shimmerAnimation.value - 0.3),
                math.max(0.0, math.min(1.0, _shimmerAnimation.value)),
                math.min(1.0, _shimmerAnimation.value + 0.3),
              ],
              colors: const [
                Color(0xFF2A2A2A),
                Color(0xFF3A3A3A),
                Color(0xFF2A2A2A),
              ],
              transform: const GradientRotation(math.pi / 4),
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      const Color(0xFF0088CC).withValues(alpha: 0.7),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Loading...',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhoneToggleSection(bool showPhoneInput) {
    return AnimatedCrossFade(
      firstChild: SizedBox(
        width: double.infinity,
        height: 56,
        child: OutlinedButton(
          onPressed: () {
            ref.read(authProvider.notifier).switchToPhoneNumber();
          },
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF0088CC)),
            foregroundColor: const Color(0xFF0088CC),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Login with Phone Number'),
        ),
      ),
      secondChild: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            autofocus: showPhoneInput,
            decoration: InputDecoration(
              labelText: 'Phone Number',
              hintText: '+1234567890',
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) {
                ref.read(authProvider.notifier).sendPhoneNumber(val.trim());
              }
            },
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                final phone = _phoneController.text.trim();
                if (phone.isNotEmpty) {
                  ref.read(authProvider.notifier).sendPhoneNumber(phone);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Next'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              ref.read(authProvider.notifier).requestQrCodeAuthentication();
            },
            child: const Text(
              'Back to QR Code',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
      crossFadeState: showPhoneInput
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 300),
    );
  }
}
