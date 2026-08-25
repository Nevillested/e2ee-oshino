package api

import (
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"server/internal/db"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

func NewGetMediaHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {

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

		//забираем файл из MinIO по ключу, который вернула база
		object, err := minioClient.GetObject(r.Context(), os.Getenv("MINIO_BUCKET"), FileId, minio.GetObjectOptions{})

		//проверяем есть ли ошибка при получении файла из MinIO
		if err != nil {
			http.Error(w, "Ошибка получения файла", http.StatusInternalServerError)
			return
		}

		//заранее закываем соединение с MinIO после того, как функция завершит свою работу
		defer object.Close()

		//явно указываем размер тела ответа — без этого net/http сам переключается
		//на chunked-энкодинг (Content-Length неизвестен), и клиент (dio,
		//onReceiveProgress) физически не может посчитать процент скачивания —
		//total всегда приходит -1. mediaFile.SizeBytes — тот же самый размер,
		//что был передан в PutObject при загрузке (см. upload_media.go), так что
		//он точно совпадает с реальным числом байт, которое отдаст io.Copy.
		w.Header().Set("Content-Length", strconv.FormatInt(mediaFile.SizeBytes, 10))

		//отправляем файл клиенту
		io.Copy(w, object)

	}

}

/*

func (q *Queries) GetMediaFile(ctx context.Context, id pgtype.UUID) (MediaFile, error) {
	row := q.db.QueryRow(ctx, getMediaFile, id)
	var i MediaFile
	err := row.Scan(
		&i.ID,
		&i.UploadedByAccountID,
		&i.ObjectKey,
		&i.SizeBytes,
		&i.CreatedAt,
	)
	return i, err
}
*/
