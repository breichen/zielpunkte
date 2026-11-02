# Zielpunkte

    flutter create .        # erzeugt android/ios/web-Ordner im bestehenden Projekt
    flutter pub get
    flutter run

## Erinnerungen einrichten (nur Android/iOS)

### Android

1. `android/app/src/main/AndroidManifest.xml`

   Vor `<application ...>` einfügen:

       <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
       <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>

   Innerhalb von `<application ...>` (z. B. direkt vor `</application>`):

       <receiver android:exported="false"
           android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
       <receiver android:exported="false"
           android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
           <intent-filter>
               <action android:name="android.intent.action.BOOT_COMPLETED"/>
               <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
               <action android:name="android.intent.action.QUICKBOOT_POWERON" />
               <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
           </intent-filter>
       </receiver>

2. `android/app/build.gradle` (bzw. `build.gradle.kts`): Desugaring aktivieren

       android {
           compileOptions {
               coreLibraryDesugaringEnabled true
               sourceCompatibility JavaVersion.VERSION_1_8
               targetCompatibility JavaVersion.VERSION_1_8
           }
       }
       dependencies {
           coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'
       }

   (In der `.kts`-Variante: `isCoreLibraryDesugaringEnabled = true` und
   `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`.)

### iOS

In `ios/Runner/AppDelegate.swift` in `application(_:didFinishLaunchingWithOptions:)`
vor dem `return` einfügen:

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

(`import UserNotifications` ergänzen, falls nötig.)
