plugins {
    kotlin("jvm")
    application
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.13.4")
}

application {
    mainClass.set("com.oshinobu.demobot.MainKt")
    // сервер маленький (1 ГБ ОЗУ на всё) — бот держится в узкой куче
    applicationDefaultJvmArgs = listOf("-Xmx128m", "-XX:+UseSerialGC")
}

tasks.test {
    useJUnitPlatform()
}
