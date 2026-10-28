import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// aliyun_push 1.2.0 pins API 31 although its resolved AndroidX libraries need
// newer APIs. Use the app's SDK without changing or forking the cached plugin.
val pushProject = project(":aliyun_push")
pushProject.pluginManager.withPlugin("com.android.library") {
    pushProject.extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
        finalizeDsl { library -> library.compileSdk = flutter.compileSdkVersion }
    }
}

val pushProperties = providers.gradleProperty("dogcodesPushProperties").orNull?.let { file(it) }
    ?: rootProject.file("../private/android-push.properties")
val sourceManifest = file("src/main/AndroidManifest.xml")
val pushManifest = layout.buildDirectory.file("generated/push/AndroidManifest.xml")
val pushResources = layout.buildDirectory.dir("generated/push/res")
val generatePushManifest by tasks.registering {
    inputs.file(sourceManifest)
    inputs.files(provider { if (pushProperties.exists()) listOf(pushProperties) else emptyList<File>() })
    outputs.file(pushManifest)
    outputs.dir(pushResources)
    doLast {
        val settings = Properties().apply {
            if (pushProperties.exists()) pushProperties.inputStream().use { load(it) }
        }
        val groups = listOf(
            listOf("com.huawei.hms.client.appid"),
            listOf("com.hihonor.push.app_id"),
            listOf("com.vivo.push.api_key", "com.vivo.push.app_id"),
            listOf("com.oppo.push.key", "com.oppo.push.secret"),
            listOf("com.xiaomi.push.id", "com.xiaomi.push.key"),
            listOf("com.meizu.push.id", "com.meizu.push.key"),
            listOf("dogcodes.push.fcm.sender_id", "dogcodes.push.fcm.app_id", "dogcodes.push.fcm.project_id", "dogcodes.push.fcm.api_key"),
        )
        val metadata = StringBuilder()
        for (group in groups) {
            val values = group.map { settings.getProperty(it)?.trim().orEmpty() }
            if (values.all { it.isEmpty() }) continue
            require(values.none { it.isEmpty() }) { "Incomplete push channel configuration: ${group.joinToString()}" }
            for ((key, value) in group.zip(values)) {
                val escaped = value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")
                metadata.append("<meta-data android:name=\"$key\" android:value=\"$escaped\" />\n")
            }
        }
        // Resource-based Firebase configuration also initializes cold/background
        // deliveries; token auto-init remains disabled until the user enables push.
        val firebaseNames = mapOf("sender_id" to "gcm_defaultSenderId", "app_id" to "google_app_id", "project_id" to "project_id", "api_key" to "google_api_key")
        val resources = StringBuilder("<resources>\n")
        for ((field, name) in firebaseNames) {
            val value = settings.getProperty("dogcodes.push.fcm.$field")?.trim().orEmpty().removePrefix("id=")
            if (value.isNotEmpty()) {
                val escaped = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "\\'")
                resources.append("<string name=\"$name\" translatable=\"false\">$escaped</string>\n")
            }
        }
        resources.append("</resources>")
        val resourceFile = pushResources.get().file("values/push.xml").asFile
        resourceFile.parentFile.mkdirs()
        resourceFile.writeText(resources.toString())
        val output = pushManifest.get().asFile
        output.parentFile.mkdirs()
        output.writeText(sourceManifest.readText().replace("</application>", "$metadata</application>"))
    }
}

android {
    sourceSets.getByName("main").manifest.srcFile(pushManifest)
    sourceSets.getByName("main").res.srcDir(pushResources.get().asFile)
    namespace = "codes.dog.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "codes.dog.mobile"
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
    }

    buildTypes {
        release {
            // Release credentials are configured privately by the maintainer.
            signingConfig = null
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

val buildEndpoint by tasks.registering(Exec::class) {
    workingDir = rootProject.projectDir.parentFile
    commandLine("python3", "tool/build_endpoint.py", "android")
}
tasks.named("preBuild") { dependsOn(buildEndpoint, generatePushManifest) }

// Own these direct SDKs explicitly instead of relying on EMAS's transitive versions.
dependencies {
    implementation("com.google.firebase:firebase-messaging:24.1.2")
    implementation("com.huawei.hms:push:6.13.0.300")
}
