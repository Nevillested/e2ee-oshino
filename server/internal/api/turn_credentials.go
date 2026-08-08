package api

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"server/internal/db"
	"time"
)

type TurnCredentialsResponse struct {
	Username string   `json:"username"`
	Password string   `json:"password"`
	Ttl      int      `json:"ttl"`
	Urls     []string `json:"urls"`
}

func NewTurnCredentialsHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var _, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var secret = os.Getenv("TURN_SECRET")
		if secret == "" {
			http.Error(w, "TURN не настроен на сервере", http.StatusInternalServerError)
			return
		}

		//username по схеме coturn: unix-время истечения, дальше сервер сам
		//разбирает эту часть и сверяет с текущим временем
		var ttlSeconds int64 = 86400 // сутки — достаточно с запасом на один звонок
		var expiry = time.Now().Unix() + ttlSeconds
		var username = fmt.Sprintf("%d", expiry)

		var mac = hmac.New(sha1.New, []byte(secret))
		mac.Write([]byte(username))
		var password = base64.StdEncoding.EncodeToString(mac.Sum(nil))

		var resp TurnCredentialsResponse
		resp.Username = username
		resp.Password = password
		resp.Ttl = int(ttlSeconds)
		resp.Urls = []string{
			"turn:195.19.66.107:3478?transport=udp",
			"turn:195.19.66.107:3478?transport=tcp",
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}
