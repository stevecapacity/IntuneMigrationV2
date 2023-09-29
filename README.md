# IntuneMigrationV2
 Intune Tenant to Tenant Device Migration New Release: Supports in-place migration in addition to hardware refresh scenarios.

 Welcome to V2 of Intune Tenant to Tenant device migration.  We're constantly improving the solution, but here are the major new fixes and features:
 * **Two directories**: Each containing a migration scenario solution-
    * **InPlaceMigration**: Contents are similar to the V1 scripts.  Meant for migrating a device to a new tenant on an existing PC.
    * **HardwareRefreshMigration**: Brand new solution that will allow a user to migrate to a new device and new tenant while migrating their existing uesr data.

* **Hybrid AAD Joined and Domain Joined to Azure**: We're now adding the ability to migrate from hybrid or domain joined tenants directly to Azure AD.

* **Peer-to-peer Data Migration**: When a user receives a new PC and starts Autopilot provisioning, user data will be migrated from the existing PC over the local network.
* **Blob Storage Backup**: Alternative solution for data migration that levereges Azure blob storage.  Works in both scenarios.

* **Fixes**: Fixed major issue where users were still seeing the Tenant A account in *Settings* > *Work and school accounts* after migrating to Tenant B.  This has been resolved.

A lot more is coming soon, so stay tuned.
