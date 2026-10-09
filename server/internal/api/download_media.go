package api

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"server/internal/db"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

func NewGetMediaHandler(queries *db.Queries, minioClient *minio.Client, staging *MediaStaging) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//достаем FileId из входящей http строки - это ID файла, КОТОРЫЙ хотят скачать
		var FileId string = r.PathValue("id")

		//конвертируем FileId из string в необходимый постгре UUID
		var FileIdUUID pgtype.UUID

		ScanUuidErr := FileIdUUID.Scan(FileId)

		//проверяем на ошибки
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации FileId", http.StatusBadRequest)
			return
		}

		//достаем из бд информацию о файле по FileId
		var mediaFile, sqlErr = queries.GetMediaFile(r.Context(), FileIdUUID)

		//проверяем есть ли ошибка при получении информации о файле по FileId
		if sqlErr != nil {

			//проверяем что за ошибка - при выполнении запроса не оказалось строк или у нас с базой проблема
			if errors.Is(sqlErr, pgx.ErrNoRows) {
				http.Error(w, "Такого файла нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска файла", http.StatusInternalServerError)
			}
			return
		}

		//проверяем права доступа к файлу. Файл может скачать только тот, кто его загрузил и тот, кому он предназначен
		var current_acc = Session.AccountID

		//смотрим, кто был загрузчиком файла
		var AccSRC = mediaFile.UploadedByAccountID

		//смотрим, кто был получателем файла
		var AccDST = mediaFile.RecipientAccountID

		//проверяем доступы к файлу. Если текущий человек не является ни тем, кто загрузил файл, ни тем, кому он предназначен, то запрещаем доступ
		if current_acc != AccSRC && current_acc != AccDST {
			http.Error(w, "Нет прав доступа к файлу", http.StatusForbidden)
			return
		}

		totalSize := mediaFile.SizeBytes

		// HEAD — клиент спрашивает только полный размер зашифрованного
		// файла (нужен MediaDownloadManager, когда локальный хвост уже есть,
		// а запись о его полном размере потерялась). Не трогаем MinIO
		// вообще — размер и так лежит в БД, а тянуть ради HEAD весь объект
		// из Японии в Москву было бы абсурдом. Go ServeMux отдаёт этот же
		// хендлер и на HEAD (паттерн "GET ..." матчит HEAD).
		if r.Method == http.MethodHead {
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Header().Set("Content-Length", strconv.FormatInt(totalSize, 10))
			w.WriteHeader(http.StatusOK)
			return
		}

		// Докачка с места обрыва (см. MediaDownloadManager на клиенте):
		// поддерживаем ОДИН байтовый диапазон "bytes=START-" / "bytes=START-END".
		// Range разбираем сами и передаём его в MinIO через SetRange —
		// так сетевое хранилище (оно физически в Японии, сервер в Москве)
		// тянет и отдаёт РОВНО запрошенные байты, а не весь файл; это же
		// избавляет от лишнего round-trip на Seek(0, End), который сделал
		// бы http.ServeContent ради вычисления размера — размер и так уже
		// известен из mediaFile.SizeBytes (тот же, что был передан в
		// PutObject при загрузке).
		start, end := int64(0), totalSize-1
		isRange := false
		if rangeHeader := r.Header.Get("Range"); rangeHeader != "" {
			s, e, ok := parseSingleByteRange(rangeHeader, totalSize)
			if !ok {
				w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", totalSize))
				http.Error(w, "диапазон вне допустимого", http.StatusRequestedRangeNotSatisfiable)
				return
			}
			start, end, isRange = s, e, true
		}

		contentLen := end - start + 1

		// Файл ещё в горячем буфере на диске сервера (см. media_staging.go) —
		// отдаём оттуда, NAS не нужен вовсе. Если локальной копии уже нет
		// (архиватор только что перенёс её в MinIO) — идём в архив ниже.
		if mediaFile.Storage == "local" {
			f, openErr := staging.Open(FileId)
			if openErr == nil {
				defer f.Close()
				writeMediaHeaders(w, contentLen, isRange, start, end, totalSize)
				n, copyErr := io.Copy(w, io.NewSectionReader(f, start, contentLen))
				// Получатель забрал файл до последнего байта — у обоих он
				// теперь есть, можно переносить в архив. Начало файла он
				// мог скачать раньше (докачка по Range), поэтому смотрим
				// именно на хвост.
				if copyErr == nil && n == contentLen && end == totalSize-1 && current_acc == AccDST {
					markMediaDelivered(queries, FileIdUUID)
				}
				return
			}
			if !errors.Is(openErr, os.ErrNotExist) {
				log.Printf("media staging: не удалось открыть %s из буфера: %v — пробуем архив", FileId, openErr)
			}
		}

		opts := minio.GetObjectOptions{}
		if isRange {
			if err := opts.SetRange(start, end); err != nil {
				http.Error(w, "некорректный диапазон", http.StatusBadRequest)
				return
			}
		}

		//забираем файл (или его кусок) из MinIO по ключу, который вернула база
		object, err := minioClient.GetObject(r.Context(), os.Getenv("MINIO_BUCKET"), FileId, opts)

		//проверяем есть ли ошибка при получении файла из MinIO
		if err != nil {
			http.Error(w, "Ошибка получения файла", http.StatusInternalServerError)
			return
		}

		//заранее закываем соединение с MinIO после того, как функция завершит свою работу
		defer object.Close()

		writeMediaHeaders(w, contentLen, isRange, start, end, totalSize)

		//отправляем файл (или запрошенный кусок) клиенту
		io.Copy(w, object)
	}
}

func writeMediaHeaders(w http.ResponseWriter, contentLen int64, isRange bool, start, end, totalSize int64) {
	// Accept-Ranges — сигнал клиенту, что докачку этот эндпоинт умеет.
	w.Header().Set("Accept-Ranges", "bytes")
	// Шифротекст — сниффить тип по содержимому бессмысленно, ставим явно.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(contentLen, 10))
	if isRange {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, totalSize))
		w.WriteHeader(http.StatusPartialContent)
	}
}

// markMediaDelivered — отдельный контекст: запрос к этому моменту уже
// отдан целиком, и его контекст может быть отменён в любую секунду.
func markMediaDelivered(queries *db.Queries, id pgtype.UUID) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := queries.MarkMediaDelivered(ctx, id); err != nil {
		log.Printf("media staging: не удалось отметить доставку %s: %v", id.String(), err)
	}
}

// ---- POST /media/{id}/received ----
// Клиент получателя подтверждает, что скачал И расшифровал файл. Дублирует
// серверную отметку по последнему байту (см. выше) — точнее её: засчитывает
// только реально расшифрованный файл. Повторный вызов безвреден.
func NewMediaReceivedHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, errTok := CheckToken(w, r, queries)
		if errTok != nil {
			log.Printf("media received: ошибка токена: %v", errTok)
			return
		}
		var fileUUID pgtype.UUID
		if err := fileUUID.Scan(r.PathValue("id")); err != nil {
			http.Error(w, "Ошибка конвертации FileId", http.StatusBadRequest)
			return
		}
		mediaFile, err := queries.GetMediaFile(r.Context(), fileUUID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.Error(w, "Такого файла нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска файла", http.StatusInternalServerError)
			}
			return
		}
		// подтверждать может только получатель
		if session.AccountID != mediaFile.RecipientAccountID {
			http.Error(w, "Нет прав доступа к файлу", http.StatusForbidden)
			return
		}
		markMediaDelivered(queries, fileUUID)
		w.WriteHeader(http.StatusNoContent)
	}
}

// parseSingleByteRange разбирает заголовок Range вида "bytes=START-" или
// "bytes=START-END" (только один диапазон — мультидиапазонные запросы
// клиент не шлёт). Возвращает нормализованные start/end (включительно) и
// ok=false, если заголовок не распарсился или диапазон вне [0, total).
func parseSingleByteRange(header string, total int64) (start, end int64, ok bool) {
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if strings.Contains(spec, ",") {
		return 0, 0, false
	}
	dash := strings.IndexByte(spec, '-')
	if dash < 0 {
		return 0, 0, false
	}
	startStr := strings.TrimSpace(spec[:dash])
	endStr := strings.TrimSpace(spec[dash+1:])
	if startStr == "" {
		// суффиксная форма "bytes=-N" (последние N байт) — клиент её не
		// использует, не поддерживаем.
		return 0, 0, false
	}
	s, err := strconv.ParseInt(startStr, 10, 64)
	if err != nil || s < 0 || s >= total {
		return 0, 0, false
	}
	e := total - 1
	if endStr != "" {
		parsed, err := strconv.ParseInt(endStr, 10, 64)
		if err != nil || parsed < s {
			return 0, 0, false
		}
		e = parsed
	}
	if e >= total {
		e = total - 1
	}
	return s, e, true
}
