-- data2pg_init_db.sql
-- This file belongs to data2pg, the framework that helps migrating data to PostgreSQL databases from various sources.
-- This sql script defines the structure of the central database used by data2pg.pl.
-- It must be executed by the data2pg role.

\set ON_ERROR_STOP

--- 
--- Preliminary checks on roles.
---
DO LANGUAGE plpgsql
$$
BEGIN
  IF current_user <> 'data2pg' THEN
    RAISE EXCEPTION 'The connection role to create the data2pg schema must be ''data2pg''';
  END IF;
END
$$;

BEGIN TRANSACTION;

--
-- Create the schema.
--
DROP SCHEMA IF EXISTS data2pg CASCADE;

CREATE SCHEMA data2pg;
SET search_path = data2pg;
--
-- Create specific types.
--
CREATE TYPE run_status_enum AS ENUM ('Initializing', 'In_progress', 'Ending', 'Completed', 'Aborted', 'Suspended', 'Restarted');
CREATE TYPE session_status_enum AS ENUM ('Opened', 'Closed', 'Aborted');
CREATE TYPE step_status_enum AS ENUM ('Blocked', 'Ready', 'In_progress', 'Completed');

--
-- Create tables.
--

-- The table target_database contains data related to each target database to migrate.
CREATE TABLE target_database (
    tdb_id                     TEXT NOT NULL,           -- A unique database name for data2pg
    tdb_host                   TEXT,                    -- The ip adress of the database
    tdb_port                   SMALLINT,                -- The ip port of the database
    tdb_dbname                 TEXT,                    -- The database name inside the target instance
    tdb_description            TEXT,                    -- A free description
    PRIMARY KEY (tdb_id)
);

-- The table run contains data related to each data migration batch run.
CREATE TABLE run (
    run_id                     INT NOT NULL             -- Run identifier
	                             GENERATED BY DEFAULT AS IDENTITY,
----    run_pg_dsn                 TEXT NOT NULL,                 -- The DSN of the targeted database
    run_database               TEXT NOT NULL,           -- The name of the targeted database
    run_batch_name             TEXT,                    -- Batch name as specified in the configuration file
    run_batch_type             TEXT,                    -- Batch type as specified in the batch configuration on the target database
    run_init_max_ses           INT                      -- The MAX_SESSIONS parameter from the configuration file (at least 1)
                                 CHECK (run_init_max_ses > 0),
    run_init_asc_ses           INT                      -- The ASC_SESSIONS parameter from the configuration file (at least 0)
                                 CHECK (run_init_max_ses >= 0),
    run_comment                TEXT,                    -- Comment entered at run start
    run_start_ts               TIMESTAMPTZ NOT NULL     -- Start date and time of the run
                                 DEFAULT current_timestamp,
    run_end_ts                 TIMESTAMPTZ,             -- End date and time of the run
    run_status                 run_status_enum NOT NULL -- Current status of the run (Initializing, In_progress, Completed,...)
                                 DEFAULT 'Initializing',
    run_perl_pid               INT,                     -- Process ID of the data2pg.pl process
    run_max_sessions           INT                      -- The current maximum number of sessions to the target database
                                 CHECK (run_max_sessions >= 0),   -- positive, but may be 0 to smartly stop the run
    run_asc_sessions           INT                      -- The current number of sessions for which steps are assigned in estimated cost ascending order
                                 CHECK (run_max_sessions >= 0),
    run_error_msg              TEXT,                    -- Error message, in case of run abort
    run_restart_id             INT,                     -- Identifier of the run which restarted the current run, if aborted
    PRIMARY KEY (run_id),
    FOREIGN KEY (run_database) REFERENCES target_database(tdb_id)
);

-- The session table contains data related to each opened session to the target database for a migration batch run.
CREATE TABLE session (
    ses_run_id                 INT NOT NULL,            -- The run id of the session
    ses_id                     INT NOT NULL,            -- Id of the session within the run
    ses_status                 session_status_enum      -- Status of the session (Opened or closed)
                                 DEFAULT 'Opened',
    ses_backend_pid            INT,                     -- Current Pid of the Postgres backend that handles the session
    ses_start_ts               TIMESTAMPTZ NOT NULL     -- Session start date and time (the first start time if the session is re-opened)
                                 DEFAULT current_timestamp,
    ses_stop_ts                TIMESTAMPTZ,             -- Session end date and time (remains NULL in case of abort)
    PRIMARY KEY (ses_run_id, ses_id),
    FOREIGN KEY (ses_run_id) REFERENCES run(run_id)
);

-- The step table contains data related to elementary steps of the batch run.
CREATE TABLE step (
    stp_run_id                 INT NOT NULL,            -- The run id of the step
    stp_name                   TEXT NOT NULL,           -- The name of the step of the migration (a schema qualified table name for instance)
    stp_sql_function           TEXT,                    -- The sql function to execute on the target database
    stp_shell_script           TEXT,                    -- The shell script to execute (for specific purpose only)
    stp_cost                   BIGINT,                  -- The relative cost indicator (a table size for instance)
    stp_parents                TEXT[],                  -- The set of parent steps that need to be completed to allow the step to start
    stp_cum_cost               BIGINT,                  -- Cumulative cost, taking into account the children steps costs. This is used to plan the run.
    stp_status                 step_status_enum         -- Status of the step (Blocked, Ready_to_start, In_progress, Completed)
                                 DEFAULT 'Blocked',
    stp_blocking               TEXT[],                  -- The set of parent steps that currently block the step execution
    stp_ses_id                 INT,                     -- Session identifier used to execute the step
    stp_start_ts               TIMESTAMPTZ,             -- Session start date and time
    stp_stop_ts                TIMESTAMPTZ,             -- Session end date and time (remains NULL in case of abort)
    CHECK ((stp_sql_function IS NULL AND stp_shell_script IS NOT NULL) OR (stp_sql_function IS NOT NULL AND stp_shell_script IS NULL)),
    PRIMARY KEY (stp_run_id, stp_name),
    FOREIGN KEY (stp_run_id) REFERENCES run(run_id)
);

-- The step_result table contains the data related to elementary steps of the batch run.
CREATE TABLE step_result (
    sr_run_id                  INT NOT NULL,            -- The run id of the step
    sr_step                    TEXT NOT NULL,           -- The name of the step of the migration
    sr_indicator               TEXT NOT NULL,           -- An elementary indicator for the step
    sr_value                   BIGINT,                  -- The numeric value associated to the sr_indicator
    sr_rank                    SMALLINT,                -- The display rank of the indicator
    sr_is_main_indicator       BOOLEAN,                 -- Boolean indicating whether the indicator is the main indicator to display by the monitoring clients
    PRIMARY KEY (sr_run_id, sr_step, sr_indicator),
    FOREIGN KEY (sr_run_id, sr_step) REFERENCES step(stp_run_id, stp_name)
);

COMMIT;
RESET search_path;
