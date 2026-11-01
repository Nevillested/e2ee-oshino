#pragma once

// Журнал (как FileLogger на Android): строки с временем — в файл
// <data>/log.txt (ограничен по размеру) и в stderr. Отсюда же берётся хвост
// для автоотчётов в feedback (auto_crash, call_problem).

#include <QString>

namespace osh {

void log(const QString &line);
void logError(const QString &line);

/// Файл журнала (задать один раз при старте; пусто — только stderr).
void setLogFile(const QString &path);
QString logFilePath();
/// Последние [maxBytes] журнала — для отчёта.
QString logTail(qint64 maxBytes = 64 * 1024);

} // namespace osh
