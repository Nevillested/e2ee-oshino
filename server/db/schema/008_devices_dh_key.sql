ALTER TABLE devices
    ADD COLUMN identity_dh_pubkey BYTEA,
    ADD COLUMN identity_dh_signature BYTEA;
