-- ==============================================================================
-- Script: diagnose-connections.sql
-- Purpose: Inspect and emergency-reclaim PostgreSQL connection pool slots
-- ==============================================================================

-- 1. Display total connection usage against server limit
SELECT 
    (SELECT count(*) FROM pg_stat_activity) AS current_connections,
    current_setting('max_connections')::int AS max_connections,
    round((SELECT count(*)::numeric FROM pg_stat_activity) / current_setting('max_connections')::numeric * 100, 2) AS usage_percent;

-- 2. Breakdown active connections by state
SELECT 
    state,
    count(*) AS connection_count
FROM pg_stat_activity
GROUP BY state
ORDER BY connection_count DESC;

-- 3. Identify abandoned idle transactions
SELECT 
    pid,
    usename,
    client_addr,
    now() - state_change AS idle_duration,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY idle_duration DESC;

-- 4. EMERGENCY KILL: Terminate connections idle for more than 5 minutes
-- UNCOMMENT TO EXECUTE:
-- SELECT pg_terminate_backend(pid)
-- FROM pg_stat_activity
-- WHERE state IN ('idle in transaction', 'idle')
--   AND now() - state_change > interval '5 minutes'
--   AND pid <> pg_backend_pid();
