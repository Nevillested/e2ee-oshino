package api

import "sync"

// ACK - acknowledgement, подтверждение
// эта ересь нужна для того, чтобы подтверждать, что клиент 100% получил от сервера сообщение и сообщения не потерялись
type AckRegistry struct {
	mu      sync.Mutex
	waiters map[string]chan struct{}
}

func NewAckRegistry() *AckRegistry {
	return &AckRegistry{waiters: make(map[string]chan struct{})}
}

// Wait регистрирует ожидание ACK с данным id и возвращает канал, который
// закроется, когда ACK придёт (через Fulfill).
func (r *AckRegistry) Wait(id string) chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	ch := make(chan struct{})
	r.waiters[id] = ch
	return ch
}

// Fulfill сообщает, что ACK с данным id получен.
func (r *AckRegistry) Fulfill(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ch, ok := r.waiters[id]; ok {
		close(ch)
		delete(r.waiters, id)
	}
}

// Cancel убирает ожидание без доставки — вызывается после таймаута или
// ошибки записи, чтобы waiter не висел в памяти вечно.
func (r *AckRegistry) Cancel(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.waiters, id)
}
