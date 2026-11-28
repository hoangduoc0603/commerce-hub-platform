-- Database và bốn role của hello, chép theo gitops/infra/pg-main/hello.yaml (CR DatabaseRole, Database).
-- Sửa file đó thì sửa file này cùng lúc (cùng với services/hello/src/test/resources/testcontainers/hello-roles.sql):
-- dev chỉ có giá trị khi quyền giống lab. Sửa ở đây chỉ có hiệu lực sau docker compose down -v.
-- Mật khẩu là giá trị dev (lab: SealedSecret), khớp pgbouncer/userlist.txt và application-local.yaml của hello.
-- Service G1 mới: thêm một file <số>-<service>.sql theo mẫu này, một dòng ở pgbouncer.ini, userlist.txt và pg_hba.conf.

-- Owner database, schema, bảng. NOLOGIN: migration làm việc bằng SET ROLE hello_owner.
CREATE ROLE hello_owner NOLOGIN;

-- Chỉ sở hữu hàm SECURITY DEFINER tra cứu chéo Workspace (G1).
CREATE ROLE hello_lookup NOLOGIN BYPASSRLS;

-- Flyway. IN ROLE = inRoles của CR. CONNECTION LIMIT giống lab: Flyway 1 kết nối, chừa 1.
CREATE ROLE hello_migrator LOGIN PASSWORD 'hello_migrator_local' CONNECTION LIMIT 2 IN ROLE hello_owner, hello_lookup;

-- Runtime qua PgBouncer. Không thuộc role nào ở trên: chỉ có quyền DML mà migration cấp.
CREATE ROLE hello_app LOGIN PASSWORD 'hello_app_local' CONNECTION LIMIT 10;

-- CR Database: owner hello_owner. PostgreSQL 15+: schema public thuộc pg_database_owner, nên hello_owner tạo được bảng
-- trong public, còn hello_app thì không.
CREATE DATABASE hello OWNER hello_owner;
