package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	"server/internal/db"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

// Presigned-URL: клиент льёт/качает байты файлов НАПРЯМУЮ в MinIO
// (публичный эндпоинт files.oshino.space → VPS в Токио → FRP-туннель до
// NAS), минуя московский сервер. Москва только подписывает URL (чистая
// локальная криптография, реального подключения к MinIO при этом нет) и
// заводит/проверяет строку в media_files. Служебные вызовы multipart
// (init/complete/list) по-прежнему идут через Москву на 127.0.0.1:9000 —
// они крошечные.
//
// [presign] — отдельный minio-клиент с endpoint = MINIO_PUBLIC_ENDPOINT.

const presignExpiry = 2 * time.Hour

// ---- POST /upload-media/presign  (нечанковый файл целиком) ----
// Ответ: {media_id, url}. Строку в media_files здесь НЕ создаём — только
// после подтверждения (/finalize), что байты реально долетели: иначе при
// обрыве PUT в БД оставались бы висячие записи без объекта.

type presignPutResponse struct {
	MediaID string `json:"media_id"`
	URL     string `json:"url"`
}

func NewPresignPutHandler(queries *db.Queries, presign *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, errTok := CheckToken(w, r, queries); errTok != nil {
			log.Printf("presign put: ошибка токена: %v", errTok)
			return
		}

		mediaID := uuid.NewString()
		u, err := presign.PresignedPutObject(r.Context(), os.Getenv("MINIO_BUCKET"), mediaID, presignExpiry)
		if err != nil {
			log.Printf("presign put: ошибка подписи URL: %v", err)
			http.Error(w, "ошибка подписи URL", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(presignPutResponse{MediaID: mediaID, URL: u.String()})
	}
}

// ---- POST /upload-media/{media_id}/finalize  (после успешного PUT) ----
// Тело: {recipient_account_id, size_bytes, file_name}
// Проверяет, что объект реально лежит в MinIO нужного размера, и только
// тогда создаёт строку в media_files. [local] — обычный клиент (через FRP
// на 127.0.0.1:9000), StatObject крошечный.

type finalizeUploadRequest struct {
	RecipientAccountID string `json:"recipient_account_id"`
	SizeBytes          int64  `json:"size_bytes"`
	FileName           string `json:"file_name"`
}

func NewFinalizeUploadHandler(queries *db.Queries, local *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, errTok := CheckToken(w, r, queries)
		if errTok != nil {
			log.Printf("finalize: ошибка токена: %v", errTok)
			return
		}

		mediaID := r.PathValue("media_id")
		var mediaUUID pgtype.UUID
		if err := mediaUUID.Scan(mediaID); err != nil {
			http.Error(w, "некорректный media_id", http.StatusBadRequest)
			return
		}

		var req finalizeUploadRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
			http.Error(w, "ошибка чтения тела запроса", http.StatusBadRequest)
			return
		}
		if req.SizeBytes <= 0 || req.SizeBytes > maxUploadSizeBytes {
			http.Error(w, "некорректный размер файла", http.StatusBadRequest)
			return
		}

		var recipientID pgtype.UUID
		if err := recipientID.Scan(req.RecipientAccountID); err != nil {
			http.Error(w, "Ошибка конвертации recipient_account_id", http.StatusBadRequest)
			return
		}

		info, err := local.StatObject(r.Context(), os.Getenv("MINIO_BUCKET"), mediaID, minio.StatObjectOptions{})
		if err != nil {
			log.Printf("finalize: объект %s не найден в MinIO: %v", mediaID, err)
			http.Error(w, "файл не загружен", http.StatusBadRequest)
			return
		}
		if info.Size != req.SizeBytes {
			log.Printf("finalize: %s размер не сходится (в MinIO %d, ожидалось %d)", mediaID, info.Size, req.SizeBytes)
			http.Error(w, "файл загружен не полностью", http.StatusBadRequest)
			return
		}

		fileName := req.FileName
		if fileName == "" {
			fileName = mediaID
		}

		var params db.SaveMediaFileWithIDParams
		params.ID = mediaUUID
		params.UploadedByAccountID = session.AccountID
		params.RecipientAccountID = recipientID
		params.ObjectKey = fileName
		params.SizeBytes = info.Size
		if _, err := queries.SaveMediaFileWithID(r.Context(), params); err != nil {
			log.Printf("finalize: ошибка записи в БД для %s: %v", mediaID, err)
			http.Error(w, "ошибка сохранения информации о файле", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

// ---- POST /upload-media/{media_id}/part-urls  (части чанковой загрузки) ----
// Тело:  {upload_id, part_numbers: [1,2,3]}
// Ответ: {urls: {"1": "...", "2": "..."}}

type presignPartsRequest struct {
	UploadID    string `json:"upload_id"`
	PartNumbers []int  `json:"part_numbers"`
}

type presignPartsResponse struct {
	URLs map[string]string `json:"urls"`
}

func NewPresignPartsHandler(queries *db.Queries, presign *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, errTok := CheckToken(w, r, queries); errTok != nil {
			log.Printf("presign parts: ошибка токена: %v", errTok)
			return
		}

		mediaID := r.PathValue("media_id")
		var req presignPartsRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&req); err != nil {
			http.Error(w, "ошибка чтения тела запроса", http.StatusBadRequest)
			return
		}
		if mediaID == "" || req.UploadID == "" || len(req.PartNumbers) == 0 || len(req.PartNumbers) > 200 {
			http.Error(w, "некорректный запрос", http.StatusBadRequest)
			return
		}

		bucket := os.Getenv("MINIO_BUCKET")
		urls := make(map[string]string, len(req.PartNumbers))
		for _, pn := range req.PartNumbers {
			if pn < 1 {
				http.Error(w, "некорректный номер части", http.StatusBadRequest)
				return
			}
			params := url.Values{}
			params.Set("uploadId", req.UploadID)
			params.Set("partNumber", strconv.Itoa(pn))
			u, err := presign.Presign(r.Context(), http.MethodPut, bucket, mediaID, presignExpiry, params)
			if err != nil {
				log.Printf("presign parts: ошибка подписи части %d: %v", pn, err)
				http.Error(w, "ошибка подписи URL", http.StatusInternalServerError)
				return
			}
			urls[strconv.Itoa(pn)] = u.String()
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(presignPartsResponse{URLs: urls})
	}
}

// ---- GET /media/{id}/url  → {url, size_bytes}  presigned GET для скачивания ----

type presignGetResponse struct {
	URL       string `json:"url"`
	SizeBytes int64  `json:"size_bytes"`
}

func NewPresignGetHandler(queries *db.Queries, presign *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, errTok := CheckToken(w, r, queries)
		if errTok != nil {
			log.Printf("presign get: ошибка токена: %v", errTok)
			return
		}

		fileID := r.PathValue("id")
		var fileUUID pgtype.UUID
		if err := fileUUID.Scan(fileID); err != nil {
			http.Error(w, "Ошибка конвертации FileId", http.StatusBadRequest)
			return
		}

		mediaFile, sqlErr := queries.GetMediaFile(r.Context(), fileUUID)
		if sqlErr != nil {
			if errors.Is(sqlErr, pgx.ErrNoRows) {
				http.Error(w, "Такого файла нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска файла", http.StatusInternalServerError)
			}
			return
		}

		// Тот же контроль доступа, что и у прямого скачивания (download_media.go):
		// только загрузчик или получатель.
		if session.AccountID != mediaFile.UploadedByAccountID && session.AccountID != mediaFile.RecipientAccountID {
			http.Error(w, "Нет прав доступа к файлу", http.StatusForbidden)
			return
		}

		u, err := presign.PresignedGetObject(r.Context(), os.Getenv("MINIO_BUCKET"), fileID, presignExpiry, nil)
		if err != nil {
			log.Printf("presign get: ошибка подписи URL: %v", err)
			http.Error(w, "ошибка подписи URL", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(presignGetResponse{URL: u.String(), SizeBytes: mediaFile.SizeBytes})
	}
}
