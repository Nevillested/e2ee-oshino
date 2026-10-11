package api

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"hash/crc32"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"server/internal/db"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// StickerStore — где лежат файлы стикеров на диске Москвы (STICKERS_DIR,
// по умолчанию /e2ee/stickers): <dir>/<pack_id>/<sticker_id>.<формат>.
type StickerStore struct {
	Dir string
}

func NewStickerStore() *StickerStore {
	dir := os.Getenv("STICKERS_DIR")
	if dir == "" {
		dir = "/e2ee/stickers"
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		log.Printf("стикеры: папка %s недоступна: %v", dir, err)
	}
	return &StickerStore{Dir: dir}
}

// StickerJSON / StickerPackJSON — пак для клиента.
type StickerJSON struct {
	ID     string `json:"id"`
	Format string `json:"format"`
}

type StickerPackJSON struct {
	ID        string        `json:"id"`
	Title     string        `json:"title"`
	IsOwner   bool          `json:"is_owner"`
	Installed bool          `json:"installed"`
	Deleted   bool          `json:"deleted"`
	Stickers  []StickerJSON `json:"stickers"`
}

func packJSON(ctx context.Context, queries *db.Queries, pack db.StickerPack, viewer pgtype.UUID) (StickerPackJSON, error) {
	out := StickerPackJSON{
		ID:       pack.ID.String(),
		Title:    pack.Title,
		IsOwner:  pack.OwnerAccountID == viewer,
		Deleted:  pack.DeletedAt.Valid,
		Stickers: []StickerJSON{},
	}
	if out.Deleted {
		return out, nil
	}
	installed, err := queries.IsStickerPackInstalled(ctx, db.IsStickerPackInstalledParams{AccountID: viewer, PackID: pack.ID})
	if err != nil {
		return out, err
	}
	out.Installed = installed
	rows, err := queries.ListPackStickers(ctx, pack.ID)
	if err != nil {
		return out, err
	}
	for _, s := range rows {
		out.Stickers = append(out.Stickers, StickerJSON{ID: s.ID.String(), Format: s.Format})
	}
	return out, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func pathUUID(r *http.Request, name string) (pgtype.UUID, bool) {
	var id pgtype.UUID
	return id, id.Scan(r.PathValue(name)) == nil
}

// ---------------- загрузка пака ----------------

// uploadEvents — ход обработки архива для окна загрузки: по строке JSON на
// событие (NDJSON), каждое сразу уходит клиенту (nginx не копит —
// X-Accel-Buffering: no).
type uploadEvents struct {
	w  http.ResponseWriter
	rc *http.ResponseController
}

func (e *uploadEvents) send(v map[string]any) {
	b, _ := json.Marshal(v)
	_, _ = e.w.Write(append(b, '\n'))
	_ = e.rc.Flush()
}

func (e *uploadEvents) stage(stage string, extra map[string]any) {
	v := map[string]any{"stage": stage}
	for k, x := range extra {
		v[k] = x
	}
	e.send(v)
}

func (e *uploadEvents) fail(err *stickerCheckError) {
	v := map[string]any{"stage": "error", "code": err.Code}
	if err.Name != "" {
		v["name"] = err.Name
	}
	if err.Limit != 0 {
		v["limit"] = err.Limit
	}
	e.send(v)
}

// NewUploadStickerPackHandler — POST /stickers/packs?title=…, тело — ZIP.
// Название и лимит паков проверяются до приёма архива (обычный ответ с
// кодом); дальше — события по шагам: принят, распаковка, проверка каждого
// файла (тип, объём, размеры), сохранение, регистрация, готово. Ушёл
// клиент (отмена в окне, обрыв) — контекст запроса отменён: транзакция не
// фиксируется, файлы удаляются, пака нет.
func NewUploadStickerPackHandler(queries *db.Queries, pool *pgxpool.Pool, store *StickerStore) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		ctx := r.Context()

		title := r.URL.Query().Get("title")
		if !validPackTitle(title) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"code": "title.invalid", "limit": maxPackTitleRunes})
			return
		}
		own, err := queries.CountOwnStickerPacks(ctx, session.AccountID)
		if err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		if own >= maxOwnStickerPacks {
			writeJSON(w, http.StatusConflict, map[string]any{"code": "pack.quota", "limit": maxOwnStickerPacks})
			return
		}

		// архив — во временный файл (до 80 МБ), не в память
		tmp, err := os.CreateTemp(store.Dir, ".upload-*.zip")
		if err != nil {
			http.Error(w, "ошибка сервера", http.StatusInternalServerError)
			return
		}
		defer os.Remove(tmp.Name())
		defer tmp.Close()
		received, err := io.Copy(tmp, http.MaxBytesReader(w, r.Body, maxStickerArchiveSz))
		if err != nil {
			var tooBig *http.MaxBytesError
			if errors.As(err, &tooBig) {
				writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"code": "archive.tooLarge", "limit": maxStickerArchiveSz / (1024 * 1024)})
			}
			return
		}

		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		ev := &uploadEvents{w: w, rc: http.NewResponseController(w)}
		ev.stage("received", map[string]any{"bytes": received})

		pack, checkErr := storeStickerPack(ctx, queries, pool, store, session.AccountID, title, tmp, received, ev)
		if checkErr != nil {
			if ctx.Err() != nil {
				log.Printf("стикеры: загрузка пака отменена клиентом")
				return
			}
			ev.fail(checkErr)
			return
		}
		out, err := packJSON(ctx, queries, pack, session.AccountID)
		if err != nil {
			ev.fail(&stickerCheckError{Code: "server.error"})
			return
		}
		log.Printf("стикеры: пак %s (%d шт.) загружен %s", pack.ID.String(), len(out.Stickers), session.AccountID.String())
		ev.stage("done", map[string]any{"pack": out})
	}
}

// storeStickerPack — распаковка, проверка, сохранение и регистрация пака.
func storeStickerPack(
	ctx context.Context, queries *db.Queries, pool *pgxpool.Pool, store *StickerStore,
	owner pgtype.UUID, title string, archive *os.File, size int64, ev *uploadEvents,
) (db.StickerPack, *stickerCheckError) {
	var none db.StickerPack

	ev.stage("unpacking", nil)
	zr, err := zip.NewReader(archive, size)
	if err != nil {
		return none, &stickerCheckError{Code: "archive.invalid"}
	}
	entries := stickerEntries(zr)
	ev.stage("counting", map[string]any{"count": len(entries)})
	if len(entries) == 0 {
		return none, &stickerCheckError{Code: "archive.empty"}
	}
	if len(entries) > maxStickersPerPack {
		return none, &stickerCheckError{Code: "archive.tooMany", Limit: maxStickersPerPack}
	}

	type checked struct {
		id     uuid.UUID
		format string
		data   []byte
	}
	files := make([]checked, 0, len(entries))
	for i, e := range entries {
		if ctx.Err() != nil {
			return none, &stickerCheckError{Code: "cancelled"}
		}
		ev.stage("checking", map[string]any{"index": i + 1, "total": len(entries), "name": e.name})
		data, readErr := readArchiveEntry(e, maxStaticStickerSz)
		if readErr != nil {
			return none, readErr
		}
		format, checkErr := inspectSticker(e.name, data)
		if checkErr != nil {
			return none, checkErr
		}
		files = append(files, checked{id: uuid.New(), format: format, data: data})
	}

	packID := uuid.New()
	incoming := filepath.Join(store.Dir, ".incoming-"+packID.String())
	final := filepath.Join(store.Dir, packID.String())
	if err := os.Mkdir(incoming, 0o750); err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	committed := false
	defer func() {
		os.RemoveAll(incoming)
		if !committed {
			os.RemoveAll(final)
		}
	}()
	for i, f := range files {
		if ctx.Err() != nil {
			return none, &stickerCheckError{Code: "cancelled"}
		}
		ev.stage("saving", map[string]any{"index": i + 1, "total": len(files)})
		if err := os.WriteFile(filepath.Join(incoming, f.id.String()+"."+f.format), f.data, 0o640); err != nil {
			return none, &stickerCheckError{Code: "server.error"}
		}
	}

	ev.stage("registering", nil)
	tx, err := pool.Begin(ctx)
	if err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	defer tx.Rollback(context.Background())
	qtx := queries.WithTx(tx)
	packUUID := pgtype.UUID{Bytes: packID, Valid: true}
	if err := qtx.CreateStickerPack(ctx, db.CreateStickerPackParams{ID: packUUID, OwnerAccountID: owner, Title: title}); err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	for i, f := range files {
		if err := qtx.CreateSticker(ctx, db.CreateStickerParams{
			ID:        pgtype.UUID{Bytes: f.id, Valid: true},
			PackID:    packUUID,
			Position:  int32(i),
			Format:    f.format,
			FilePath:  filepath.Join(packID.String(), f.id.String()+"."+f.format),
			SizeBytes: int32(len(f.data)),
		}); err != nil {
			return none, &stickerCheckError{Code: "server.error"}
		}
	}
	// загрузивший сразу получает пак в панель
	if err := qtx.InstallStickerPack(ctx, db.InstallStickerPackParams{AccountID: owner, PackID: packUUID}); err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	if err := os.Rename(incoming, final); err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	if err := tx.Commit(ctx); err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	committed = true
	pack, err := queries.GetStickerPack(context.Background(), packUUID)
	if err != nil {
		return none, &stickerCheckError{Code: "server.error"}
	}
	return pack, nil
}

// ---------------- паки ----------------

// NewMyStickerPacksHandler — GET /stickers/packs/mine: паки в панели, новые первыми.
func NewMyStickerPacksHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		packs, err := queries.ListInstalledStickerPacks(r.Context(), session.AccountID)
		if err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		out := []StickerPackJSON{}
		for _, p := range packs {
			j, err := packJSON(r.Context(), queries, p, session.AccountID)
			if err != nil {
				http.Error(w, "ошибка базы", http.StatusInternalServerError)
				return
			}
			out = append(out, j)
		}
		writeJSON(w, http.StatusOK, map[string]any{"packs": out})
	}
}

// NewGetStickerPackHandler — GET /stickers/packs/{pack_id}.
func NewGetStickerPackHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		id, ok := pathUUID(r, "pack_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		writePack(w, r, queries, id, session.AccountID)
	}
}

// NewGetStickerPackBySticker — GET /stickers/items/{sticker_id}/pack: пак стикера
// из переписки (открыть пак, скачать его целиком).
func NewGetStickerPackBySticker(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		id, ok := pathUUID(r, "sticker_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		sticker, err := queries.GetSticker(r.Context(), id)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.NotFound(w, r)
			} else {
				http.Error(w, "ошибка базы", http.StatusInternalServerError)
			}
			return
		}
		writePack(w, r, queries, sticker.PackID, session.AccountID)
	}
}

func writePack(w http.ResponseWriter, r *http.Request, queries *db.Queries, packID, viewer pgtype.UUID) {
	pack, err := queries.GetStickerPack(r.Context(), packID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
		} else {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
		}
		return
	}
	out, err := packJSON(r.Context(), queries, pack, viewer)
	if err != nil {
		http.Error(w, "ошибка базы", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// NewStickerPackFilesHandler — GET /stickers/packs/{pack_id}/files: весь пак
// одним ZIP (<sticker_id>.<формат>) — сервер видит "скачан пак", а не какой
// именно стикер пришёл в переписке. Пак удалён — 410.
func NewStickerPackFilesHandler(queries *db.Queries, store *StickerStore) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, err := CheckToken(w, r, queries); err != nil {
			return
		}
		id, ok := pathUUID(r, "pack_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		pack, err := queries.GetStickerPack(r.Context(), id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if pack.DeletedAt.Valid {
			http.Error(w, "стикерпак удалён автором", http.StatusGone)
			return
		}
		rows, err := queries.ListPackStickers(r.Context(), id)
		if err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/zip")
		zw := zip.NewWriter(w)
		for _, s := range rows {
			data, err := os.ReadFile(filepath.Join(store.Dir, s.FilePath))
			if err != nil {
				log.Printf("стикеры: файл %s не прочитан: %v", s.FilePath, err)
				return
			}
			if err := writeStoredEntry(zw, s.ID.String()+"."+s.Format, data); err != nil {
				return
			}
		}
		_ = zw.Close()
	}
}

// writeStoredEntry — файл в ZIP без сжатия (форматы и так сжатые). CRC и
// размеры — в заголовке перед данными, без "data descriptor" после них:
// иначе java.util.zip.ZipInputStream на клиенте падает ("only DEFLATED
// entries can have EXT descriptor"), а CreateHeader пишет descriptor всегда.
func writeStoredEntry(zw *zip.Writer, name string, data []byte) error {
	w, err := zw.CreateRaw(&zip.FileHeader{
		Name:               name,
		Method:             zip.Store,
		CRC32:              crc32.ChecksumIEEE(data),
		CompressedSize64:   uint64(len(data)),
		UncompressedSize64: uint64(len(data)),
	})
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// NewGetStickerHandler — GET /stickers/items/{sticker_id}: один стикер. Пак удалён — 410.
func NewGetStickerHandler(queries *db.Queries, store *StickerStore) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, err := CheckToken(w, r, queries); err != nil {
			return
		}
		id, ok := pathUUID(r, "sticker_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		sticker, err := queries.GetSticker(r.Context(), id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if sticker.DeletedAt.Valid {
			http.Error(w, "стикерпак удалён автором", http.StatusGone)
			return
		}
		w.Header().Set("Content-Type", stickerContentType(sticker.Format))
		http.ServeFile(w, r, filepath.Join(store.Dir, sticker.FilePath))
	}
}

// NewInstallStickerPackHandler — POST /stickers/packs/{pack_id}/install
// (в начало панели), DELETE — убрать из панели.
func NewInstallStickerPackHandler(queries *db.Queries, install bool) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		id, ok := pathUUID(r, "pack_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		if install {
			pack, err := queries.GetStickerPack(r.Context(), id)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			if pack.DeletedAt.Valid {
				http.Error(w, "стикерпак удалён автором", http.StatusGone)
				return
			}
			err = queries.InstallStickerPack(r.Context(), db.InstallStickerPackParams{AccountID: session.AccountID, PackID: id})
			if err != nil {
				http.Error(w, "ошибка базы", http.StatusInternalServerError)
				return
			}
		} else if err := queries.UninstallStickerPack(r.Context(), db.UninstallStickerPackParams{AccountID: session.AccountID, PackID: id}); err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

// NewDeleteStickerPackHandler — DELETE /stickers/packs/{pack_id}: удалить
// навсегда (только автор). Пак пропадает из панелей у всех, файлы удаляются;
// в старой переписке — "стикерпак удалён автором".
func NewDeleteStickerPackHandler(queries *db.Queries, pool *pgxpool.Pool, store *StickerStore) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		id, ok := pathUUID(r, "pack_id")
		if !ok {
			http.Error(w, "неверный id", http.StatusBadRequest)
			return
		}
		pack, err := queries.GetStickerPack(r.Context(), id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if pack.OwnerAccountID != session.AccountID {
			http.Error(w, "удалить пак может только автор", http.StatusForbidden)
			return
		}
		tx, err := pool.Begin(r.Context())
		if err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		defer tx.Rollback(context.Background())
		qtx := queries.WithTx(tx)
		if err := qtx.MarkStickerPackDeleted(r.Context(), id); err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		if err := qtx.UninstallStickerPackForEveryone(r.Context(), id); err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			http.Error(w, "ошибка базы", http.StatusInternalServerError)
			return
		}
		if err := os.RemoveAll(filepath.Join(store.Dir, id.String())); err != nil {
			log.Printf("стикеры: файлы пака %s не удалены: %v", id.String(), err)
		}
		log.Printf("стикеры: пак %s удалён автором", id.String())
		w.WriteHeader(http.StatusOK)
	}
}
