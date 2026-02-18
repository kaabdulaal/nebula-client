import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/splash/splash_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/auth/auth_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/onboarding/setup_screen.dart';
import '../features/onboarding/seed_screen.dart';
import '../features/onboarding/seed_verification_screen.dart';
import '../features/onboarding/restore_wallet_screen.dart';
import '../features/explorer/explorer_screen.dart';
import '../features/telegram/telegram_test_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text("Home Vault")));
  }
}

final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashScreen(),
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
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/setup_password',
      builder: (context, state) => const SetupScreen(),
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
      path: '/telegram_test',
      builder: (context, state) => const TelegramTestScreen(),
    ),
  ],
);
