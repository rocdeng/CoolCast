plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dengpeng.coolcast"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dengpeng.coolcast"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

fun registerCoolCastApkCopyTask(buildType: String) {
    val capitalizedBuildType = buildType.replaceFirstChar { it.uppercase() }
    val versionName = android.defaultConfig.versionName ?: "dev"
    val outputDir = rootProject.layout.buildDirectory.dir("app/outputs/flutter-apk")

    tasks.register<Copy>("copyCoolCast${capitalizedBuildType}Apk") {
        from(layout.buildDirectory.file("outputs/apk/$buildType/app-$buildType.apk"))
        into(outputDir)
        rename { "coolcast-ver$versionName-$buildType.apk" }
        doLast {
            copy {
                from(layout.buildDirectory.file("outputs/apk/$buildType/app-$buildType.apk"))
                into(outputDir)
            }
        }
    }

    afterEvaluate {
        tasks.named("assemble$capitalizedBuildType") {
            finalizedBy("copyCoolCast${capitalizedBuildType}Apk")
        }
    }
}

registerCoolCastApkCopyTask("debug")
registerCoolCastApkCopyTask("release")
