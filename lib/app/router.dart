import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/auth/auth_provider.dart';
import '../core/auth/auth_state.dart';
import '../core/api/nebula_api.dart';
import '../features/splash/splash_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/auth/auth_screen.dart';
import '../features/auth/master_pass_screen.dart';
import '../features/onboarding/setup_screen.dart';
import '../features/onboarding/seed_screen.dart';
import '../features/onboarding/seed_verification_screen.dart';
import '../features/onboarding/restore_wallet_screen.dart';
import '../features/onboarding/cloud_restore_screen.dart';
import '../features/onboarding/cloud_unlock_screen.dart';
import '../features/onboarding/cartridge_setup_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/explorer/explorer_screen.dart';
import '../features/lock/lock_screen.dart';
import '../features/telegram/telegram_test_screen.dart';
import '../features/settings/screens/api_settings_screen.dart';
import '../features/auth/sync_conflict_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text("Home Vault")));
  }
}

class _AuthNotifierListenable extends ChangeNotifier {
  _AuthNotifierListenable(this._ref) {
    _ref.listen(authProvider, (previous, next) {
      if (previous?.status != next.status ||
          previous?.sessionTimestamp != next.sessionTimestamp ||
          previous?.hasCloudMetadata != next.hasCloudMetadata) {
        notifyListeners();
      }
    });
  }

  final Ref _ref;

  AuthState get authState => _ref.read(authProvider);
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthNotifierListenable(ref);

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      final auth = listenable.authState;
      final location = state.matchedLocation;

      if (auth.status == AuthStateStatus.initializing) {
        return location == '/' ? null : '/';
      }

      if (auth.status == AuthStateStatus.locked) {
        const allowed = ['/lock', '/restore-wallet'];
        if (allowed.contains(location)) return null;
        debugPrint('[Router] Redirecting to /lock (Session Locked)');
        return '/lock';
      }

      if (auth.status == AuthStateStatus.vaultCorrupted) {
        const allowed = ['/lock', '/restore-wallet', '/cloud-restore'];
        if (allowed.contains(location)) return null;
        return '/lock';
      }

      const onboardingPaths = [
        '/onboarding',
        '/welcome',
        '/cartridge_setup',
      ];
      const authInputStatuses = [
        AuthStateStatus.waitingForPhone,
        AuthStateStatus.waitingForCode,
        AuthStateStatus.waitingForPassword,
        AuthStateStatus.waitingForOtherDevice,
        AuthStateStatus.rekeyRequired,
      ];
      if (authInputStatuses.contains(auth.status)) {
        if (location == '/auth') return null;
        debugPrint('[Router] Auth Input Required (${auth.status}). Mandatory redirect to /auth');
        return '/auth';
      }

      if (auth.status == AuthStateStatus.needsVaultSetup) {
        const setupRoutes = ['/seed_intro', '/master_pass', '/seed', '/seed_verify'];
        if (setupRoutes.contains(location)) return null;
        debugPrint('[Router] Rule 1: No Vault. Redirecting to /seed_intro');
        return '/seed_intro';
      }

      if (auth.status == AuthStateStatus.needsRestore) {
        if (auth.hasCloudMetadata) {
          const cloudRoutes = ['/cloud-unlock', '/restore-wallet'];
          if (cloudRoutes.contains(location)) return null;
          debugPrint('[Router] Rule 3: Cloud Vault exists. Redirecting to /cloud-unlock');
          return '/cloud-unlock';
        } else {
          if (location == '/restore-wallet') return null;
          debugPrint('[Router] Rule 4: No Cloud. Redirecting to /restore-wallet');
          return '/restore-wallet';
        }
      }

      if (auth.status == AuthStateStatus.needsCloudUnlock) {
        const cloudUnlockRoutes = [
          '/cloud-unlock',
          '/restore-wallet',
        ];
        if (cloudUnlockRoutes.contains(location)) return null;
        return '/cloud-unlock';
      }
      if (auth.status == AuthStateStatus.syncRequired) {
        if (location == '/sync-conflict') return null;
        return '/sync-conflict';
      }

      if (auth.status == AuthStateStatus.ready) {
        final isCoreOpen = NebulaApi.instance.isInitialized;

        const authorizedRoutes = [
          '/home',
          '/telegram_test',
          '/api_settings',
        ];

        const onboardingOrRestoreRoutes = [
          '/master_pass',
          '/seed_intro',
          '/seed_verify',
          '/restore-wallet',
          '/cloud-restore',
          '/cloud-unlock',
          '/sync-conflict',
        ];

        final isGateway = location == '/login' || location == '/welcome' || location == '/';
        if (isGateway && isCoreOpen) {
          return '/home';
        }

        if (authorizedRoutes.contains(location) && !isCoreOpen) {
          debugPrint('[Router] Blocked access to $location: Core is not initialized.');
          return '/lock';
        }

        if (onboardingOrRestoreRoutes.contains(location) && !isCoreOpen) {
          return null;
        }

        if (onboardingOrRestoreRoutes.contains(location) && isCoreOpen) {
          return '/home';
        }

        if (authorizedRoutes.contains(location)) {
          return null;
        }

        return isCoreOpen ? '/home' : '/lock';
      }
  
      if (auth.status == AuthStateStatus.error) {
        const errorAllowed = ['/onboarding', '/api_settings', '/cartridge_setup'];
        if (errorAllowed.contains(location)) return null;
        debugPrint('[Router] ERROR state detected: ${auth.errorMessage}. Redirecting to /onboarding');
        return '/onboarding';
      }

      if (auth.status == AuthStateStatus.initial) {
        if (location == '/') {
          debugPrint('[Router] Rule 0: Fresh Start. Forwarding from Splash to /onboarding');
          return '/onboarding';
        }

        const publicPaths = [
          '/welcome',
          '/onboarding',
          '/cartridge_setup',
          '/api_settings',
          '/api-settings',
          '/restore-wallet',
          '/auth', 
        ];
        if (publicPaths.contains(location)) return null;
        return '/onboarding';
      }

      if (auth.status == AuthStateStatus.loading || auth.status == AuthStateStatus.initializing) {
        final liveScreens = [
          '/login', 
          '/cloud-restore', 
          '/cloud-unlock',
          '/restore-wallet', 
          '/auth', 
          '/master_pass',
          '/sync-conflict'
        ];
        if (liveScreens.contains(location)) return null;

        if (location == '/') return null;
        return '/';
      }

      if (auth.status == AuthStateStatus.vaultOrphaned || auth.status == AuthStateStatus.vaultCorrupted) {
        if (location == '/restore-wallet') return null;
        return '/restore-wallet';
      }

      return null;

      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/master_pass',
        builder: (context, state) => const MasterPassScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: '/lock',
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(

        path: '/seed_intro',
        builder: (context, state) => const SeedScreen(),
      ),
      GoRoute(
        path: '/seed_verify',
        builder: (context, state) => const SeedVerificationScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const ExplorerScreen(),
      ),
      GoRoute(
        path: '/restore-wallet',
        builder: (context, state) => const RestoreWalletScreen(),
      ),
      GoRoute(
        path: '/cloud-restore',
        builder: (context, state) => const CloudRestoreScreen(),
      ),
      GoRoute(
        path: '/cloud-unlock',
        builder: (context, state) => const CloudUnlockScreen(),
      ),
      GoRoute(
        path: '/sync-conflict',
        builder: (context, state) => const SyncConflictScreen(),
      ),
      GoRoute(
        path: '/telegram_test',
        builder: (context, state) => const TelegramTestScreen(),
      ),
      GoRoute(
        path: '/cartridge_setup',
        builder: (context, state) => const CartridgeSetupScreen(),
      ),
      GoRoute(
        path: '/api_settings',
        builder: (context, state) => const ApiSettingsScreen(),
      ),
    ],
  );

  ref.onDispose(listenable.dispose);

  return router;
});
