package api

import (
	"errors"
	"log"
	"net/http"
	"server/internal/db"

	"os"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

// то же значение, что и клиентский _maxAttachmentSizeBytes
// (chat_screen.dart) и nginx client_max_body_size — здесь нужен НЕ
// столько для клиента (он и так режет раньше), сколько подстраховкой на
// случай, если запрос когда-нибудь придёт в обход текущего nginx (см.
// обсуждение resilience/relay) — без этого сервер молча лил бы файл любого
// размера прямо в MinIO.
const maxUploadSizeBytes = 500 * 1024 * 1024 // 500 МБ

func NewUploadMediaHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var Session, ErrTokCheck = CheckToken(w, r, queries)
		//var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxUploadSizeBytes)

		//Нам надо сделать в базе запись о загружаемом файле. Для этого:
		//получаем файл из запроса
		file, header, err := r.FormFile("file")

		//проверяем есть ли ошибка при получении файла из запроса
		if err != nil {
			var maxBytesErr *http.MaxBytesError
			if errors.As(err, &maxBytesErr) {
				http.Error(w, "Файл превышает максимально допустимый размер (500 МБ)", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, "ошибка получения файла из запроса", http.StatusBadRequest)
			return
		}

		//отложенно закрываем файл после того, как функция завершит свою работу
		defer file.Close()

		//получаем ID получателя файла из запроса
		var recipientIDStr string = r.FormValue("recipient_account_id")

		//конвертируем ID получателя файла из string в необходимый постгре UUID
		var recipientID pgtype.UUID
		ScanUuidErr := recipientID.Scan(recipientIDStr)

		//проверяем на ошибки
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации recipient_account_id", http.StatusBadRequest)
			return
		}

		//переменная для передаваемых параметров в бд
		var NewSaveMediaFileParams db.SaveMediaFileParams

		//присваиваем значения в переменную
		NewSaveMediaFileParams.UploadedByAccountID = Session.AccountID //от кого
		NewSaveMediaFileParams.ObjectKey = header.Filename             //название файла
		NewSaveMediaFileParams.SizeBytes = header.Size                 //размер файла
		NewSaveMediaFileParams.RecipientAccountID = recipientID        //кому

		//делаем вставку в бд о загруженном файле, чтобы отдать MinIO ключ, по которому потом можно файл забрать (ключ сгенерирует база)
		var MediaFile, SqlErr = queries.SaveMediaFile(r.Context(), NewSaveMediaFileParams)

		//проверяем есть ли ошибка при вставке в бд
		if SqlErr != nil {
			http.Error(w, "ошибка загрузки файла", http.StatusInternalServerError)
			return
		}

		//получаем ID файла, которые дала база, чтобы вернуть пользователю
		var MediaFileID = MediaFile.ID.String()

		//загрузка файла в MinIO
		info, err := minioClient.PutObject(r.Context(), os.Getenv("MINIO_BUCKET"), MediaFileID, file, header.Size, minio.PutObjectOptions{})

		//проверяем есть ли ошибка при загрузке файла в MinIO
		if err != nil {

			//сообщаем клиенту, что произошла ошибка при загрузке файла в MinIO
			http.Error(w, "ошибка загрузки файла в MinIO", http.StatusInternalServerError)

			//удаляем запись о файле из базы, если произошла ошибка при загрузке в MinIO, чтобы не оставлять "мусор" в базе
			var SqlErrDel = queries.DeleteMediaFile(r.Context(), MediaFile.ID)

			//проверяем на ошибки
			if SqlErrDel != nil {
				log.Printf("Файл в MinIO не загружен, ошибка удаления записи из бд: %s", SqlErrDel)
			} else {
				log.Printf("Файл в MinIO не загружен, запись из бд удалена: %v", MediaFileID)
			}

			return
		}

		log.Printf("Файл успешно загружен в MinIO: %s, размер: %d байт", info.Key, info.Size)

		//возвращаем пользователю ID файла, который дала база
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(MediaFileID))

		/*
			проверка
			curl -i -X POST http://127.0.0.1:8080/upload-media \
			  -H "Authorization: Bearer Ji3bJf3ODyUxumht2uvRuwSEnIbe7wZL8foFJhcxaCg=" \
			  -F "file=@/home/luck/wow_2_32x32x32.png" \
			  -F "recipient_account_id=7df2d9c9-08d3-40ca-a590-61ff8f002848"
		*/
	}

}
