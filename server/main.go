package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {

	//создаем свой эндопоинт (endpoint) для проверки состояния сервера
	var endpoint_health string = "/health"

	//создаем переменную, в которую помещаем функцию, которая будет обрабатывать HTTP-запросы к эндопоинту /health
	var healthHandler = func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	}

	//создаем свою таблицу маршрутов (mux) для обработки HTTP-запросов
	var mux = http.NewServeMux()

	//добавляет в таблицу mux (multiplexor) запись о том, что при обращении к endpoint_health будет вызвана функция healthHandler
	mux.HandleFunc(endpoint_health, healthHandler)

	//сохраняем в переменную и запускаем HTTP-сервер на порту 8080 и
	var server_error = http.ListenAndServe(":8080", mux)

	//если сервер не запустился, то выводим сообщение об ошибке и выходим с кодом 1
	if server_error != nil {

		//Fatalf гарантированно завершает работу программы после вывода сообщения об ошибке
		log.Fatalf("ошибка запуска сервера на порту 8080: %v", server_error)
	}
}
