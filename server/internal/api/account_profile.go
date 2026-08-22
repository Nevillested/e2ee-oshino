package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/db"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

const maxStatusLength = 200

type UpdateStatusRequest struct {
	Status string `json:"status"`
}

// NewUpdateStatusHandler — PUT /account/status. Пустая строка валидна
// (пользователь стёр весь статус во время редактирования — это не
// "отмена", а осознанный пустой статус).
func NewUpdateStatusHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req UpdateStatusRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		// len() по байтам достаточно строг (реальные символы только короче),
		// клиент дополнительно считает по символам для UX — здесь просто
		// защита от откровенно большого тела.
		if len(Req.Status) > maxStatusLength*4 {
			http.Error(w, "Статус слишком длинный", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UpdateAccountStatus(r.Context(), db.UpdateAccountStatusParams{
			ID:         Session.AccountID,
			StatusText: pgtype.Text{String: Req.Status, Valid: Req.Status != ""},
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения статуса", http.StatusInternalServerError)
			return
		}

		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "status")

		w.WriteHeader(http.StatusOK)
	}
}

type UpdateBirthdayRequest struct {
	Birthday *string `json:"birthday"`
}

// NewUpdateBirthdayHandler — PUT /account/birthday. birthday: null снимает
// дату рождения целиком.
func NewUpdateBirthdayHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req UpdateBirthdayRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var Birthday pgtype.Date
		if Req.Birthday != nil && strings.TrimSpace(*Req.Birthday) != "" {
			Parsed, ParseErr := time.Parse("2006-01-02", strings.TrimSpace(*Req.Birthday))
			if ParseErr != nil {
				http.Error(w, "Неверный формат даты (нужно YYYY-MM-DD)", http.StatusBadRequest)
				return
			}
			Birthday = pgtype.Date{Time: Parsed, Valid: true}
		}

		var SqlErr = queries.UpdateAccountBirthday(r.Context(), db.UpdateAccountBirthdayParams{
			ID:       Session.AccountID,
			Birthday: Birthday,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения даты рождения", http.StatusInternalServerError)
			return
		}

		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "birthday")

		w.WriteHeader(http.StatusOK)
	}
}

type UpdatePrivacyRequest struct {
	FindByLogin int16 `json:"find_by_login"`
	Avatar      int16 `json:"avatar"`
	Birthday    int16 `json:"birthday"`
	Status      int16 `json:"status"`
}

func validVisibility(v int16, allowContactsOnly bool) bool {
	if v == 0 || v == 1 {
		return true
	}
	return v == 2 && allowContactsOnly
}

// NewUpdatePrivacyHandler — PUT /account/privacy, все 4 значения одним
// запросом (одна кнопка "Сохранить" на клиенте). find_by_login — просто
// пишется в базу, рассылать тут нечего (это влияет только на будущий
// поиск, у уже существующих контактов ничего не закэшировано). А вот для
// avatar/birthday/status, если их видимость реально поменялась (в любую
// сторону — и когда поле стало видно, и когда его наоборот скрыли), уже
// существующие контакты уведомляются тем же profile_updated, что и при
// смене самих данных — именно так их клиент узнаёт, что нужно перезапросить
// (и в случае "скрыли" — вычистить у себя из кэша то, что видеть больше не
// должен, см. notifyContactsProfileField ниже).
func NewUpdatePrivacyHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req UpdatePrivacyRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		if !validVisibility(Req.FindByLogin, false) ||
			!validVisibility(Req.Avatar, true) ||
			!validVisibility(Req.Birthday, true) ||
			!validVisibility(Req.Status, true) {
			http.Error(w, "Недопустимое значение приватности", http.StatusBadRequest)
			return
		}

		var Old, OldErr = queries.GetAccountByID(r.Context(), Session.AccountID)
		if OldErr != nil {
			http.Error(w, "Ошибка чтения текущих настроек", http.StatusInternalServerError)
			return
		}

		var SqlErr = queries.UpdateAccountPrivacy(r.Context(), db.UpdateAccountPrivacyParams{
			ID:                    Session.AccountID,
			FindByLoginVisibility: Req.FindByLogin,
			AvatarVisibility:      Req.Avatar,
			BirthdayVisibility:    Req.Birthday,
			StatusVisibility:      Req.Status,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения настроек приватности", http.StatusInternalServerError)
			return
		}

		if Old.AvatarVisibility != Req.Avatar {
			notifyContactsProfileField(r.Context(), queries, registry, Session.AccountID, "avatar")
		}
		if Old.BirthdayVisibility != Req.Birthday {
			notifyContactsProfileField(r.Context(), queries, registry, Session.AccountID, "birthday")
		}
		if Old.StatusVisibility != Req.Status {
			notifyContactsProfileField(r.Context(), queries, registry, Session.AccountID, "status")
		}

		w.WriteHeader(http.StatusOK)
	}
}

type ProfileResponse struct {
	AccountID string       `json:"account_id"`
	Login     string       `json:"login"`
	Devices   []DeviceInfo `json:"devices"`
	Status    string       `json:"status,omitempty"`
	Birthday  string       `json:"birthday,omitempty"`
	HasAvatar bool         `json:"has_avatar"`
}

// NewGetAccountProfileHandler — GET /account/profile/{login}, заменяет
// GetDevicesByLogin для сценария "поиск/просмотр чужого профиля": те же
// account_id+devices, плюс поля профиля, отфильтрованные по приватности
// смотрящего. Свой собственный логин — всегда без ограничений.
func NewGetAccountProfileHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var login = r.PathValue("login")

		var Account, SqlErrAcc = queries.GetAccountByLogin(r.Context(), login)
		if SqlErrAcc != nil {
			if errors.Is(SqlErrAcc, pgx.ErrNoRows) {
				http.Error(w, "Такого пользователя нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска пользователя", http.StatusInternalServerError)
			}
			return
		}

		var isSelf = Account.ID == Session.AccountID

		if !isSelf && Account.FindByLoginVisibility == 0 {
			// "Никто не может найти" — буквально никто, даже уже
			// существующий контакт (у него и так уже есть чат, поиск
			// по логину — не единственный путь взаимодействия).
			http.Error(w, "Такого пользователя нет", http.StatusNotFound)
			return
		}

		var devices, SqlErrDev = queries.GetDevicesByAccount(r.Context(), Account.ID)
		if SqlErrDev != nil {
			http.Error(w, "ошибка получения списка устройств", http.StatusInternalServerError)
			return
		}
		var DevicesInfo []DeviceInfo
		for _, d := range devices {
			var info DeviceInfo
			info.DeviceID = d.ID.String()
			if d.DeviceName.Valid {
				info.DeviceName = d.DeviceName.String
			}
			DevicesInfo = append(DevicesInfo, info)
		}

		var Resp ProfileResponse
		Resp.AccountID = Account.ID.String()
		Resp.Login = Account.Login
		Resp.Devices = DevicesInfo

		fieldVisible := func(visibility int16) bool {
			if isSelf || visibility == 1 {
				return true
			}
			if visibility == 0 {
				return false
			}
			// visibility == 2: только контакты.
			isContact, ContactErr := queries.IsContact(r.Context(), db.IsContactParams{
				AccountID:     Account.ID,
				PeerAccountID: Session.AccountID,
			})
			return ContactErr == nil && isContact
		}

		if fieldVisible(Account.StatusVisibility) && Account.StatusText.Valid {
			Resp.Status = Account.StatusText.String
		}
		if fieldVisible(Account.BirthdayVisibility) && Account.Birthday.Valid {
			Resp.Birthday = Account.Birthday.Time.Format("2006-01-02")
		}
		if fieldVisible(Account.AvatarVisibility) {
			Resp.HasAvatar = Account.AvatarObjectKey.Valid
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Resp)
	}
}

// notifyProfileUpdatedIfVisible — смотрит СВОЮ (только что обновлённую,
// серверную) видимость этого поля и, если не 0, рассылает лёгкое
// событие всем контактам — не broadcast всем подряд (как avatar_changed
// сейчас, это уже признанный в его же комментариях костыль из-за
// отсутствия contacts на тот момент), а прицельно, тем же способом, что
// notifyBlockStatusChanged. Решение "слать или нет" — целиком серверное,
// не полагается на клиентский кэш приватности, чтобы не допустить
// рассинхрона источника истины.
func notifyProfileUpdatedIfVisible(ctx context.Context, queries *db.Queries, registry *ConnectionRegistry, accountID pgtype.UUID, field string) {
	Account, err := queries.GetAccountByID(ctx, accountID)
	if err != nil {
		return
	}

	var visibility int16
	switch field {
	case "status":
		visibility = Account.StatusVisibility
	case "birthday":
		visibility = Account.BirthdayVisibility
	case "avatar":
		visibility = Account.AvatarVisibility
	default:
		return
	}
	if visibility == 0 {
		return
	}

	notifyContactsProfileField(ctx, queries, registry, accountID, field)
}

// notifyContactsProfileField — сама рассылка, без проверки видимости (её,
// если нужно, делает вызывающая сторона: notifyProfileUpdatedIfVisible —
// перед отправкой новых данных, NewUpdatePrivacyHandler — нет, там сигнал
// нужен именно ПРИ смене видимости, включая переход в "скрыто").
func notifyContactsProfileField(ctx context.Context, queries *db.Queries, registry *ConnectionRegistry, accountID pgtype.UUID, field string) {
	contactIDs, err := queries.GetContactAccountIDs(ctx, accountID)
	if err != nil {
		log.Printf("notifyContactsProfileField: не удалось получить контакты: %v", err)
		return
	}

	msgBytes, err := json.Marshal(struct {
		Type      string `json:"Type"`
		AccountID string `json:"AccountId"`
		Field     string `json:"Field"`
	}{Type: "profile_updated", AccountID: accountID.String(), Field: field})
	if err != nil {
		return
	}

	for _, contactID := range contactIDs {
		devices, err := queries.GetDevicesByAccount(ctx, contactID)
		if err != nil {
			continue
		}
		for _, device := range devices {
			conn, online := registry.Get(device.ID.String())
			if online {
				if writeErr := conn.Write(ctx, websocket.MessageText, msgBytes); writeErr != nil {
					log.Printf("notifyContactsProfileField: ошибка отправки устройству, ставим в очередь: %v", writeErr)
					online = false
				}
			}
			if !online {
				if saveErr := queries.SavePendingMessage(ctx, db.SavePendingMessageParams{
					ToDeviceID: device.ID,
					Ciphertext: string(msgBytes),
				}); saveErr != nil {
					log.Printf("notifyContactsProfileField: не удалось поставить сигнал в очередь: %v", saveErr)
				}
			}
		}
	}
}
