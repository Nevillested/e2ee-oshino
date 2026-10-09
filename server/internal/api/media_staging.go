package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"server/internal/db"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

// Горячий буфер медиа на диске московского сервера.
//
// Идея: NAS с MinIO (архив) часто выключен или его датасет не разблокирован —
// пока его нет, отправка и получение файлов раньше просто не работали. Теперь
// свежий файл принимается и хранится здесь, на диске Москвы, пока его не
// скачает получатель; только после этого фоновый архиватор переносит его в
// MinIO и удаляет локальную копию. Нескачанные файлы (в т.ч. "Заметки", где
// получатель — сам загрузчик) остаются в буфере — решение владельца; когда
// буфер упрётся в stagingMinFree, новые файлы просто пойдут сразу в MinIO. Если в момент переноса NAS недоступен — файл просто ждёт
// здесь до следующей попытки, ничего не теряется.
//
// Здесь лежит ровно то же, что и в MinIO, — шифротекст: ключ расшифровки
// едет внутри Double-Ratchet-конверта и серверу не известен.
//
// Диск у Москвы маленький, поэтому файл принимается в буфер только если
// после него на диске останется не меньше stagingMinFree; иначе загрузка
// идёт старым путём, сразу в MinIO.
//
// Раскладка папки (MEDIA_STAGING_DIR, по умолчанию /e2ee/media-staging):
//
//	files/<media_id>         — готовый файл
//	files/<media_id>.tmp     — файл в процессе записи
//	chunked/<media_id>/      — чанковая загрузка в процессе:
//	    upload_id            — её upload_id (сверяется на каждом шаге)
//	    <n>                  — принятая часть номер n
//	    <n>.tmp              — часть в процессе записи

const (
	// upload_id чанковой загрузки в буфер — отличает её от multipart-загрузки
	// MinIO во всех чанковых эндпоинтах (upload_media_chunked.go).
	localUploadIDPrefix = "local-"

	// недособранные чанковые загрузки и висячие .tmp старше этого — мусор.
	stagingAbandonedAge = 3 * 24 * time.Hour
	stagingTmpMaxAge    = time.Hour

	// файл, которого нет в media_files (аккаунт удалён — строка ушла каскадом,
	// или запись в БД не удалась после записи файла), удаляется не сразу —
	// запас на гонку "файл уже записан, строка ещё вставляется".
	stagingOrphanAge = 24 * time.Hour

	stagingArchiveInterval = 2 * time.Minute

	// жёсткий пол свободного места для записи частей уже начатой чанковой
	// загрузки (решение "принять в буфер" принято на /init с полным запасом
	// stagingMinFree; здесь только не даём забить диск в ноль, если
	// параллельно пришло много всего).
	stagingHardFloor = 100 * 1024 * 1024
)

var errStagingDisabled = errors.New("буфер медиа на сервере выключен")

type MediaStaging struct {
	dir     string
	minFree int64
}

// NewMediaStaging — MEDIA_STAGING_DIR (по умолчанию /e2ee/media-staging) и
// MEDIA_STAGING_MIN_FREE_MB (по умолчанию 500). Если папку создать не
// удалось — возвращает nil: буфер выключен, всё идёт в MinIO, как раньше.
func NewMediaStaging() *MediaStaging {
	dir := os.Getenv("MEDIA_STAGING_DIR")
	if dir == "" {
		dir = "/e2ee/media-staging"
	}
	minFreeMB := int64(500)
	if v := os.Getenv("MEDIA_STAGING_MIN_FREE_MB"); v != "" {
		if parsed, err := strconv.ParseInt(v, 10, 64); err == nil && parsed >= 0 {
			minFreeMB = parsed
		}
	}
	s := &MediaStaging{dir: dir, minFree: minFreeMB * 1024 * 1024}
	for _, sub := range []string{s.filesDir(), s.chunkedRoot()} {
		if err := os.MkdirAll(sub, 0o700); err != nil {
			log.Printf("media staging: не удалось создать %s: %v — буфер выключен, файлы идут сразу в MinIO", sub, err)
			return nil
		}
	}
	log.Printf("media staging: буфер %s, запас свободного места %d МБ", dir, minFreeMB)
	return s
}

func (s *MediaStaging) filesDir() string    { return filepath.Join(s.dir, "files") }
func (s *MediaStaging) chunkedRoot() string { return filepath.Join(s.dir, "chunked") }

// media_id приходит из URL — до того, как склеить его в путь, убеждаемся,
// что это UUID (никаких "../" и прочего).
func validMediaID(mediaID string) bool {
	_, err := uuid.Parse(mediaID)
	return err == nil && !strings.ContainsAny(mediaID, `/\.`)
}

func (s *MediaStaging) filePath(mediaID string) string {
	return filepath.Join(s.filesDir(), mediaID)
}

func (s *MediaStaging) chunkDir(mediaID string) string {
	return filepath.Join(s.chunkedRoot(), mediaID)
}

// CanAccept — поместится ли файл размером size в буфер так, чтобы на диске
// осталось не меньше minFree. Ошибка определения места = "не поместится".
func (s *MediaStaging) CanAccept(size int64) bool {
	if s == nil {
		return false
	}
	free, err := diskFreeBytes(s.dir)
	if err != nil {
		log.Printf("media staging: не удалось узнать свободное место: %v", err)
		return false
	}
	return free-size >= s.minFree
}

// writeAtomically пишет r в path через path.tmp + fsync + rename — файл по
// итоговому пути либо целиком есть, либо его нет вовсе.
func writeAtomically(path string, r io.Reader) (int64, error) {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(f, r)
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return 0, err
	}
	return n, nil
}

// SaveFile — нечанковый файл целиком.
func (s *MediaStaging) SaveFile(mediaID string, r io.Reader) (int64, error) {
	if !validMediaID(mediaID) {
		return 0, errors.New("некорректный media_id")
	}
	return writeAtomically(s.filePath(mediaID), r)
}

// Open — готовый файл из буфера (для скачивания и архиватора).
func (s *MediaStaging) Open(mediaID string) (*os.File, error) {
	if s == nil {
		return nil, errStagingDisabled
	}
	if !validMediaID(mediaID) {
		return nil, errors.New("некорректный media_id")
	}
	return os.Open(s.filePath(mediaID))
}

// ---- чанковая загрузка в буфер ----

// NewChunkedUpload заводит папку под части и возвращает upload_id.
func (s *MediaStaging) NewChunkedUpload(mediaID string) (string, error) {
	if !validMediaID(mediaID) {
		return "", errors.New("некорректный media_id")
	}
	dir := s.chunkDir(mediaID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	uploadID := localUploadIDPrefix + uuid.NewString()
	if _, err := writeAtomically(filepath.Join(dir, "upload_id"), strings.NewReader(uploadID)); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	return uploadID, nil
}

// checkChunkedUpload — загрузка существует и upload_id совпадает. upload_id
// случаен и известен только загрузчику — играет ту же роль, что и upload_id
// multipart-загрузки в MinIO.
func (s *MediaStaging) checkChunkedUpload(mediaID, uploadID string) error {
	if s == nil {
		return errStagingDisabled
	}
	if !validMediaID(mediaID) {
		return errors.New("некорректный media_id")
	}
	stored, err := os.ReadFile(filepath.Join(s.chunkDir(mediaID), "upload_id"))
	if err != nil {
		return fmt.Errorf("загрузка не найдена: %w", err)
	}
	if string(stored) != uploadID {
		return errors.New("upload_id не совпадает")
	}
	return nil
}

func (s *MediaStaging) WritePart(mediaID, uploadID string, partNumber int, data []byte) error {
	if err := s.checkChunkedUpload(mediaID, uploadID); err != nil {
		return err
	}
	if free, err := diskFreeBytes(s.dir); err != nil || free-int64(len(data)) < stagingHardFloor {
		return errors.New("на сервере закончилось место")
	}
	path := filepath.Join(s.chunkDir(mediaID), strconv.Itoa(partNumber))
	_, err := writeAtomically(path, bytes.NewReader(data))
	return err
}

type stagedPart struct {
	Number int
	Size   int64
}

func (s *MediaStaging) ListParts(mediaID, uploadID string) ([]stagedPart, error) {
	if err := s.checkChunkedUpload(mediaID, uploadID); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(s.chunkDir(mediaID))
	if err != nil {
		return nil, err
	}
	parts := make([]stagedPart, 0, len(entries))
	for _, e := range entries {
		n, err := strconv.Atoi(e.Name())
		if err != nil || n < 1 {
			continue // upload_id, *.tmp
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		parts = append(parts, stagedPart{Number: n, Size: info.Size()})
	}
	sort.Slice(parts, func(i, j int) bool { return parts[i].Number < parts[j].Number })
	return parts, nil
}

// CompleteChunkedUpload склеивает части 1..N в готовый файл и возвращает его
// размер. Каждая часть удаляется сразу после того, как дописана, — пик
// занятого места остаётся ≈ размер файла, а не удвоенный. Если склейка
// оборвалась посередине, уже удалённые части клиент просто перезальёт:
// он перед /complete сверяется со списком частей.
func (s *MediaStaging) CompleteChunkedUpload(mediaID, uploadID string) (int64, int, error) {
	parts, err := s.ListParts(mediaID, uploadID)
	if err != nil {
		return 0, 0, err
	}
	if len(parts) == 0 {
		return 0, 0, errors.New("нет ни одной загруженной части")
	}
	for i, p := range parts {
		if p.Number != i+1 {
			return 0, 0, fmt.Errorf("не хватает части %d", i+1)
		}
	}

	dir := s.chunkDir(mediaID)
	finalPath := s.filePath(mediaID)
	tmp := finalPath + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, 0, err
	}
	fail := func(err error) (int64, int, error) {
		out.Close()
		os.Remove(tmp)
		return 0, 0, err
	}
	var total int64
	for _, p := range parts {
		partPath := filepath.Join(dir, strconv.Itoa(p.Number))
		in, err := os.Open(partPath)
		if err != nil {
			return fail(err)
		}
		n, err := io.Copy(out, in)
		in.Close()
		if err != nil {
			return fail(err)
		}
		total += n
		os.Remove(partPath)
	}
	if err := out.Sync(); err != nil {
		return fail(err)
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return 0, 0, err
	}
	if err := os.Rename(tmp, finalPath); err != nil {
		os.Remove(tmp)
		return 0, 0, err
	}
	os.RemoveAll(dir)
	return total, len(parts), nil
}

func (s *MediaStaging) AbortChunkedUpload(mediaID, uploadID string) error {
	if err := s.checkChunkedUpload(mediaID, uploadID); err != nil {
		return err
	}
	return os.RemoveAll(s.chunkDir(mediaID))
}

// ---- перенос в архив ----

// StartMediaArchiver — раз в stagingArchiveInterval переносит в MinIO файлы,
// которые получатель уже скачал, и подчищает мусор в буфере. Если MinIO недоступен (NAS выключен / датасет
// заблокирован) — проход пропускается целиком, файлы ждут следующего.
func StartMediaArchiver(queries *db.Queries, minioClient *minio.Client, s *MediaStaging) {
	if s == nil {
		return
	}
	go func() {
		ticker := time.NewTicker(stagingArchiveInterval)
		defer ticker.Stop()
		for {
			s.archivePass(queries, minioClient)
			s.cleanupPass(queries)
			<-ticker.C
		}
	}()
}

var archiverLastReachable = true
var archiverStateMu sync.Mutex

// logArchiveReachability пишет в лог только смену состояния "MinIO
// доступен/недоступен" — иначе при выключенном NAS лог забивался бы строкой
// каждые две минуты.
func logArchiveReachability(reachable bool, err error) {
	archiverStateMu.Lock()
	defer archiverStateMu.Unlock()
	if reachable == archiverLastReachable {
		return
	}
	archiverLastReachable = reachable
	if reachable {
		log.Printf("media archiver: архив (MinIO) снова доступен")
	} else {
		log.Printf("media archiver: архив (MinIO) недоступен, файлы ждут в буфере: %v", err)
	}
}

func (s *MediaStaging) archivePass(queries *db.Queries, minioClient *minio.Client) {
	bucket := os.Getenv("MINIO_BUCKET")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	ok, err := minioClient.BucketExists(ctx, bucket)
	cancel()
	if err == nil && !ok {
		err = fmt.Errorf("бакет %s не найден", bucket)
	}
	logArchiveReachability(err == nil, err)
	if err != nil {
		return
	}

	rows, err := queries.ListStagedMediaReadyForArchive(context.Background())
	if err != nil {
		log.Printf("media archiver: ошибка выборки файлов для архива: %v", err)
		return
	}
	for _, mf := range rows {
		if err := s.archiveOne(queries, minioClient, bucket, mf); err != nil {
			log.Printf("media archiver: %s не перенесён: %v", mf.ID.String(), err)
			// NAS пропал посреди прохода — остальные не пытаемся, подождём.
			return
		}
	}
}

func (s *MediaStaging) archiveOne(queries *db.Queries, minioClient *minio.Client, bucket string, mf db.MediaFile) error {
	mediaID := mf.ID.String()
	// большой файл через слабый туннель может ехать долго
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()

	f, err := s.Open(mediaID)
	if errors.Is(err, os.ErrNotExist) {
		// локальной копии нет — возможно, прошлый проход успел залить файл и
		// удалить его, но не успел обновить строку. Проверяем архив.
		info, statErr := minioClient.StatObject(ctx, bucket, mediaID, minio.StatObjectOptions{})
		if statErr == nil && info.Size == mf.SizeBytes {
			return queries.MarkMediaArchived(ctx, mf.ID)
		}
		return fmt.Errorf("файла нет ни в буфере, ни в архиве: %v", statErr)
	}
	if err != nil {
		return err
	}
	defer f.Close()

	if _, err := minioClient.PutObject(ctx, bucket, mediaID, f, mf.SizeBytes, minio.PutObjectOptions{}); err != nil {
		return fmt.Errorf("загрузка в MinIO: %w", err)
	}
	info, err := minioClient.StatObject(ctx, bucket, mediaID, minio.StatObjectOptions{})
	if err != nil {
		return fmt.Errorf("проверка в MinIO: %w", err)
	}
	if info.Size != mf.SizeBytes {
		return fmt.Errorf("в MinIO размер %d, ожидался %d", info.Size, mf.SizeBytes)
	}
	// Сначала строка, потом удаление: если упадём между ними, файл просто
	// лежит лишнюю копию до уборки, а скачивание идёт из архива.
	if err := queries.MarkMediaArchived(ctx, mf.ID); err != nil {
		return fmt.Errorf("отметка в БД: %w", err)
	}
	if err := os.Remove(s.filePath(mediaID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("media archiver: %s в архиве, но локальная копия не удалена: %v", mediaID, err)
	}
	log.Printf("media archiver: %s перенесён в архив (%d байт)", mediaID, mf.SizeBytes)
	return nil
}

// cleanupPass — висячие .tmp, брошенные чанковые загрузки и файлы, у которых
// больше нет строки в media_files (или она уже указывает на архив).
func (s *MediaStaging) cleanupPass(queries *db.Queries) {
	now := time.Now()

	if entries, err := os.ReadDir(s.filesDir()); err == nil {
		for _, e := range entries {
			info, err := e.Info()
			if err != nil {
				continue
			}
			age := now.Sub(info.ModTime())
			path := filepath.Join(s.filesDir(), e.Name())
			if strings.HasSuffix(e.Name(), ".tmp") {
				if age > stagingTmpMaxAge {
					os.Remove(path)
				}
				continue
			}
			if age < stagingOrphanAge || !validMediaID(e.Name()) {
				continue
			}
			var id pgtype.UUID
			if id.Scan(e.Name()) != nil {
				continue
			}
			mf, err := queries.GetMediaFile(context.Background(), id)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && mf.Storage == "archive") {
				log.Printf("media staging: удаляю лишний файл %s из буфера", e.Name())
				os.Remove(path)
			}
		}
	}

	if entries, err := os.ReadDir(s.chunkedRoot()); err == nil {
		for _, e := range entries {
			info, err := e.Info()
			if err != nil || now.Sub(info.ModTime()) < stagingAbandonedAge {
				continue
			}
			log.Printf("media staging: удаляю брошенную чанковую загрузку %s", e.Name())
			os.RemoveAll(filepath.Join(s.chunkedRoot(), e.Name()))
		}
	}
}
