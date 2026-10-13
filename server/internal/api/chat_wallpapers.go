package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"server/internal/db"
	"strconv"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Обои чатов — как фото профиля, НЕ шифруются (решение владельца проекта):
// после переустановки приложения ключей устройства уже нет, а обои должны
// вернуться. Лежат в базе на Москве (chat_wallpapers, 025_chat_wallpapers.sql).
//
// Строка (account_id, peer_account_id) — фон, который видит account_id в
// чате с peer_account_id. "Установить также у собеседника" — та же картинка
// ещё и в строку собеседника (peer, я); ему — сигнал wallpaper_changed, если
// он в сети (не в сети — заберёт при следующем запуске по списку).

// maxWallpaperBytes — клиент присылает уже сжатый JPEG (сотни КБ).
const maxWallpaperBytes = 3 * 1024 * 1024

type chatWallpaperInfo struct {
	PeerAccountID string `json:"peer_account_id"`
	// время последней смены в мс — клиент по нему понимает, что картинку пора перекачать
	Version int64 `json:"version"`
}

type chatWallpapersResponse struct {
	Wallpapers []chatWallpaperInfo `json:"wallpapers"`
}

func wallpaperPeer(w http.ResponseWriter, r *http.Request) (pgtype.UUID, bool) {
	var peerID pgtype.UUID
	if err := peerID.Scan(r.PathValue("peer_account_id")); err != nil {
		http.Error(w, "Ошибка конвертации peer_account_id", http.StatusBadRequest)
		return peerID, false
	}
	return peerID, true
}

// PUT /chats/wallpapers/{peer_account_id}: multipart "file" (JPEG) и
// необязательное поле "for_peer" = "1".
func NewSetChatWallpaperHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		peerID, ok := wallpaperPeer(w, r)
		if !ok {
			return
		}
		if peerID == Session.AccountID {
			http.Error(w, "Нельзя поставить обои чату с самим собой", http.StatusBadRequest)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxWallpaperBytes+64*1024)
		file, _, formErr := r.FormFile("file")
		if formErr != nil {
			http.Error(w, "ошибка получения файла из запроса", http.StatusBadRequest)
			return
		}
		defer file.Close()
		image, readErr := io.ReadAll(io.LimitReader(file, maxWallpaperBytes+1))
		if readErr != nil || len(image) == 0 {
			http.Error(w, "ошибка чтения файла", http.StatusBadRequest)
			return
		}
		if len(image) > maxWallpaperBytes {
			http.Error(w, "картинка слишком большая", http.StatusRequestEntityTooLarge)
			return
		}
		// только JPEG — сервер отдаёт эти байты как image/jpeg
		if !bytes.HasPrefix(image, []byte{0xFF, 0xD8, 0xFF}) {
			http.Error(w, "ожидается JPEG", http.StatusUnsupportedMediaType)
			return
		}
		forPeer := r.FormValue("for_peer") == "1"
		// заблокированному (в любую сторону) чужие обои не ставим
		if forPeer && blockedBetween(r.Context(), queries, Session.AccountID, peerID) {
			http.Error(w, "Собеседник недоступен", http.StatusForbidden)
			return
		}

		updatedAt, sqlErr := queries.SetChatWallpaper(r.Context(), db.SetChatWallpaperParams{
			AccountID:     Session.AccountID,
			PeerAccountID: peerID,
			Image:         image,
		})
		if sqlErr != nil {
			log.Printf("обои: ошибка сохранения: %v", sqlErr)
			http.Error(w, "Ошибка сохранения обоев", http.StatusInternalServerError)
			return
		}
		if forPeer {
			if _, sqlErr := queries.SetChatWallpaper(r.Context(), db.SetChatWallpaperParams{
				AccountID:     peerID,
				PeerAccountID: Session.AccountID,
				Image:         image,
			}); sqlErr != nil {
				log.Printf("обои: ошибка сохранения у собеседника: %v", sqlErr)
				http.Error(w, "Ошибка сохранения обоев у собеседника", http.StatusInternalServerError)
				return
			}
			notifyWallpaperChanged(r, queries, registry, peerID, Session.AccountID)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(chatWallpaperInfo{PeerAccountID: peerID.String(), Version: updatedAt.Time.UnixMilli()})
	}
}

// notifyWallpaperChanged — устройствам [to], которые сейчас в сети: у чата с
// [from] новые обои. Не в сети — не копим: клиент сверяет список при запуске.
func notifyWallpaperChanged(r *http.Request, queries *db.Queries, registry *ConnectionRegistry, to, from pgtype.UUID) {
	msgBytes, err := json.Marshal(struct {
		Type      string `json:"Type"`
		AccountID string `json:"AccountId"`
	}{Type: "wallpaper_changed", AccountID: from.String()})
	if err != nil {
		return
	}
	devices, err := queries.GetDevicesByAccount(r.Context(), to)
	if err != nil {
		return
	}
	for _, device := range devices {
		if conn, online := registry.Get(device.ID.String()); online {
			if writeErr := conn.Write(r.Context(), websocket.MessageText, msgBytes); writeErr != nil {
				log.Printf("обои: сигнал устройству не ушёл: %v", writeErr)
			}
		}
	}
}

// DELETE /chats/wallpapers/{peer_account_id} — убрать СВОИ обои этого чата.
func NewDeleteChatWallpaperHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		peerID, ok := wallpaperPeer(w, r)
		if !ok {
			return
		}
		if sqlErr := queries.DeleteChatWallpaper(r.Context(), db.DeleteChatWallpaperParams{
			AccountID:     Session.AccountID,
			PeerAccountID: peerID,
		}); sqlErr != nil {
			http.Error(w, "Ошибка удаления обоев", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

// GET /chats/wallpapers — у каких чатов есть обои и когда менялись.
func NewListChatWallpapersHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		rows, sqlErr := queries.ListChatWallpapers(r.Context(), Session.AccountID)
		if sqlErr != nil {
			http.Error(w, "Ошибка получения списка обоев", http.StatusInternalServerError)
			return
		}
		resp := chatWallpapersResponse{Wallpapers: make([]chatWallpaperInfo, 0, len(rows))}
		for _, row := range rows {
			resp.Wallpapers = append(resp.Wallpapers, chatWallpaperInfo{PeerAccountID: row.PeerAccountID.String(), Version: row.UpdatedAt.Time.UnixMilli()})
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

// GET /chats/wallpapers/{peer_account_id} — сама картинка; нет обоев — 404.
func NewGetChatWallpaperHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}
		peerID, ok := wallpaperPeer(w, r)
		if !ok {
			return
		}
		image, sqlErr := queries.GetChatWallpaper(r.Context(), db.GetChatWallpaperParams{
			AccountID:     Session.AccountID,
			PeerAccountID: peerID,
		})
		if sqlErr != nil {
			if errors.Is(sqlErr, pgx.ErrNoRows) {
				http.Error(w, "Обоев нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка чтения обоев", http.StatusInternalServerError)
			}
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Content-Length", strconv.Itoa(len(image)))
		if _, writeErr := w.Write(image); writeErr != nil {
			log.Printf("обои: ошибка отдачи: %v", writeErr)
		}
	}
}
