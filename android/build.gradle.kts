allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Force NDK version on plugins to match project version
subprojects {
    afterEvaluate {
        if (extensions.findByName("android") != null) {
            val androidExt = extensions.getByName("android")
            if (androidExt is com.android.build.gradle.BaseExtension) {
                androidExt.ndkVersion = "26.1.10909125"
                if (androidExt.compileSdkVersion == "android-33" ||
                    androidExt.compileSdkVersion == "android-27" || // in case some use older
                    (androidExt.compileSdkVersion?.contains("android-36") == true)) {
                    androidExt.compileSdkVersion = "android-34"
                }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
