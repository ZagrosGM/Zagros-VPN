allprojects {
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepository {
                maven {
                    name = "zagrosPinnedThirdParty"
                    // Anchor to the ROOT project: a bare relative uri() is
                    // resolved per-project, so subprojects (android/app/,
                    // the tunnel plugin) would land one level too deep in
                    // apps/third_party instead of the repo-root checkout.
                    url = uri(rootProject.file("../../../third_party/maven"))
                }
            }
            filter {
                includeGroup("ai.zagros.thirdparty")
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
