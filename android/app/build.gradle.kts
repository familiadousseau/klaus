import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Assinatura fixa: o CI cria android/app/klaus.jks a partir de um segredo do GitHub.
// Assim cada versão nova instala por cima da anterior no telemóvel.
val klausKeystore = File(projectDir, "klaus.jks")

android {
    namespace = "com.familiadousseau.klaus"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.familiadousseau.klaus"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("klaus") {
            if (klausKeystore.exists()) {
                storeFile = klausKeystore
                storePassword = System.getenv("KLAUS_STORE_PASSWORD") ?: "klaus-app"
                keyAlias = System.getenv("KLAUS_KEY_ALIAS") ?: "klaus"
                keyPassword = System.getenv("KLAUS_KEY_PASSWORD") ?: "klaus-app"
            }
        }
    }

    // Código nativo que prepara o áudio para o modelo da palavra "Klaus" (microWakeWord).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            signingConfig = if (klausKeystore.exists()) signingConfigs.getByName("klaus")
                            else signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
