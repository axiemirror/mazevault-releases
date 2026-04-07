-- =============================================================================
-- MazeVault EntraID SSO Role Mapping — Database Diagnostic Queries
-- =============================================================================
-- Run against the MazeVault database to diagnose role mapping issues.
--
-- Usage:
--   psql -U mazevault -d mazevault -f diagnose-role-mapping.sql
--   psql "$DATABASE_URL" -f diagnose-role-mapping.sql
--
-- Modify the @target_email variable at the top to filter for a specific user.
-- =============================================================================

-- Set target user email (change this to investigate a specific user)
\set target_email 'user@example.com'

-- =============================================================================
-- 1. Identity Providers — verify Entra SSO configuration
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  1. Identity Providers (Entra/AzureAD)'
\echo '=================================================================='

SELECT
    id,
    name,
    type,
    status,
    config->>'tenant_id' AS tenant_id,
    config->>'client_id' AS client_id,
    CASE WHEN config->>'client_secret' IS NOT NULL THEN '***set***' ELSE 'MISSING' END AS secret,
    created_at,
    updated_at
FROM identity_providers
WHERE type IN ('entra_id', 'entra', 'azure_ad')
  AND deleted_at IS NULL
ORDER BY created_at;

-- Check: at least one active entra provider should exist
SELECT
    CASE
        WHEN COUNT(*) = 0 THEN 'FAIL: No active Entra identity provider found!'
        WHEN COUNT(*) > 1 THEN 'WARN: Multiple Entra providers found — resolveConfig uses first match'
        ELSE 'OK: Single Entra provider configured'
    END AS check_result
FROM identity_providers
WHERE type IN ('entra_id', 'entra', 'azure_ad')
  AND deleted_at IS NULL;

-- =============================================================================
-- 2. Group Role Mappings — verify mapping configuration
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  2. Group Role Mappings (Entra source)'
\echo '=================================================================='

SELECT
    grm.id,
    grm.group_external_id,
    grm.group_display_name,
    r.name AS mapped_role,
    r.is_system,
    grm.source,
    ip.name AS provider_name,
    ip.type AS provider_type,
    grm.created_at
FROM group_role_mappings grm
JOIN roles r ON r.id = grm.role_id
LEFT JOIN identity_providers ip ON ip.id = grm.provider_id
WHERE grm.source = 'entra'
ORDER BY r.name, grm.group_display_name;

-- Check: at least one mapping should exist
SELECT
    CASE
        WHEN COUNT(*) = 0 THEN 'FAIL: No group_role_mappings with source=entra!'
        ELSE 'OK: ' || COUNT(*) || ' Entra role mapping(s) configured'
    END AS check_result
FROM group_role_mappings
WHERE source = 'entra';

-- =============================================================================
-- 3. System Roles — available roles and their permissions
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  3. System Roles & Permissions'
\echo '=================================================================='

SELECT
    id,
    name,
    description,
    is_system,
    LENGTH(permissions::text) AS permissions_json_length,
    CASE
        WHEN permissions IS NULL THEN 'NO PERMISSIONS!'
        WHEN permissions::text = '[]' THEN 'EMPTY PERMISSIONS!'
        ELSE 'configured'
    END AS permission_status
FROM roles
WHERE is_system = true
ORDER BY name;

-- =============================================================================
-- 4. Specific User Investigation
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  4. User Investigation (target: ' :target_email ')'
\echo '=================================================================='

-- Basic user info
SELECT
    u.id,
    u.email,
    u.name,
    u.role AS denormalized_role,
    u.sso_provider,
    u.sso_external_id,
    u.created_at,
    u.last_login_at
FROM users u
WHERE u.email = :'target_email'
  AND u.deleted_at IS NULL;

-- All active role assignments for the user
\echo ''
\echo '  4a. Active Role Assignments'

SELECT
    ur.id,
    r.name AS role_name,
    ur.scope,
    ur.organization_id,
    ur.project_id,
    ur.environment_id,
    ur.assigned_by_sso,
    ur.expires_at,
    ur.created_at
FROM user_roles ur
JOIN roles r ON r.id = ur.role_id
JOIN users u ON u.id = ur.user_id
WHERE u.email = :'target_email'
  AND u.deleted_at IS NULL
  AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
ORDER BY ur.scope, r.name;

-- Check role vs effective permissions
\echo ''
\echo '  4b. Effective Roles Summary'

SELECT
    u.role AS user_role_field,
    COUNT(ur.id) AS active_role_count,
    STRING_AGG(DISTINCT r.name, ', ' ORDER BY r.name) AS all_assigned_roles,
    CASE
        WHEN COUNT(ur.id) = 0 THEN 'FAIL: No active user_roles!'
        WHEN COUNT(ur.id) = 1 AND u.role = MIN(r.name) THEN 'OK: Single role, matches denormalized field'
        WHEN COUNT(ur.id) > 1 THEN 'INFO: Multiple roles — permissions are COMBINED'
        ELSE 'CHECK: Role mismatch possible'
    END AS assessment
FROM users u
LEFT JOIN user_roles ur ON ur.user_id = u.id
    AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
LEFT JOIN roles r ON r.id = ur.role_id
WHERE u.email = :'target_email'
  AND u.deleted_at IS NULL
GROUP BY u.id, u.role;

-- =============================================================================
-- 5. OBO Token Sessions — verify Entra token storage
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  5. User Entra Sessions (OBO)'
\echo '=================================================================='

SELECT
    ues.id,
    u.email,
    ues.expires_at,
    CASE
        WHEN ues.expires_at < NOW() THEN 'EXPIRED'
        ELSE 'ACTIVE'
    END AS status,
    LENGTH(ues.encrypted_access_token) AS access_token_len,
    LENGTH(ues.encrypted_refresh_token) AS refresh_token_len,
    ues.updated_at
FROM user_entra_sessions ues
JOIN users u ON u.id = ues.user_id
WHERE u.email = :'target_email'
ORDER BY ues.updated_at DESC
LIMIT 5;

-- =============================================================================
-- 6. Recent SSO Role Sync Events (audit log)
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  6. Recent SSO Audit Events'
\echo '=================================================================='

SELECT
    al.id,
    al.action,
    al.entity_type,
    al.entity_id,
    al.details->>'role' AS synced_role,
    al.details->>'source' AS source,
    al.actor_email,
    al.created_at
FROM audit_logs al
WHERE al.action IN ('sso_role_sync', 'user_role_assigned', 'sso_login', 'sso_login_failed')
  AND al.created_at > NOW() - INTERVAL '7 days'
ORDER BY al.created_at DESC
LIMIT 20;

-- =============================================================================
-- 7. Cross-Check: Mappings vs Actual Assignments
-- =============================================================================
\echo ''
\echo '=================================================================='
\echo '  7. Mapping Coverage Analysis'
\echo '=================================================================='

-- Unused mappings (configured but no user_roles referencing that role via SSO)
SELECT
    grm.group_display_name,
    grm.group_external_id,
    r.name AS mapped_role,
    COUNT(ur.id) AS sso_assigned_count
FROM group_role_mappings grm
JOIN roles r ON r.id = grm.role_id
LEFT JOIN user_roles ur ON ur.role_id = grm.role_id AND ur.assigned_by_sso = true
WHERE grm.source = 'entra'
GROUP BY grm.id, grm.group_display_name, grm.group_external_id, r.name
ORDER BY sso_assigned_count, r.name;

\echo ''
\echo '=================================================================='
\echo '  Done — Review results above'
\echo '=================================================================='
