package api

import (
	"log"
	"net/http"
	"server/internal/db"

	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

type DeviceInfo struct {
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name,omitempty"`
}

type ListDevicesResponse struct {
	AccountID string       `json:"account_id"`
	Devices   []DeviceInfo `json:"devices"`
}

func NewGetDevicesByLoginHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var _, ErrTokCheck = CheckToken(w, r, queries)
		//var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var login = r.PathValue("login")

		//ищем аккаунт ID сохраненный в базе по логину
		var Account, SqlErrAcc = queries.GetAccountByLogin(r.Context(), login)

		//проверяем есть ли ошибка при получении аккаунт ID по логину в базе
		if SqlErrAcc != nil {

			//проверяем что за ошибка - при выполнении запроса не оказалось строк или у нас с базой проблема
			if errors.Is(SqlErrAcc, pgx.ErrNoRows) {
				http.Error(w, "Такого пользователя нет", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска пользователя", http.StatusInternalServerError)
			}
			return
		}

		//получаем список устройств по найденному аккаунт ID
		var devices, SqlErrDev = queries.GetDevicesByAccount(r.Context(), Account.ID)

		//проверяем есть ли ошибка при получении списка устройств по логину
		if SqlErrDev != nil {
			http.Error(w, "ошибка получения списка устройств", http.StatusInternalServerError)
			return
		}

		//сохраняем в переменной массива список устройств пользователя
		var NewDevicesInfo []DeviceInfo

		//
		for _, d := range devices {
			var info DeviceInfo
			info.DeviceID = d.ID.String()
			if d.DeviceName.Valid {
				info.DeviceName = d.DeviceName.String
			}
			NewDevicesInfo = append(NewDevicesInfo, info)
		}

		//переменная с ответом
		var NewListeDevicesResponse ListDevicesResponse

		//добавляем в ответ список устройств
		NewListeDevicesResponse.AccountID = Account.ID.String()

		NewListeDevicesResponse.Devices = NewDevicesInfo

		//устанавливаем тип ответа - JSON
		w.Header().Set("Content-Type", "application/json")

		//переводим наш JSON в байты и отправляем клиенту.
		json.NewEncoder(w).Encode(NewListeDevicesResponse)

		/*
			проверка
			curl -i http://127.0.0.1:8080/accounts/alice/devices \
			-H "Authorization: Bearer Ji3bJf3ODyUxumht2uvRuwSEnIbe7wZL8foFJhcxaCg="

			curl -i http://127.0.0.1:8080/accounts/несуществующий_логин/devices \
			-H "Authorization: Bearer Ji3bJf3ODyUxumht2uvRuwSEnIbe7wZL8foFJhcxaCg="

			curl -i http://127.0.0.1:8080/accounts/alice/devices
		*/
	}

}
