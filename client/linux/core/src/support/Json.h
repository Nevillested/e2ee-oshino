#pragma once

// Мелочи поверх QJson: печать чисел так же, как Kotlin (целое — без дробной
// части), компактный JSON и чтение необязательных полей.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>
#include <optional>
#include <stdexcept>

namespace osh::json {

/// Число как в JSON: целое — без дробной части (64-битные целые точно).
inline QString numberText(const QJsonValue &v) {
    const double d = v.toDouble();
    const qint64 i = v.toInteger();
    if (double(i) == d) return QString::number(i);
    return QString::number(d, 'g', 17);
}

inline QString compact(const QJsonValue &v) {
    if (v.isObject()) return QString::fromUtf8(QJsonDocument(v.toObject()).toJson(QJsonDocument::Compact));
    if (v.isArray()) return QString::fromUtf8(QJsonDocument(v.toArray()).toJson(QJsonDocument::Compact));
    if (v.isString()) return v.toString();
    if (v.isDouble()) return numberText(v);
    if (v.isBool()) return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    return QStringLiteral("null");
}

inline QString compact(const QJsonObject &o) { return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)); }

/// Разбор JSON-объекта из строки; не объект — std::runtime_error.
inline QJsonObject parseObject(const QByteArray &raw) {
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) throw std::runtime_error("ожидался JSON-объект");
    return doc.object();
}

inline QJsonObject parseObject(const QString &raw) { return parseObject(raw.toUtf8()); }

/// Строковое поле или nullopt (нет поля / null / не строка).
inline std::optional<QString> optString(const QJsonObject &o, QLatin1String name) {
    const QJsonValue v = o.value(name);
    if (!v.isString()) return std::nullopt;
    return v.toString();
}

/// Обязательное строковое поле; нет — std::runtime_error.
inline QString string(const QJsonObject &o, QLatin1String name) {
    const QJsonValue v = o.value(name);
    if (!v.isString()) throw std::runtime_error("нет строкового поля " + std::string(name.data(), size_t(name.size())));
    return v.toString();
}

inline std::optional<QString> optString(const QJsonObject &o, const char *name) { return optString(o, QLatin1String(name)); }
inline QString string(const QJsonObject &o, const char *name) { return string(o, QLatin1String(name)); }

/// Строка или JSON null.
inline QJsonValue nullable(const std::optional<QString> &s) { return s ? QJsonValue(*s) : QJsonValue(QJsonValue::Null); }

} // namespace osh::json
