import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing from a LOCAL, git-ignored keystore.properties (never committed —
// public repo). Absent (fresh clone / CI) → release falls back to debug signing so
// the build still works; present → release is signed with the real key.
val keystorePropsFile = rootProject.file("keystore.properties")
val hasKeystore = keystorePropsFile.exists()
val keystoreProps = Properties().apply {
    if (hasKeystore) keystorePropsFile.inputStream().use { load(it) }
}

android {
    namespace = "dev.universaltmux.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.universaltmux.android"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    testOptions { unitTests.isIncludeAndroidResources = true }
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/sharedJournalAssets"))
    sourceSets["test"].resources.srcDir(rootProject.file("../../testdata/workspace"))
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../../testdata/workspace"))
    testBuildType = if (providers.gradleProperty("parityQA").orNull == "true") "qa" else "release"

    signingConfigs {
        if (hasKeystore) create("release") {
            storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
            storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias")
            keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false // R8 off: the gomobile JNI classes need keep-rules; not worth the risk
            signingConfig = signingConfigs.getByName(if (hasKeystore) "release" else "debug")
        }
        create("qa") {
            initWith(getByName("release"))
            applicationIdSuffix = ".qa"
            isDebuggable = true
            matchingFallbacks += "release"
        }
    }
    sourceSets["qa"].assets.srcDir(rootProject.file("../../testdata/workspace"))
    packaging { resources { excludes += setOf("/META-INF/{AL2.0,LGPL2.1}") } }
}

val syncSharedJournalAssets by tasks.registering(Sync::class) {
    from(rootProject.file("../macos/Resources")) { include("ledger/**", "wrapped/**") }
    into(layout.buildDirectory.dir("generated/sharedJournalAssets"))
}
tasks.named("preBuild").configure { dependsOn(syncSharedJournalAssets) }

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.annotation:annotation:1.8.2")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")

    implementation(platform("androidx.compose:compose-bom:2024.09.03"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")

    // Embedded tsnet core (gomobile .aar): joins the tailnet for native peer
    // discovery. Rebuild with: scripts/build-core.sh
    implementation(files("libs/uttsnet.aar"))
}
