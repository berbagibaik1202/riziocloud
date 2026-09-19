# RizIO Flutter

## Prasyarat

- Flutter SDK terpasang dan `flutter doctor` tidak melaporkan masalah Android.
- Android SDK, Android SDK Platform, dan Android SDK Build-Tools tersedia.
- Java 17 tersedia untuk Gradle/Kotlin.

Cek lingkungan dari folder ini:

```powershell
flutter doctor
flutter --version
```

## Menyiapkan project

Jalankan semua perintah berikut dari `mobile/flutter`:

```powershell
flutter pub get
```

Endpoint API tidak disimpan permanen di source code. Berikan melalui `--dart-define` saat menjalankan atau build aplikasi.

## Menjalankan mode development

```powershell
flutter run --dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

Untuk endpoint lokal, ganti nilainya, misalnya `http://10.0.2.2:3000/v1` untuk Android Emulator atau alamat LAN untuk perangkat fisik.

## Build APK debug

Build ini cocok untuk pengujian dan ukurannya besar karena berisi metadata debug:

```powershell
flutter build apk --debug `
	--dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

Artifact:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Jangan gunakan APK debug untuk distribusi ke pengguna.

## Build APK release

Untuk APK release yang kompatibel dengan beberapa arsitektur Android:

```powershell
flutter build apk --release --split-per-abi `
	--dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

Artifact berada di:

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
build/app/outputs/flutter-apk/app-x86_64-release.apk
```

Gunakan `app-arm64-v8a-release.apk` untuk mayoritas perangkat Android modern. Gunakan `app-armeabi-v7a-release.apk` untuk perangkat Android 32-bit lama. APK universal dapat dibuat tanpa `--split-per-abi`, tetapi ukurannya lebih besar:

```powershell
flutter build apk --release `
	--dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

## Build untuk Google Play

Google Play umumnya menggunakan Android App Bundle:

```powershell
flutter build appbundle --release `
	--dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

Artifact:

```text
build/app/outputs/bundle/release/app-release.aab
```

Play Store akan membuat split APK sesuai perangkat pengguna, sehingga ukuran unduhan lebih kecil.

## Signing release

Konfigurasi saat ini masih menggunakan debug key untuk build release internal. Sebelum upload ke Play Store atau distribusi produksi, buat keystore release dan konfigurasi `signingConfigs` di `android/app/build.gradle.kts`. Simpan keystore dan password di luar repository; jangan commit file `.jks`, password, atau `key.properties`.

## Mengatasi cache build Kotlin

Jika build gagal dengan pesan `this and base files have different roots` atau error cache `mobile_scanner`, bersihkan artifact yang dapat dibuat ulang:

```powershell
flutter clean
flutter pub get
flutter build apk --release --split-per-abi `
	--dart-define=API_BASE_URL=https://rizio.rizbill.my.id/v1
```

Jika proses Gradle lama masih aktif, hentikan dari terminal Android/Gradle yang sedang berjalan sebelum mengulang build.

## Ukuran build

APK debug dapat berukuran lebih dari 100 MB karena runtime dan metadata debugging. APK release split ABI lebih kecil karena hanya membawa native library untuk satu arsitektur. Dependency `mobile_scanner` juga menyertakan library native kamera yang diperlukan untuk scan QR.
# rizio

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
