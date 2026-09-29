pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.library") version "9.1.0" apply false
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        exclusiveContent {
            forRepository {
                maven {
                    url = uri("../../../third_party/maven")
                    metadataSources { mavenPom(); artifact() }
                }
            }
            filter { includeGroup("ai.zagros.thirdparty") }
        }
        exclusiveContent {
            forRepository {
                maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
            }
            filter { includeGroup("io.flutter") }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "tunnel_interface"
