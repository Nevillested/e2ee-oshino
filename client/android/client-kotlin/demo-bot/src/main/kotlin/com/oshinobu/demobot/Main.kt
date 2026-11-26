package com.oshinobu.demobot

import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.ApiConfig
import com.oshinobu.core.service.RouterHost
import com.oshinobu.core.service.RtcEngine
import com.oshinobu.core.storage.AppDirs
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
import java.io.File
import java.security.SecureRandom
import java.time.Instant
import kotlin.system.exitProcess

/*
 * Бот-собеседник для проверяющих магазинов приложений.
 *
 *   demo-bot register --login demo --invite 123456 [--greet iosacc,testandroid]
 *       регистрирует аккаунт бота (пароль — случайный), настраивает TOTP и
 *       сохраняет всё в <data>/bot.json (права 600);
 *   demo-bot run
 *       работает, пока не остановят (systemd).
 *
 * Общие параметры: --data <каталог> (по умолчанию ./data), --server <url>
 * (по умолчанию https://ee2e.oshino.space).
 */
fun main(args: Array<String>) {
    val command = args.firstOrNull() ?: usage()
    val opts = args.drop(1).chunked(2).associate { (k, v) -> k.removePrefix("--") to v }
    val dataDir = File(opts["data"] ?: "data").absoluteFile
    val config = ApiConfig(opts["server"] ?: ApiConfig().baseUrl)
    when (command) {
        "register" -> runBlocking { register(dataDir, config, opts["login"] ?: usage(), opts["invite"] ?: usage(), greet(opts)) }
        "run" -> runBlocking { run(dataDir, config) }
        else -> usage()
    }
}

private fun greet(opts: Map<String, String>) = opts["greet"]?.split(',')?.map(String::trim)?.filter(String::isNotEmpty).orEmpty()

private fun usage(): Nothing {
    System.err.println("usage: demo-bot register --login <login> --invite <code> [--greet a,b] | run   [--data dir] [--server url]")
    exitProcess(2)
}

private fun log(message: String) = println("${Instant.now()} $message")

private fun configFile(dataDir: File) = File(dataDir, "bot.json")

private suspend fun register(dataDir: File, config: ApiConfig, login: String, invite: String, greetLogins: List<String>) {
    val file = configFile(dataDir)
    check(!file.exists()) { "${file.path} уже есть — бот уже зарегистрирован" }
    val api = ApiClient(config)
    val password = randomPassword()
    val secret = Totp.secretFromUrl(api.register(login, password, invite))
    api.verifyTotp(login, Totp.code(secret))
    dataDir.mkdirs()
    val json = JsonObject(
        mapOf(
            "login" to JsonPrimitive(login),
            "password" to JsonPrimitive(password),
            "totp_secret" to JsonPrimitive(secret),
            "greet_logins" to JsonArray(greetLogins.map(::JsonPrimitive)),
        ),
    )
    file.writeText(json.toString())
    restrict(file)
    log("registered $login, credentials saved to ${file.path}")
}

/** Пароль под правила сервера: длинный, с буквами обоих регистров, цифрой и знаком. */
private fun randomPassword(): String {
    val random = SecureRandom()
    val pool = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    val body = (1..20).map { pool[random.nextInt(pool.length)] }.joinToString("")
    return "Aa1!$body"
}

private fun readConfig(dataDir: File): BotConfig {
    val o = Json.parseToJsonElement(configFile(dataDir).readText()).jsonObject
    return BotConfig(
        login = o.getValue("login").jsonPrimitive.content,
        password = o.getValue("password").jsonPrimitive.content,
        totpSecret = o.getValue("totp_secret").jsonPrimitive.content,
        greetLogins = o["greet_logins"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty(),
    )
}

private suspend fun run(dataDir: File, config: ApiConfig) {
    val botConfig = readConfig(dataDir)
    val dirs = AppDirs(File(dataDir, "documents"), File(dataDir, "support"), File(dataDir, "temp")).also {
        it.documents.mkdirs()
        it.support.mkdirs()
        it.temp.mkdirs()
    }
    val core = OshinobuCore(
        secure = FileSecureStore(File(dataDir, "secure.json")),
        prefs = FilePrefs(File(dataDir, "prefs.json")),
        dirs = dirs,
        routerHost = HeadlessHost,
        rtcEngine = NoRtc,
        config = config,
    )
    log("demo bot starting as ${botConfig.login}, greeting ${botConfig.greetLogins}")
    DemoBot(core, botConfig, ::log).run()
}

/** Экрана и звуков у бота нет. */
private object HeadlessHost : RouterHost {
    override val openChatPeerLogin: String? = null
    override val isAppInForeground = true
    override fun playMessageSound() = Unit
    override fun showBackgroundMessageNotification() = Unit
}

/** WebRTC у бота нет: звонки он только отклоняет (сессия до ответа не создаётся). */
private val NoRtc = RtcEngine { _, _ -> error("demo bot does not take calls") }
