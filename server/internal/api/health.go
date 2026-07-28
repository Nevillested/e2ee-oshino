package api

import (
	"fmt"
	"net/http"
	"server/internal/db"
)

/*
функция NewHealthHandler принимает 1 параметр queries с типом *db.Queries
функция NewHealthHandler возвращает функцию с типом func(http.ResponseWriter, *http.Request),
где w - это данные(канал) от сервера к клиенту, r - это данные от клиента к серверу
*/

func NewHealthHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
		// далее использование queries
	}

}
