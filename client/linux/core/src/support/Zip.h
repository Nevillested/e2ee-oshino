#pragma once

// Минимальное чтение ZIP (центральный каталог, методы stored и deflate через
// zlib) — пак стикеров приходит одним архивом.

#include <QByteArray>
#include <QString>
#include <functional>

namespace osh {

/// Перебрать записи архива [path]; [onEntry](имя, данные) — для файлов не больше [maxEntryBytes].
/// false — архив не прочитан.
bool forEachZipEntry(const QString &path, qint64 maxEntryBytes, const std::function<void(const QString &, const QByteArray &)> &onEntry);

} // namespace osh
