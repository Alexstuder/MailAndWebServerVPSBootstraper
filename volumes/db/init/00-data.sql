-- =============================================================================
-- Supabase Role & Schema Initialization for supabase/postgres:17.x
-- =============================================================================
-- This file runs inside docker-entrypoint-initdb.d on a FRESH database.
-- The image creates only `supabase_admin` as superuser. This script builds
-- every other role, schema, and permission that Supabase services require.
--
-- Sources (verbatim SQL compiled from):
--   supabase/postgres: migrations/db/init-scripts/00000000000000-initial-schema.sql
--   supabase/postgres: migrations/db/init-scripts/00000000000001-auth-schema.sql
--   supabase/postgres: migrations/db/init-scripts/00000000000002-storage-schema.sql
--   supabase/postgres: migrations/db/init-scripts/00000000000003-post-setup.sql
--   supabase/postgres: migrations/db/migrations/ (all role-related migrations up to latest)
--   supabase/postgres: ansible/files/pgbouncer_config/pgbouncer_auth_schema.sql
-- =============================================================================


-- ---------------------------------------------------------------------------
-- SECTION 1: Core role setup (init-script 00000000000000-initial-schema.sql)
-- ---------------------------------------------------------------------------

-- Realtime publication
CREATE PUBLICATION supabase_realtime;

-- Supabase super admin (already exists as superuser; ensure all attributes)
ALTER USER supabase_admin WITH SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;

-- postgres role (created as superuser; demoted in Section 6)
CREATE USER postgres SUPERUSER CREATEDB CREATEROLE LOGIN REPLICATION BYPASSRLS;
GRANT supabase_admin TO postgres;

-- Supabase replication user (used by supabase-realtime)
CREATE USER supabase_replication_admin WITH LOGIN REPLICATION;

-- Supabase ETL user
CREATE USER supabase_etl_admin WITH LOGIN REPLICATION BYPASSRLS;
GRANT pg_read_all_data TO supabase_etl_admin;
GRANT CREATE ON DATABASE postgres TO supabase_etl_admin;

-- Supabase read-only user
CREATE ROLE supabase_read_only_user WITH LOGIN BYPASSRLS;
GRANT pg_read_all_data TO supabase_read_only_user;

-- Extension schema
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto         WITH SCHEMA extensions;

-- PostgREST API roles
CREATE ROLE anon            NOLOGIN NOINHERIT;
CREATE ROLE authenticated   NOLOGIN NOINHERIT;   -- logged-in users
CREATE ROLE service_role    NOLOGIN NOINHERIT BYPASSRLS; -- bypass RLS

-- PostgREST authenticator (connects to DB, switches into api roles)
CREATE USER authenticator NOINHERIT;
GRANT anon           TO authenticator;
GRANT authenticated  TO authenticator;
GRANT service_role   TO authenticator;
GRANT supabase_admin TO authenticator;

-- Public schema grants for API roles
GRANT USAGE                  ON SCHEMA public TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;

-- Extensions schema usable from API
GRANT USAGE ON SCHEMA extensions TO postgres, anon, authenticated, service_role;

-- supabase_admin search_path
ALTER USER supabase_admin SET search_path TO public, extensions;

-- Ensure grants apply even when supabase_admin creates objects
ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA public
    GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA public
    GRANT ALL ON TABLES    TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;

-- Short statement timeouts for API roles
ALTER ROLE anon          SET statement_timeout = '3s';
ALTER ROLE authenticated SET statement_timeout = '8s';


-- ---------------------------------------------------------------------------
-- SECTION 2: Auth schema (init-script 00000000000001-auth-schema.sql)
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_admin;

-- Core auth tables (GoTrue will manage migrations, but needs ownership)
CREATE TABLE auth.users (
    instance_id         uuid          NULL,
    id                  uuid          NOT NULL UNIQUE,
    aud                 varchar(255)  NULL,
    role                varchar(255)  NULL,
    email               varchar(255)  NULL UNIQUE,
    encrypted_password  varchar(255)  NULL,
    confirmed_at        timestamptz   NULL,
    invited_at          timestamptz   NULL,
    confirmation_token  varchar(255)  NULL,
    confirmation_sent_at timestamptz  NULL,
    recovery_token      varchar(255)  NULL,
    recovery_sent_at    timestamptz   NULL,
    email_change_token  varchar(255)  NULL,
    email_change        varchar(255)  NULL,
    email_change_sent_at timestamptz  NULL,
    last_sign_in_at     timestamptz   NULL,
    raw_app_meta_data   jsonb         NULL,
    raw_user_meta_data  jsonb         NULL,
    is_super_admin      bool          NULL,
    created_at          timestamptz   NULL,
    updated_at          timestamptz   NULL,
    CONSTRAINT users_pkey PRIMARY KEY (id)
);
CREATE INDEX users_instance_id_email_idx ON auth.users USING btree (instance_id, email);
CREATE INDEX users_instance_id_idx       ON auth.users USING btree (instance_id);
COMMENT ON TABLE auth.users IS 'Auth: Stores user login data within a secure schema.';

CREATE TABLE auth.refresh_tokens (
    instance_id uuid         NULL,
    id          bigserial    NOT NULL,
    token       varchar(255) NULL,
    user_id     varchar(255) NULL,
    revoked     bool         NULL,
    created_at  timestamptz  NULL,
    updated_at  timestamptz  NULL,
    CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id)
);
CREATE INDEX refresh_tokens_instance_id_idx         ON auth.refresh_tokens USING btree (instance_id);
CREATE INDEX refresh_tokens_instance_id_user_id_idx ON auth.refresh_tokens USING btree (instance_id, user_id);
CREATE INDEX refresh_tokens_token_idx               ON auth.refresh_tokens USING btree (token);
COMMENT ON TABLE auth.refresh_tokens IS 'Auth: Store of tokens used to refresh JWT tokens once they expire.';

CREATE TABLE auth.instances (
    id              uuid        NOT NULL,
    uuid            uuid        NULL,
    raw_base_config text        NULL,
    created_at      timestamptz NULL,
    updated_at      timestamptz NULL,
    CONSTRAINT instances_pkey PRIMARY KEY (id)
);
COMMENT ON TABLE auth.instances IS 'Auth: Manages users across multiple sites.';

CREATE TABLE auth.audit_log_entries (
    instance_id uuid        NULL,
    id          uuid        NOT NULL,
    payload     json        NULL,
    created_at  timestamptz NULL,
    CONSTRAINT audit_log_entries_pkey PRIMARY KEY (id)
);
CREATE INDEX audit_logs_instance_id_idx ON auth.audit_log_entries USING btree (instance_id);
COMMENT ON TABLE auth.audit_log_entries IS 'Auth: Audit trail for user actions.';

CREATE TABLE auth.schema_migrations (
    version varchar(255) NOT NULL,
    CONSTRAINT schema_migrations_pkey PRIMARY KEY (version)
);
COMMENT ON TABLE auth.schema_migrations IS 'Auth: Manages updates to the auth system.';

INSERT INTO auth.schema_migrations (version) VALUES
    ('20171026211738'), ('20171026211808'), ('20171026211834'),
    ('20180103212743'), ('20180108183307'), ('20180119214651'),
    ('20180125194653');

-- Auth helper functions accessible to API roles
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid AS $$
    SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text AS $$
    SELECT nullif(current_setting('request.jwt.claim.role', true), '')::text;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth.email() RETURNS text AS $$
    SELECT nullif(current_setting('request.jwt.claim.email', true), '')::text;
$$ LANGUAGE sql STABLE;

-- Grant auth schema usage to API roles
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Auth admin service account
CREATE USER supabase_auth_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
GRANT ALL PRIVILEGES ON SCHEMA auth              TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin;
ALTER USER supabase_auth_admin SET search_path = "auth";
ALTER TABLE auth.users              OWNER TO supabase_auth_admin;
ALTER TABLE auth.refresh_tokens     OWNER TO supabase_auth_admin;
ALTER TABLE auth.audit_log_entries  OWNER TO supabase_auth_admin;
ALTER TABLE auth.instances          OWNER TO supabase_auth_admin;
ALTER TABLE auth.schema_migrations  OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.uid()           OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.role()          OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.email()         OWNER TO supabase_auth_admin;
ALTER SCHEMA auth                   OWNER TO supabase_auth_admin;


-- ---------------------------------------------------------------------------
-- SECTION 3: Storage schema (init-script 00000000000002-storage-schema.sql)
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_admin;

CREATE USER supabase_storage_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
ALTER USER supabase_storage_admin SET search_path = "storage";
GRANT CREATE ON DATABASE postgres TO supabase_storage_admin;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'storage') THEN
        GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON TABLES    TO postgres, anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
        GRANT ALL ON SCHEMA storage TO supabase_storage_admin WITH GRANT OPTION;
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- SECTION 4: Post-setup (init-script 00000000000003-post-setup.sql)
-- ---------------------------------------------------------------------------

ALTER ROLE supabase_admin SET search_path TO "$user", public, auth, extensions;
ALTER ROLE postgres        SET search_path TO "$user", public, extensions;

-- pg_cron access event trigger
CREATE OR REPLACE FUNCTION extensions.grant_pg_cron_access()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    schema_is_cron bool;
BEGIN
    schema_is_cron = (
        SELECT n.nspname = 'cron'
        FROM pg_event_trigger_ddl_commands() AS ev
        LEFT JOIN pg_catalog.pg_namespace AS n ON ev.objid = n.oid
    );
    IF schema_is_cron THEN
        GRANT USAGE ON SCHEMA cron TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES IN SCHEMA cron GRANT ALL ON TABLES    TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES IN SCHEMA cron GRANT ALL ON FUNCTIONS TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES IN SCHEMA cron GRANT ALL ON SEQUENCES TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA cron
            GRANT ALL ON SEQUENCES  TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA cron
            GRANT ALL ON TABLES     TO postgres WITH GRANT OPTION;
        ALTER DEFAULT PRIVILEGES FOR USER supabase_admin IN SCHEMA cron
            GRANT ALL ON FUNCTIONS  TO postgres WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres WITH GRANT OPTION;
    END IF;
END;
$$;
CREATE EVENT TRIGGER issue_pg_cron_access ON ddl_command_end
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE PROCEDURE extensions.grant_pg_cron_access();
COMMENT ON FUNCTION extensions.grant_pg_cron_access IS 'Grants access to pg_cron';

-- pg_net access event trigger
CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access()
RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_extension AS ext ON ev.objid = ext.oid
        WHERE ext.extname = 'pg_net'
    ) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
            CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
        END IF;
        GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        ALTER  FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER  FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER  FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer)  SET search_path = net;
        ALTER  FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
        REVOKE ALL     ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer)  FROM PUBLIC;
        REVOKE ALL     ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;
        GRANT  EXECUTE ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer)  TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        GRANT  EXECUTE ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
    END IF;
END;
$$;
COMMENT ON FUNCTION extensions.grant_pg_net_access IS 'Grants access to pg_net';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'issue_pg_net_access') THEN
        CREATE EVENT TRIGGER issue_pg_net_access ON ddl_command_end
            WHEN TAG IN ('CREATE EXTENSION')
            EXECUTE PROCEDURE extensions.grant_pg_net_access();
    END IF;
END $$;

-- Dashboard user (Supabase Studio / postgres-meta)
CREATE ROLE dashboard_user NOSUPERUSER CREATEDB CREATEROLE REPLICATION;
GRANT ALL ON DATABASE postgres         TO dashboard_user;
GRANT ALL ON SCHEMA auth               TO dashboard_user;
GRANT ALL ON SCHEMA extensions         TO dashboard_user;
GRANT ALL ON ALL TABLES    IN SCHEMA auth        TO dashboard_user;
GRANT ALL ON ALL TABLES    IN SCHEMA extensions  TO dashboard_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA auth        TO dashboard_user;
GRANT ALL ON ALL SEQUENCES IN SCHEMA extensions  TO dashboard_user;
GRANT ALL ON ALL ROUTINES  IN SCHEMA auth        TO dashboard_user;
GRANT ALL ON ALL ROUTINES  IN SCHEMA extensions  TO dashboard_user;
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'storage') THEN
        GRANT ALL ON SCHEMA storage                    TO dashboard_user;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA storage   TO dashboard_user;
        GRANT ALL ON ALL ROUTINES  IN SCHEMA storage   TO dashboard_user;
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- SECTION 5: PgBouncer user + schema
-- (ansible/files/pgbouncer_config/pgbouncer_auth_schema.sql)
-- ---------------------------------------------------------------------------

CREATE USER pgbouncer;
REVOKE ALL PRIVILEGES ON SCHEMA public FROM pgbouncer;
CREATE SCHEMA pgbouncer AUTHORIZATION pgbouncer;

-- Latest version of get_auth (from migration 20251121132723 - correct search_path)
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename TEXT)
RETURNS TABLE(username TEXT, password TEXT)
LANGUAGE plpgsql
SET search_path = ''
SECURITY DEFINER
AS $$
BEGIN
    RAISE DEBUG 'PgBouncer auth request: %', p_usename;
    RETURN QUERY
    SELECT
        rolname::TEXT,
        CASE WHEN rolvaliduntil < now() THEN NULL ELSE rolpassword::TEXT END
    FROM pg_authid
    WHERE rolname = $1 AND rolcanlogin;
END;
$$;

REVOKE ALL     ON FUNCTION pgbouncer.get_auth(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO pgbouncer;


-- ---------------------------------------------------------------------------
-- SECTION 5b: Realtime schema + replication_admin grants
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS realtime;
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO supabase_admin;

GRANT ALL ON SCHEMA realtime TO supabase_replication_admin;
GRANT ALL ON SCHEMA public   TO supabase_replication_admin;
GRANT ALL ON ALL TABLES    IN SCHEMA realtime TO supabase_replication_admin;
GRANT ALL ON ALL TABLES    IN SCHEMA public   TO supabase_replication_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA realtime GRANT ALL ON TABLES TO supabase_replication_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public   GRANT ALL ON TABLES TO supabase_replication_admin;

-- ---------------------------------------------------------------------------
-- SECTION 6: Demote postgres (migration 10000000000000_demote-postgres.sql)
-- ---------------------------------------------------------------------------

GRANT ALL ON DATABASE postgres TO postgres;
GRANT ALL ON SCHEMA auth       TO postgres;
GRANT ALL ON SCHEMA extensions TO postgres;
GRANT ALL ON ALL TABLES    IN SCHEMA auth       TO postgres;
GRANT ALL ON ALL TABLES    IN SCHEMA extensions TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA auth       TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA extensions TO postgres;
GRANT ALL ON ALL ROUTINES  IN SCHEMA auth       TO postgres;
GRANT ALL ON ALL ROUTINES  IN SCHEMA extensions TO postgres;
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'storage') THEN
        GRANT ALL ON SCHEMA storage                  TO postgres;
        GRANT ALL ON ALL TABLES    IN SCHEMA storage TO postgres;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO postgres;
        GRANT ALL ON ALL ROUTINES  IN SCHEMA storage TO postgres;
    END IF;
END $$;
ALTER ROLE postgres NOSUPERUSER CREATEDB CREATEROLE LOGIN REPLICATION BYPASSRLS;


-- ---------------------------------------------------------------------------
-- SECTION 7: Accumulated migrations (role/permission changes only)
-- ---------------------------------------------------------------------------

-- 20211115181400 / 20220118070449: PostgREST tuning
ALTER ROLE authenticator SET session_preload_libraries = 'safeupdate';

-- 20220609081115: Grant service admins to postgres
GRANT supabase_auth_admin, supabase_storage_admin TO postgres;

-- 20221028101028: Authenticator statement timeout
ALTER ROLE authenticator SET statement_timeout = '8s';

-- 20221103090837: Revoke supabase_admin from authenticator
REVOKE supabase_admin FROM authenticator;

-- 20230201083204: Grant API roles to postgres
GRANT anon, authenticated, service_role TO postgres;

-- 20230306081037: pg_monitor to postgres
GRANT pg_monitor TO postgres;

-- 20230327032006: Grant API roles to supabase_storage_admin
GRANT anon, authenticated, service_role TO supabase_storage_admin;

-- 20230529180330: API roles become inherit (PostgREST v11+)
ALTER ROLE authenticated INHERIT;
ALTER ROLE anon          INHERIT;
ALTER ROLE service_role  INHERIT;

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgsodium_keyholder') THEN
        GRANT pgsodium_keyholder TO service_role;
    END IF;
END $$;

-- 20231013070755: Grant authenticator to supabase_storage_admin (revoke API roles)
GRANT authenticator TO supabase_storage_admin;
REVOKE anon, authenticated, service_role FROM supabase_storage_admin;

-- 20231020085357: Restrict cron.job writes from postgres
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM pg_class
        WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'cron')
          AND relname = 'job'
    ) THEN
        REVOKE ALL ON cron.job FROM postgres;
        GRANT SELECT ON cron.job TO postgres WITH GRANT OPTION;
    END IF;
END $$;

-- 20231130133139: Authenticator lock timeout
ALTER ROLE authenticator SET lock_timeout = '8s';

-- 20240606060239: Predefined role grants to postgres
GRANT pg_read_all_data, pg_signal_backend TO postgres;

-- 20250205060043: Disable log_statement for internal roles (security)
ALTER ROLE supabase_admin         SET log_statement = none;
ALTER ROLE supabase_auth_admin    SET log_statement = none;
ALTER ROLE supabase_storage_admin SET log_statement = none;

-- 20250218031949: pgsodium mask_role (only if pgsodium extension exists)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_extension WHERE extname = 'pgsodium') THEN
        CREATE OR REPLACE FUNCTION pgsodium.mask_role(masked_role regrole, source_name text, view_name text)
        RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $func$
        BEGIN
            EXECUTE format('GRANT SELECT ON pgsodium.key TO %s', masked_role);
            EXECUTE format('GRANT pgsodium_keyiduser, pgsodium_keyholder TO %s', masked_role);
            EXECUTE format('GRANT ALL ON %I TO %s', view_name, masked_role);
        END
        $func$;
    END IF;
END $$;

-- 20250402065937: Move internal event trigger owner to supabase_admin
DROP EVENT TRIGGER IF EXISTS issue_pg_net_access;
ALTER FUNCTION extensions.grant_pg_net_access OWNER TO supabase_admin;
CREATE EVENT TRIGGER issue_pg_net_access ON ddl_command_end
    WHEN TAG IN ('CREATE EXTENSION')
    EXECUTE FUNCTION extensions.grant_pg_net_access();

-- 20250402093753: Grant pg_create_subscription to postgres on PG16+
DO $$
DECLARE major_version int;
BEGIN
    SELECT current_setting('server_version_num')::int / 10000 INTO major_version;
    IF major_version >= 16 THEN
        GRANT pg_create_subscription TO postgres WITH ADMIN OPTION;
    END IF;
END $$;

-- 20250417190610: Replace pgbouncer.get_auth with final version (already done above in section 5)
-- (the version in section 5 already incorporates the corrected search_path from 20251121132723)

-- 20250421084701: Revoke admin roles from postgres (security tightening)
REVOKE supabase_storage_admin FROM postgres;
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'storage') THEN
        REVOKE CREATE ON SCHEMA storage FROM postgres;
    END IF;
END $$;
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM pg_class
        WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'storage')
          AND relname = 'migrations'
    ) THEN
        REVOKE ALL ON storage.migrations FROM anon, authenticated, service_role, postgres;
    END IF;
END $$;
REVOKE supabase_auth_admin FROM postgres;
REVOKE CREATE ON SCHEMA auth FROM postgres;
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM pg_class
        WHERE relnamespace = 'auth'::regnamespace AND relname = 'schema_migrations'
    ) THEN
        REVOKE ALL ON auth.schema_migrations FROM dashboard_user, postgres;
    END IF;
END $$;

-- 20250605172253: Grant with ADMIN OPTION on PG16+
DO $$
DECLARE major_version int;
BEGIN
    SELECT current_setting('server_version_num')::int / 10000 INTO major_version;
    IF major_version >= 16 THEN
        GRANT anon, authenticated, service_role, authenticator,
              pg_monitor, pg_read_all_data, pg_signal_backend
        TO postgres WITH ADMIN OPTION;
    END IF;
END $$;

-- 20250709135250: Grant storage schema usage to postgres with grant option
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'storage') THEN
        GRANT USAGE ON SCHEMA storage TO postgres WITH GRANT OPTION;
    END IF;
END $$;

-- 20250710151649: Read-only user enforces read-only transactions
ALTER ROLE supabase_read_only_user SET default_transaction_read_only = on;

-- 20251001204436: pg_monitor to ETL and read-only; pg_create_subscription already above
GRANT pg_monitor TO supabase_etl_admin, supabase_read_only_user;

-- 20251105172723: pg_reload_conf to postgres
GRANT EXECUTE ON FUNCTION pg_catalog.pg_reload_conf() TO postgres WITH GRANT OPTION;

-- 20251121132723: Final pgbouncer.get_auth already correct in section 5
-- (revoke from postgres, grant only to pgbouncer - already done)
REVOKE EXECUTE ON FUNCTION pgbouncer.get_auth(text) FROM postgres;

-- 20260211120934: supabase_privileged_role
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_privileged_role') THEN
        CREATE ROLE supabase_privileged_role;
        GRANT supabase_privileged_role TO postgres, supabase_etl_admin;
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- SECTION 8: Passwords
-- Passwords are set by 01-passwords.sh (a shell init script that runs after
-- this file and has access to $POSTGRES_PASSWORD from the container env).
-- SQL files cannot read env vars directly; shell scripts can.
-- See volumes/db/init/01-passwords.sh
-- ---------------------------------------------------------------------------
