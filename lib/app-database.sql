-- The application's database, owned by the `app` role and closed to every other
-- role. Run by postgres-init.sh at first start (db = app) and by `kit restore`,
-- which builds the restored copy beside the live one (db = app_restore).
CREATE DATABASE :"db" OWNER app ENCODING 'UTF8';
REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO app;
