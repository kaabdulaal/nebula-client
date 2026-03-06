import 'dart:typed_data';

enum AuthStateStatus {
  initializing,
  loading,
  locked, 
  initial,
  vaultCorrupted, 
  waitingForParams,
  waitingForPhone,
  waitingForCode,
  waitingForPassword,
  waitingForOtherDevice,
  needsVaultSetup,
  needsCloudUnlock,
  needsRestore, 
  syncRequired, 
  rekeyRequired,  
  vaultOrphaned,
  ready,
  error,
}

class AuthState {
  final AuthStateStatus status;
  final String? errorMessage;
  final String? masterKey;       
  final Uint8List? mnemonic;     
  final String? phoneNumber;     
  final String? tempPassword;    
  final String? qrLink;          
  final bool preferPhoneNumber;  
  final int? tgUserId;           
  final int? cloudChannelId;     
  final bool isDiscoveryFallback; 
  final bool hasCloudMetadata;
  final int? sessionTimestamp;   

  const AuthState({
    this.status = AuthStateStatus.initial,
    this.errorMessage,
    this.masterKey,
    this.mnemonic,
    this.phoneNumber,
    this.tempPassword,
    this.qrLink,
    this.preferPhoneNumber = false,
    this.tgUserId,
    this.cloudChannelId,
    this.isDiscoveryFallback = false,
    this.hasCloudMetadata = false,
    this.sessionTimestamp,
  });

  const AuthState.initializing({this.sessionTimestamp})
      : status = AuthStateStatus.initializing,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.locked({this.sessionTimestamp, this.errorMessage})
      : status = AuthStateStatus.locked,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.initial({this.sessionTimestamp})
      : status = AuthStateStatus.initial,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.waitingForParams({this.sessionTimestamp})
      : status = AuthStateStatus.waitingForParams,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.waitingForPhone({this.sessionTimestamp})
      : status = AuthStateStatus.waitingForPhone,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.waitingForCode({this.sessionTimestamp})
      : status = AuthStateStatus.waitingForCode,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.waitingForPassword({this.sessionTimestamp})
      : status = AuthStateStatus.waitingForPassword,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.needsVaultSetup({this.sessionTimestamp})
      : status = AuthStateStatus.needsVaultSetup,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.needsCloudUnlock({this.sessionTimestamp})
      : status = AuthStateStatus.needsCloudUnlock,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = true,
        cloudChannelId = null;

  const AuthState.needsRestore({this.sessionTimestamp})
      : status = AuthStateStatus.needsRestore,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.syncRequired({this.sessionTimestamp})
      : status = AuthStateStatus.syncRequired,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.rekeyRequired({this.sessionTimestamp})
      : status = AuthStateStatus.rekeyRequired,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.vaultCorrupted({this.sessionTimestamp, this.errorMessage})
      : status = AuthStateStatus.vaultCorrupted,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.vaultOrphaned({this.sessionTimestamp, this.errorMessage})
      : status = AuthStateStatus.vaultOrphaned,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.ready({this.sessionTimestamp})
      : status = AuthStateStatus.ready,
        errorMessage = null,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  const AuthState.error(String message, {this.sessionTimestamp})
      : status = AuthStateStatus.error,
        errorMessage = message,
        masterKey = null,
        mnemonic = null,
        phoneNumber = null,
        tempPassword = null,
        qrLink = null,
        preferPhoneNumber = false,
        tgUserId = null,
        isDiscoveryFallback = false,
        hasCloudMetadata = false,
        cloudChannelId = null;

  AuthState copyWith({
    AuthStateStatus? status,
    String? errorMessage,
    String? masterKey,
    Uint8List? mnemonic,
    String? phoneNumber,
    String? tempPassword,
    String? qrLink,
    bool? preferPhoneNumber,
    int? tgUserId,
    int? cloudChannelId,
    bool? isDiscoveryFallback,
    bool? hasCloudMetadata,
    int? sessionTimestamp,
    bool clearError = false,
    bool clearPhone = false,
    bool clearQrLink = false,
    bool clearMnemonic = false,
    bool clearTgUserId = false,
    bool clearCloudChannelId = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      masterKey: masterKey ?? this.masterKey,
      mnemonic: clearMnemonic ? null : (mnemonic ?? this.mnemonic),
      phoneNumber: clearPhone ? null : (phoneNumber ?? this.phoneNumber),
      tempPassword: tempPassword ?? this.tempPassword,
      qrLink: clearQrLink ? null : (qrLink ?? this.qrLink),
      preferPhoneNumber: preferPhoneNumber ?? this.preferPhoneNumber,
      tgUserId: clearTgUserId ? null : (tgUserId ?? this.tgUserId),
      cloudChannelId:
          clearCloudChannelId ? null : (cloudChannelId ?? this.cloudChannelId),
      isDiscoveryFallback: isDiscoveryFallback ?? this.isDiscoveryFallback,
      hasCloudMetadata: hasCloudMetadata ?? this.hasCloudMetadata,
      sessionTimestamp: sessionTimestamp ?? this.sessionTimestamp,
    );
  }
}
