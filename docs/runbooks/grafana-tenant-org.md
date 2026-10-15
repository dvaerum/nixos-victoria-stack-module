# Give a tenant its own Grafana organisation

Applies to a tenant in `services.victoriaStack.tenants` (see
[0032](../decisions/0032-tenants-in-token-files.md)) whose users should see that
tenant's data in Grafana and nothing else. Grafana OSS cannot create
organisations or restrict a datasource to some users of an organisation, so the
split is one organisation per tenant: you create the organisation by hand, and
the module provisions the tenant's datasources into it. The datasources go
through vmauth's read tier with the tenant's own token
([0029](../decisions/0029-grafana-datasources-through-vmauth-read-tier.md)), so
they can only read that tenant, whatever a Grafana user types into Explore.

The steps below are run by the test `grafana-tenant-orgs-runbook`
(`tests/grafana-tenant-orgs.nix`, a VM): steps 1 to 4 with the API calls shown
here, the missing-organisation failure and a token rotation. The clicks in the
Grafana UI are not automated.

Placeholders: `<tenant>` is the tenant name, `<org-id>` the number Grafana
gives the organisation, `grafana.example.internal` your Grafana host,
`<admin-user>` a Grafana server admin.

## Order matters: create the organisation first

If `grafanaOrgId` names an organisation that does not exist, Grafana fails at
start (`[org.notFound] failed to get org by ID: <org-id>` in its journal) and
systemd restarts it in a loop. While it loops its API is down, so the
organisation cannot be created then. Create it first, with Grafana running,
and set `grafanaOrgId` afterwards. If it is already looping (the organisation
was deleted, or the id is wrong), remove `grafanaOrgId` and `readTokenFile`
from the tenant, deploy, and start again at step 2.

## Procedure

1. **Declare the tenant and its read token.** Create a file with one random
   bearer token for this tenant's Grafana datasources, list the same token in
   vmauth's read tokens with `tenant: <tenant>`, and deploy. Do not set
   `grafanaOrgId` yet.

   ```nix
   {
     imports = [ victoria-stack-module.nixosModules.victoriaStack ];
     services.victoriaStack = {
       tenants.team-a.accountId = 7;
       vmauth.readTokensFile = "/run/secrets/vmauth-read-tokens.yaml";
     };
   }
   ```

   ```yaml
   # vmauth-read-tokens.yaml
   tokens:
     - token: "team-a-grafana-secret"   # the content of the token file
       tenant: team-a
   ```

2. **Create the organisation in Grafana.** In the UI: Administration, General,
   Organizations, New org; the organisations list shows the id. Or with the
   API as a server admin:

   ```sh
   curl -X POST -u '<admin-user>:<admin-password>' \
     -H 'Content-Type: application/json' -d '{"name": "<tenant>"}' \
     https://grafana.example.internal/api/orgs
   # {"message":"Organization created","orgId":<org-id>}
   ```

   Add the tenant's users to the organisation with the role you want
   (Administration, Users and access). Every member of the organisation can
   query every datasource in it.

   Grafana also adds every new user to the main organisation as a Viewer
   (default `[users] auto_assign_org = true`), where the main datasources are,
   and that user can query them through Grafana's datasource API. For a tenant
   user, either remove them from the main organisation (Administration, Users
   and access, Users, the user, Organizations) or set
   `services.grafana.settings.users.auto_assign_org = false` and add users to
   organisations yourself.

3. **Set `grafanaOrgId` and `readTokenFile` and deploy.** Both together, or the
   build stops. The id must not be 1 (the organisation of the main
   datasources) and must be different for every tenant.

   ```nix
   {
     imports = [ victoria-stack-module.nixosModules.victoriaStack ];
     services.victoriaStack = {
       tenants.team-a = {
         accountId = 7;
         grafanaOrgId = 2;                                 # the id from step 2
         readTokenFile = "/run/secrets/grafana-team-a-token";  # the token from step 1
       };
     };
   }
   ```

   Deploying changes Grafana's provisioning, so NixOS restarts `grafana.service`.
   Check it is running: `systemctl status grafana.service`.

4. **Verify.**
   - UI: switch to the organisation (profile menu, or the organisation picker),
     then Connections, Data sources lists `VictoriaLogs (<tenant>)`,
     `VictoriaTraces (<tenant>)` and, with metrics on, `VictoriaMetrics (<tenant>)`.
     In Explore, pick one and run a query: it shows only that tenant's data.
     Behind nginx's `/grafana/` sub-path, the two cards on the Connections home
     page link to a doubled path (`/grafana/grafana/connections/...`, a Grafana
     13.1.6 bug); use the sidebar or open `/grafana/connections/datasources`.
   - API (the same check):

     ```sh
     curl -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' \
       https://grafana.example.internal/api/datasources
     ```

     A query through a datasource, for logs:

     ```sh
     curl -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' \
       --data-urlencode 'query=*' \
       https://grafana.example.internal/api/datasources/proxy/uid/vl-<tenant>/select/logsql/query
     ```

   The main organisation keeps only the main datasources.

## Rotating the token

Replace the content of the tenant's `readTokenFile` and add the new token to
`vmauth.readTokensFile`. A path unit notices the replaced file and restarts
Grafana. Until vmauth knows the new token the tenant's datasources answer 401.

## What the module provisions

Per tenant with both options, into organisation `grafanaOrgId`: one datasource
for each enabled backend, named `<product> (<tenant>)` with uid `vm-<tenant>`,
`vl-<tenant>` or `vt-<tenant>` (a uid is at most 40 characters, so a tenant name
longer than 37 characters is refused). Tenants without the options get nothing.
Removing a tenant's options leaves its datasources in the organisation: the
module only deletes what the current configuration names (the same limit as
disabling a backend, see the note on `prune` in
`nixosModule/victoriaStack/grafana.nix`). Delete them by hand, in Connections,
Data sources, or with
`curl -X DELETE -u '<admin-user>:<admin-password>' -H 'X-Grafana-Org-Id: <org-id>' https://grafana.example.internal/api/datasources/uid/<uid>`.
