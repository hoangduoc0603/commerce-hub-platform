-- Database và role của Keycloak, chép theo gitops/infra/pg-main/keycloak.yaml (CR DatabaseRole, Database).
-- Entrypoint của image postgres chạy file này một lần khi volume pgdata rỗng, bằng superuser postgres, theo thứ tự tên.
-- Mật khẩu là giá trị dev (lab: SealedSecret pg-main-keycloak); khớp KC_DB_PASSWORD trong compose.yaml.

-- Keycloak tự migrate schema và chạy runtime bằng cùng role, nối thẳng PostgreSQL (lab: pg-main-rw).
CREATE ROLE keycloak LOGIN PASSWORD 'keycloak_local' CONNECTION LIMIT 20;
CREATE DATABASE keycloak OWNER keycloak;
