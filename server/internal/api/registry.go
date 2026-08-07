package api

import (
	"sync"

	"github.com/coder/websocket"
)

// структура хранения подключенных пользователей к серверу
type ConnectionRegistry struct {
	mu    sync.Mutex
	conns map[string]*websocket.Conn
}

// метод для type ConnectionRegistry, который добавляет запись в словарь/мапу/список присутствующих
func (reg *ConnectionRegistry) Add(deviceID string, conn *websocket.Conn) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//добавлеяем запись вида: "deviceID": "ID_вебсокет_подключения"
	reg.conns[deviceID] = conn
}

// метод для type ConnectionRegistry, который удаляет запись из словаря/мапы/списка присутствующих
func (reg *ConnectionRegistry) Remove(deviceID string) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//удаляем запись вида: "deviceID": "ID_вебсокет_подключения"
	delete(reg.conns, deviceID)
}

// метод для type ConnectionRegistry, который выдает инфу, подключен ли пользователь к серверу или нет
func (reg *ConnectionRegistry) Get(deviceID string) (*websocket.Conn, bool) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//проверяем есть ли такой пользователь в списке подключенных или нет
	conn, ok := reg.conns[deviceID]

	//возвращаем результат
	return conn, ok
}

// чтобы каждое подключение работало не со своей копией, а с общей структурой - возвращаем указатель на структуру. Так с одной структурой будет работать весь сервер
func NewConnectionRegistry() *ConnectionRegistry {

	//объявляем переменную структуры
	var NewRegistry ConnectionRegistry

	//инициализация второго поля переменной, тк по умолчанию это nil
	NewRegistry.conns = make(map[string]*websocket.Conn)

	//возврат
	return &NewRegistry
}

// удаляет запись только если в реестре сейчас лежит именно это соединение — а не более новое, которое могло успеть зарегистрироваться позже (защита от гонки при быстром переподключении).
func (reg *ConnectionRegistry) RemoveIfCurrent(deviceID string, conn *websocket.Conn) {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	if reg.conns[deviceID] == conn {
		delete(reg.conns, deviceID)
	}
}

/*
принудительно закрывает соединение конкретногоустройства и убирает его из реестра — используется, когда старое
устройство нужно немедленно "выгнать" при входе с нового устройства
того же аккаунта, не дожидаясь, пока оно само что-то пришлёт и получит отказ.
*/
func (reg *ConnectionRegistry) CloseAndRemove(deviceID string) {
	reg.mu.Lock()
	conn, ok := reg.conns[deviceID]
	if ok {
		delete(reg.conns, deviceID)
	}
	reg.mu.Unlock()

	if ok {
		conn.Close(websocket.StatusPolicyViolation, "logged in on another device")
	}
}
