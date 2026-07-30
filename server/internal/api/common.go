package api

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"server/internal/db"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// функция проверки токена
func CheckToken(w http.ResponseWriter, r *http.Request, queries *db.Queries) (db.Session, error) {

	var ErrExp string

	//получаем заголовок
	var NewAuthorization = r.Header.Get("Authorization")

	//проверяем, не пустой ли заголовок
	if len(NewAuthorization) == 0 {
		ErrExp = "Ошибка заголовка"
		http.Error(w, ErrExp, http.StatusUnauthorized)
		return db.Session{}, errors.New(ErrExp)
	}

	//Из заголовка удаляем "Bearer " чтобы оставить только токен
	var token string = strings.TrimPrefix(NewAuthorization, "Bearer ")

	//формируем хэш токен по sha256
	var hashArray [32]byte = sha256.Sum256([]byte(token))
	var tokenHash string = base64.StdEncoding.EncodeToString(hashArray[:])

	//лезем в бд и по хэшу токена ищем там данные пользователя
	var Session, SessionErr = queries.GetValidSessionByToken(r.Context(), tokenHash)

	//проверяем есть ли валидные сессии или нет
	if SessionErr != nil {
		ErrExp = "Нет валидных сессий"
		http.Error(w, ErrExp, http.StatusUnauthorized)
		return db.Session{}, errors.New(ErrExp)
	}

	//устанавливаем новую дату жизни токена. 30 дней от текущего момента
	var NewDtExpiries = pgtype.Timestamptz{Time: time.Now().Add(30 * 24 * time.Hour), InfinityModifier: pgtype.Finite, Valid: true}

	//продлеваем жизнь токену, под которым вошел пользователь
	var ExSessionError = queries.ExtendSession(r.Context(), db.ExtendSessionParams{ID: Session.ID, ExpiresAt: NewDtExpiries})

	//проверяем продлена ли жизнь токена
	if ExSessionError != nil {
		log.Printf("не удалось продлить сессию: %v", ExSessionError)
	}

	//ошибок нет, возвращаем nil
	return Session, nil

}
