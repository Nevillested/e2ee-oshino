package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"

	"server/internal/db"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

// Докачка больших файлов по кусочкам (multipart upload в MinIO).
//
// Сервер намеренно НЕ хранит своё собственное состояние загрузки (ни новой
// таблицы в БД, ни памяти процесса) — единственный источник правды о том,
// какие части уже долетели, это сам MinIO (ListObjectParts). Это значит:
//   - обрыв связи посреди докачки не требует никакой уборки на сервере —
//     недокачанный multipart-upload просто лежит в MinIO, пока клиент не
//     вернётся и не продолжит (или не вызовет /abort);
//   - рестарт сервера ничего не теряет — media_id и upload_id клиент хранит
//     у себя и присылает те же значения при возврате;
//   - строка в media_files создаётся ТОЛЬКО на успешном /complete — то есть
//     мусора от брошенных загрузок в БД в принципе не появляется (сам объект
//     в MinIO для незавершённых multipart-upload'ов чистит lifecycle-политика
//     бакета, это уже забота инфраструктуры, не этого кода).
//
// Размер части фиксирован и определяется сервером (клиент его не выбирает) —
// это одновременно и ограничивает число частей на файл (500 МБ / 8 МБ ≈ 63,
// далеко от лимита S3 в 10000 частей на объект), и держит каждую часть выше
// минимума S3/MinIO в 5 МБ (кроме, как обычно, последней части).
const chunkedUploadPartSizeBytes = 8 * 1024 * 1024 // 8 МБ

type chunkedUploadCore struct {
	core *minio.Core
}

func newChunkedUploadCore(minioClient *minio.Client) chunkedUploadCore {
	// Core — это просто Client, обёрнутый ради доступа к низкоуровневым
	// S3-примитивам (NewMultipartUpload/PutObjectPart/...) — вторая
	// хендшейка/подключение здесь не нужны, тот же клиент.
	return chunkedUploadCore{core: &minio.Core{Client: minioClient}}
}

// ---- POST /upload-media/init ----

type initChunkedUploadRequest struct {
	SizeBytes int64 `json:"size_bytes"`
}

type initChunkedUploadResponse struct {
	MediaID  string `json:"media_id"`
	UploadID string `json:"upload_id"`
	PartSize int64  `json:"part_size"`
}

func NewInitChunkedUploadHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	cu := newChunkedUploadCore(minioClient)

	return func(w http.ResponseWriter, r *http.Request) {
		_, errTokCheck := CheckToken(w, r, queries)
		if errTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", errTokCheck)
			return
		}

		var req initChunkedUploadRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
			http.Error(w, "ошибка чтения тела запроса", http.StatusBadRequest)
			return
		}

		if req.SizeBytes <= 0 {
			http.Error(w, "некорректный размер файла", http.StatusBadRequest)
			return
		}
		if req.SizeBytes > maxUploadSizeBytes {
			http.Error(w, "Файл превышает максимально допустимый размер (500 МБ)", http.StatusRequestEntityTooLarge)
			return
		}

		mediaID := uuid.NewString()

		uploadID, err := cu.core.NewMultipartUpload(r.Context(), os.Getenv("MINIO_BUCKET"), mediaID, minio.PutObjectOptions{})
		if err != nil {
			log.Printf("ошибка создания multipart-загрузки в MinIO: %v", err)
			http.Error(w, "ошибка создания загрузки", http.StatusInternalServerError)
			return
		}

		resp := initChunkedUploadResponse{
			MediaID:  mediaID,
			UploadID: uploadID,
			PartSize: chunkedUploadPartSizeBytes,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

// ---- PUT /upload-media/{media_id}/part/{part_number}?upload_id=... ----

func NewUploadChunkedPartHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	cu := newChunkedUploadCore(minioClient)

	return func(w http.ResponseWriter, r *http.Request) {
		_, errTokCheck := CheckToken(w, r, queries)
		if errTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", errTokCheck)
			return
		}

		mediaID := r.PathValue("media_id")
		uploadID := r.URL.Query().Get("upload_id")
		if mediaID == "" || uploadID == "" {
			http.Error(w, "не хватает media_id или upload_id", http.StatusBadRequest)
			return
		}

		partNumber, err := strconv.Atoi(r.PathValue("part_number"))
		if err != nil || partNumber < 1 {
			http.Error(w, "некорректный номер части", http.StatusBadRequest)
			return
		}

		// +1 МБ запаса — размер части определяет сервер (chunkedUploadPartSizeBytes),
		// но клиент может слегка ошибиться в последней части, режем только от
		// откровенно неадекватных тел запроса.
		r.Body = http.MaxBytesReader(w, r.Body, chunkedUploadPartSizeBytes+1024*1024)
		data, err := io.ReadAll(r.Body)
		if err != nil {
			var maxBytesErr *http.MaxBytesError
			if errors.As(err, &maxBytesErr) {
				http.Error(w, "часть файла превышает допустимый размер", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, "ошибка чтения части файла", http.StatusBadRequest)
			return
		}
		if len(data) == 0 {
			http.Error(w, "пустая часть файла", http.StatusBadRequest)
			return
		}

		_, err = cu.core.PutObjectPart(r.Context(), os.Getenv("MINIO_BUCKET"), mediaID, uploadID, partNumber,
			bytes.NewReader(data), int64(len(data)), minio.PutObjectPartOptions{})
		if err != nil {
			log.Printf("ошибка загрузки части %d файла %s в MinIO: %v", partNumber, mediaID, err)
			http.Error(w, "ошибка загрузки части файла", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

// ---- GET /upload-media/{media_id}/parts?upload_id=... ----

type uploadedPartInfo struct {
	PartNumber int   `json:"part_number"`
	Size       int64 `json:"size"`
}

func NewListChunkedPartsHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	cu := newChunkedUploadCore(minioClient)

	return func(w http.ResponseWriter, r *http.Request) {
		_, errTokCheck := CheckToken(w, r, queries)
		if errTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", errTokCheck)
			return
		}

		mediaID := r.PathValue("media_id")
		uploadID := r.URL.Query().Get("upload_id")
		if mediaID == "" || uploadID == "" {
			http.Error(w, "не хватает media_id или upload_id", http.StatusBadRequest)
			return
		}

		parts, err := listAllChunkedParts(r, cu, mediaID, uploadID)
		if err != nil {
			log.Printf("ошибка получения списка частей файла %s: %v", mediaID, err)
			http.Error(w, "ошибка получения списка частей", http.StatusInternalServerError)
			return
		}

		result := make([]uploadedPartInfo, 0, len(parts))
		for _, p := range parts {
			result = append(result, uploadedPartInfo{PartNumber: p.PartNumber, Size: p.Size})
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	}
}

// listAllChunkedParts вытягивает ВСЕ части (с пагинацией — ListObjectParts
// за один вызов может отдать не больше 1000 штук), отсортированные по
// номеру части — это же и требование S3 для CompleteMultipartUpload.
func listAllChunkedParts(r *http.Request, cu chunkedUploadCore, mediaID, uploadID string) ([]minio.ObjectPart, error) {
	bucket := os.Getenv("MINIO_BUCKET")
	var all []minio.ObjectPart
	marker := 0
	for {
		result, err := cu.core.ListObjectParts(r.Context(), bucket, mediaID, uploadID, marker, 1000)
		if err != nil {
			return nil, err
		}
		all = append(all, result.ObjectParts...)
		if !result.IsTruncated {
			break
		}
		marker = result.NextPartNumberMarker
	}
	sort.Slice(all, func(i, j int) bool { return all[i].PartNumber < all[j].PartNumber })
	return all, nil
}

// ---- POST /upload-media/{media_id}/complete?upload_id=... ----

type completeChunkedUploadRequest struct {
	RecipientAccountID string `json:"recipient_account_id"`
	FileName           string `json:"file_name"`
}

func NewCompleteChunkedUploadHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	cu := newChunkedUploadCore(minioClient)

	return func(w http.ResponseWriter, r *http.Request) {
		Session, errTokCheck := CheckToken(w, r, queries)
		if errTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", errTokCheck)
			return
		}

		mediaID := r.PathValue("media_id")
		uploadID := r.URL.Query().Get("upload_id")
		if mediaID == "" || uploadID == "" {
			http.Error(w, "не хватает media_id или upload_id", http.StatusBadRequest)
			return
		}

		var req completeChunkedUploadRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
			http.Error(w, "ошибка чтения тела запроса", http.StatusBadRequest)
			return
		}

		var recipientID pgtype.UUID
		if err := recipientID.Scan(req.RecipientAccountID); err != nil {
			http.Error(w, "Ошибка конвертации recipient_account_id", http.StatusBadRequest)
			return
		}

		var mediaUUID pgtype.UUID
		if err := mediaUUID.Scan(mediaID); err != nil {
			http.Error(w, "некорректный media_id", http.StatusBadRequest)
			return
		}

		parts, err := listAllChunkedParts(r, cu, mediaID, uploadID)
		if err != nil {
			log.Printf("ошибка получения списка частей файла %s перед завершением: %v", mediaID, err)
			http.Error(w, "ошибка получения списка частей", http.StatusInternalServerError)
			return
		}
		if len(parts) == 0 {
			http.Error(w, "нет ни одной загруженной части", http.StatusBadRequest)
			return
		}

		completeParts := make([]minio.CompletePart, 0, len(parts))
		var totalSize int64
		for _, p := range parts {
			completeParts = append(completeParts, minio.CompletePart{PartNumber: p.PartNumber, ETag: p.ETag})
			totalSize += p.Size
		}

		bucket := os.Getenv("MINIO_BUCKET")
		if _, err := cu.core.CompleteMultipartUpload(r.Context(), bucket, mediaID, uploadID, completeParts, minio.PutObjectOptions{}); err != nil {
			log.Printf("ошибка завершения multipart-загрузки файла %s в MinIO: %v", mediaID, err)
			http.Error(w, "ошибка завершения загрузки", http.StatusInternalServerError)
			return
		}

		fileName := req.FileName
		if fileName == "" {
			fileName = mediaID
		}

		var params db.SaveMediaFileWithIDParams
		params.ID = mediaUUID
		params.UploadedByAccountID = Session.AccountID
		params.RecipientAccountID = recipientID
		params.ObjectKey = fileName
		params.SizeBytes = totalSize

		if _, err := queries.SaveMediaFileWithID(r.Context(), params); err != nil {
			log.Printf("файл %s загружен в MinIO, но ошибка записи в БД: %v", mediaID, err)
			// объект в MinIO уже собран — не откатываем его: не оставлять
			// пользователя без файла из-за временной проблемы с БД. Тот же
			// mediaID можно будет позже дозаписать в БД вручную при необходимости.
			http.Error(w, "ошибка сохранения информации о файле", http.StatusInternalServerError)
			return
		}

		log.Printf("Файл успешно докачан по частям в MinIO: %s, размер: %d байт, частей: %d", mediaID, totalSize, len(parts))

		w.WriteHeader(http.StatusOK)
		w.Write([]byte(mediaID))
	}
}

// ---- POST /upload-media/{media_id}/abort?upload_id=... ----

func NewAbortChunkedUploadHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	cu := newChunkedUploadCore(minioClient)

	return func(w http.ResponseWriter, r *http.Request) {
		_, errTokCheck := CheckToken(w, r, queries)
		if errTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", errTokCheck)
			return
		}

		mediaID := r.PathValue("media_id")
		uploadID := r.URL.Query().Get("upload_id")
		if mediaID == "" || uploadID == "" {
			http.Error(w, "не хватает media_id или upload_id", http.StatusBadRequest)
			return
		}

		if err := cu.core.AbortMultipartUpload(r.Context(), os.Getenv("MINIO_BUCKET"), mediaID, uploadID); err != nil {
			log.Printf("ошибка отмены multipart-загрузки файла %s: %v", mediaID, err)
			// не считаем это фатальной ошибкой для клиента — если аплоада уже
			// не существовало (например, отменили дважды), отвечать ошибкой
			// пользователю смысла нет, он всё равно уже отказался от файла.
		}

		w.WriteHeader(http.StatusOK)
	}
}
