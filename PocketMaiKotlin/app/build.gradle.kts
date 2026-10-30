import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val signingNames = listOf("PMAI_ANDROID_KEYSTORE", "PMAI_ANDROID_KEY_ALIAS",
    "PMAI_ANDROID_STORE_PASSWORD", "PMAI_ANDROID_KEY_PASSWORD")
val signingValues = signingNames.associateWith { System.getenv(it).orEmpty() }
val customSigning = signingValues.values.any { it.isNotEmpty() }
if (customSigning) require(signingValues.values.all { it.isNotEmpty() }) {
    "Release signing requires all four PMAI_ANDROID_* signing variables (see README.md)."
}
val iconDir = layout.buildDirectory.dir("generated/app-icon")
val syncIcon by tasks.registering(Copy::class) {
    from(rootProject.file("../PocketMai/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
    into(iconDir.map { it.dir("drawable-nodpi") })
    rename { "ic_launcher.png" }
}
val generateWebSdk by tasks.registering(Exec::class) {
    workingDir(rootDir)
    commandLine("python3", "scripts/stage-webxdc.py")
    inputs.file(rootProject.file("../MaiCore/Sources/MaiCore/WebXDCPocketMaiBridge.swift"))
    inputs.file(rootProject.file("scripts/stage-webxdc.py"))
    outputs.dir(layout.buildDirectory.dir("generated/webxdc"))
}
android {
    namespace = "org.mai.kotlin"
    compileSdk = 36
    defaultConfig {
        applicationId = "org.mai.pocketmai.kotlin"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += (System.getenv("ANDROID_ABIS") ?: "arm64-v8a").split(" ").filter { it.isNotBlank() } }
    }
    signingConfigs {
        if (customSigning) create("releaseKey") {
            storeFile = rootProject.file(signingValues.getValue("PMAI_ANDROID_KEYSTORE"))
            keyAlias = signingValues.getValue("PMAI_ANDROID_KEY_ALIAS")
            storePassword = signingValues.getValue("PMAI_ANDROID_STORE_PASSWORD")
            keyPassword = signingValues.getValue("PMAI_ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName(if (customSigning) "releaseKey" else "debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    buildFeatures { compose = true }
    sourceSets["main"].res.srcDir(iconDir)
    sourceSets["main"].assets.srcDirs("src/main/assets", "build/generated/webxdc")
    val nativeNdk = System.getenv("ANDROID_NDK_HOME")?.let(::file)
        ?: rootProject.file(".deps/android-ndk-r30").takeIf { it.isDirectory }
    nativeNdk?.let {
        ndkPath = it.absolutePath
        ndkVersion = Properties().apply { it.resolve("source.properties").inputStream().use { stream -> load(stream) } }.getProperty("Pkg.Revision")
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
tasks.named("preBuild") { dependsOn(syncIcon, generateWebSdk) }
dependencies {
    implementation(project(":bridge"))
    implementation(platform("androidx.compose:compose-bom:2026.02.01"))
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material3:material3-adaptive-navigation-suite")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    implementation("org.rustls:rustls-platform-verifier:0.2.0")
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
