import java.util.Properties

plugins { id("com.android.library") }

android {
    namespace = "org.mai.kotlin.bridge"
    compileSdk = 36
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].java.srcDirs("build/generated/java")
    sourceSets["main"].resources.srcDir("../.build/checkouts/swift-java/SwiftKitCore/src/main/resources")
    sourceSets["debug"].jniLibs.srcDir("build/generated/native/debug")
    sourceSets["release"].jniLibs.srcDir("build/generated/native/release")
    val nativeNdk = System.getenv("ANDROID_NDK_HOME")?.let(::file)
        ?: rootProject.file(".deps/android-ndk-r30").takeIf { it.isDirectory }
    nativeNdk?.let {
        ndkPath = it.absolutePath
        ndkVersion = Properties().apply { it.resolve("source.properties").inputStream().use { stream -> load(stream) } }.getProperty("Pkg.Revision")
    }
}
androidComponents.onVariants { variant ->
    val name = variant.name.replaceFirstChar { it.uppercase() }
    val prepareSwift = tasks.register<Exec>("prepare${name}Swift") {
        workingDir(rootDir)
        environment("JAVA_HOME", System.getProperty("java.home"))
        environment("CONFIGURATION", variant.buildType ?: "debug")
        commandLine("bash", "scripts/build-native.sh")
        // SwiftPM owns incremental compilation and binding generation.
    }
    // JExtract's callback phase already compiles SwiftKitCore with the JDK.
    // Package those classes: compiling its desktop-only JFR annotations against
    // Android's boot classpath would fail even though Android never uses them.
    val runtimeJar = tasks.register<Jar>("package${name}SwiftRuntime") {
        dependsOn(prepareSwift)
        from(rootProject.file(".build/checkouts/swift-java/SwiftKitCore/build/classes/java/main"))
        archiveFileName.set("swiftkit-$name.jar")
        destinationDirectory.set(layout.buildDirectory.dir("generated/runtime"))
    }
    dependencies.add("${variant.name}Api", files(runtimeJar.flatMap { it.archiveFile }).builtBy(runtimeJar))
    tasks.matching { it.name == "pre${name}Build" }.configureEach { dependsOn(prepareSwift) }
}
