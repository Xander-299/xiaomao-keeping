import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.teacodeman.yanxin"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // 默认是正式包 id；走查机上都装着正式包（versionCode 更高、签名也不同），
        // 直接 `adb install -r` 会 INSTALL_FAILED_VERSION_DOWNGRADE / 签名冲突，**强行装会丢账本**。
        // 所以留一个 QA 侧装口子：`ORG_GRADLE_PROJECT_qaAppId=com.teacodeman.yanxin.qa flutter build apk --debug`
        // 装上后是**并列的第二份 App**（独立数据目录），走查完 `adb uninstall` 即可，不碰用户数据。
        applicationId = (project.findProperty("qaAppId") as String?) ?: "com.teacodeman.yanxin"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABI 交给构建命令决定（`--target-platform android-arm/-arm64/-x64`）：
        // Flutter 会据此设置 abiFilters，**这里不要写死**。
        // 历史：F8.1 曾在 defaultConfig 里写死 arm64+v7a 给正式包瘦身；但 AGP 的
        // abiFilters 在 buildType 层是**并集**，一旦再给 release 补 x86_64（发布页要提供
        // 模拟器包），每个 APK 都会同时塞进三套 ML Kit 原生库（每个 ABI 6–11 MB）。
        // 2026-11-09 起改为不设默认值，按 ABI 分别出包，包体反而更小。
    }

    // ⚠️ `signingConfigs` 必须声明在 `buildTypes` **之前**：
    //    `buildTypes.release { }` 的 lambda 在**配置阶段立即执行**，里面
    //    `signingConfigs.getByName("release")` 会在 signingConfig 注册前求值 →
    //    "SigningConfig with name 'release' not found."（连 debug 构建都在配置阶段挂掉）。
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        debug {
            // 不再需要单独补 x86_64：ABI 由构建命令决定（模拟器用 android-x64）。
        }
        release {
            // 有 `android/key.properties` 时用正式签名；没有（如 clone 仓库的机器）回退
            // debug 签名，保证 `flutter build apk --release` 仍能跑通。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // ⚠️ F8.1 真机实测（2026-10-24）：Flutter 的 release 构建**默认开 R8**，
            //    而 R8 会把 ML Kit 内部依赖的组件/泛型签名裁掉 → 端上识别在**release 包里**
            //    必抛 `NullPointerException: … Object.getClass() on a null object reference`
            //    （同一张图在 debug 包里识别正常，30 行 / 375 ms）。
            //    这里先关掉压缩/混淆（与 debug 行为一致，最稳）；
            //    将来要瘦身，改成保留 ML Kit 的 keep 规则再测，别直接开回来。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // F8.1 截图记账：ML Kit 中文文字识别。
    // ⚠️ 这是 **bundled** 变体 —— 模型随 APK（约几 MB/ABI），**不做运行时下载**，
    //    也不需要 Google Play 服务（国产 ROM / 无 GMS 设备同样可用）。
    //    因此 release 包**仍然不需要 `INTERNET` 权限**，「不联网」这条卖点保持不变。
    // 数字 / ¥ / 英文商户名由同一个中文模型识别，不必再引 latency 模型。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

flutter {
    source = "../.."
}
