package com.oshinobu.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull

// Чтение полей JSON-объекта так, как это делает Dart-код Flutter-клиента
// (`j['x'] as String?`): отсутствующее поле и null — одно и то же.

private fun JsonObject.primitive(name: String): JsonPrimitive? = (this[name] as? JsonPrimitive)?.takeUnless { it is JsonNull }

fun JsonObject.optString(name: String): String? = primitive(name)?.contentOrNull

fun JsonObject.optLong(name: String): Long? = primitive(name)?.longOrNull

fun JsonObject.optInt(name: String): Int? = primitive(name)?.intOrNull

fun JsonObject.optBool(name: String): Boolean? = primitive(name)?.booleanOrNull

fun JsonObject.string(name: String): String = optString(name) ?: throw IllegalArgumentException("в JSON нет поля $name")

fun JsonObject.optObjects(name: String): List<JsonObject> = (this[name] as? JsonArray)?.map { it.jsonObject }.orEmpty()

fun JsonObject.optStrings(name: String): List<String> =
    (this[name] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
