-- Push-токены iOS (APNs). У устройства их два: обычный — уведомление о
-- новом сообщении, VoIP (PushKit) — входящий звонок (iOS сразу показывает
-- его через CallKit). Приходят в приложение в разное время, поэтому
-- регистрируются по отдельности (NULL — "не менять"). sandbox — сборка из
-- Xcode (development APNs), иначе TestFlight/App Store (production).
CREATE TABLE apns_tokens (
    device_id UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    alert_token TEXT,
    voip_token TEXT,
    sandbox BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
