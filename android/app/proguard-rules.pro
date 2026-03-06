-keep class org.drinkless.tdlib.** { *; }

-keep class com.nebula.nebula_client.** { *; }
-keepnames class com.nebula.nebula_client.** { *; }
-keepattributes Exceptions,InnerClasses,Signature,Deprecated,SourceFile,LineNumberTable,*Annotation*,EnclosingMethod
-keep class androidx.lifecycle.DefaultLifecycleObserver { *; }

-keepclasseswithmembernames class * {
    native <methods>;
}

# Firebase / GMS
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# FirebaseCrashlytics
-dontwarn javax.xml.stream.**
-dontwarn org.apache.tika.**

-ignorewarnings